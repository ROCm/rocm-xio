/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include "axiio-endpoint-config.h"
#include "axiio-endpoint.h"
#include "test-ep-config.h"
#include "test-ep.h"

// Namespace all test-ep implementation to avoid conflicts
namespace test_ep {

// Helper function to create AxiioEndpoint object for this endpoint
__host__ AxiioEndpoint createEndpoint() {
  return AxiioEndpoint(EndpointType::TEST_EP);
}

// Use types from test-ep.h
typedef struct test_sqe sqeType;
typedef struct test_cqe cqeType;

// Verify that the queue entry sizes match test-ep expectations
static_assert(sizeof(sqeType) == TEST_EP_SQE_SIZE, "test-ep SQE size mismatch");
static_assert(sizeof(cqeType) == TEST_EP_CQE_SIZE, "test-ep CQE size mismatch");

// Helper function to compare sqeType structs
__host__ __device__ bool sqeEqual(const sqeType* a, const sqeType* b) {
  return (a->dataPayload == b->dataPayload && a->entryId == b->entryId &&
          a->magicID == b->magicID);
}

// Helper function to compare cqeType structs
__host__ __device__ bool cqeEqual(const cqeType* a, const cqeType* b) {
  return (a->dataPayload == b->dataPayload && a->entryId == b->entryId &&
          a->magicID == b->magicID);
}

__host__ __device__ sqeType sqeRead(volatile sqeType* sqeAddress) {
  sqeType result;
  result.magicID = sqeAddress->magicID;
  result.entryId = sqeAddress->entryId;
  result.timeStamp = sqeAddress->timeStamp;
  result.dataPayload = sqeAddress->dataPayload;
  return result;
}

__host__ __device__ cqeType cqeRead(volatile cqeType* cqeAddress) {
  cqeType result;
  result.magicID = cqeAddress->magicID;
  result.entryId = cqeAddress->entryId;
  result.dataPayload = cqeAddress->dataPayload;
  return result;
}

__host__ __device__ void sqeWrite(sqeType sqeData, sqeType* sqeAddress) {
  *sqeAddress = sqeData;
#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
#endif // __HIP_DEVICE_COMPILE__
}

__host__ __device__ void cqeWrite(cqeType cqeData, cqeType* cqeAddress) {
  *cqeAddress = cqeData;
#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
#endif // __HIP_DEVICE_COMPILE__
}

__host__ __device__ sqeType sqePoll(sqeType sqeLast,
                                    volatile sqeType* sqeAddress) {
  sqeType sqeNew;
  while (true) {
    sqeNew = sqeRead(sqeAddress);
    if (sqeNew.magicID == TEST_EP_MAGIC_ID && !sqeEqual(&sqeNew, &sqeLast))
      return sqeNew;
  }
}

__host__ __device__ cqeType cqePoll(cqeType cqeLast,
                                    volatile cqeType* cqeAddress) {
  cqeType cqeNew;
  while (true) {
    cqeNew = cqeRead(cqeAddress);
    if (cqeNew.magicID == TEST_EP_MAGIC_ID && !cqeEqual(&cqeNew, &cqeLast))
      return cqeNew;
  }
}

__host__ __device__ cqeType cqeGenFromSqe(const sqeType* sqeData) {
  cqeType result;
  result.magicID = TEST_EP_MAGIC_ID;
  result.entryId = sqeData->entryId;
  result.dataPayload = ~sqeData->dataPayload;
  return result;
}

} // namespace test_ep

// Export test-ep functions for runtime dispatch
__host__ __device__ void test_ep_emulateEndpoint(unsigned sqeIterations,
                                                 void* sqeAddr, void* cqeAddr) {
  test_ep::sqeType sqeNew = {TEST_EP_MAGIC_ID, 0, 0, 0xbeefdead, {0}};
  test_ep::sqeType sqeOld = {TEST_EP_MAGIC_ID, 0, 0, 0xf000f000, {0}};
  test_ep::sqeType sqeStop = {TEST_EP_MAGIC_ID, 0xFFFF, 0, 0xf0f0f0f0, {0}};
  test_ep::cqeType cqeLocal;

  while (!test_ep::sqeEqual(&sqeNew, &sqeStop)) {
    sqeNew = test_ep::sqePoll(sqeOld, (volatile test_ep::sqeType*)sqeAddr);
    cqeLocal = test_ep::cqeGenFromSqe(&sqeNew);
    test_ep::cqeWrite(cqeLocal, (test_ep::cqeType*)cqeAddr);
    sqeOld = sqeNew;
  }
}

// New config-based driveEndpoint function
__device__ void test_ep_driveEndpoint(const AxiioEndpointConfig& config,
                                      void* sqeAddr, void* cqeAddr) {
  // Extract endpoint-specific config
  const test_ep::TestEpConfig* epConfig =
    static_cast<const test_ep::TestEpConfig*>(config.endpointConfig);
  (void)epConfig; // May be used for future test-ep specific features

  // Get thread ID for multi-threading
  unsigned tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid >= config.numThreads) {
    return;
  }

  // Cast void* to endpoint-specific types
  test_ep::sqeType* sqePtr = static_cast<test_ep::sqeType*>(sqeAddr);
  test_ep::cqeType* cqePtr = static_cast<test_ep::cqeType*>(cqeAddr);

  // Use per-thread buffers if multi-threaded
  test_ep::sqeType* mySqe = (config.numThreads > 1) ? &sqePtr[tid] : sqePtr;
  test_ep::cqeType* myCqe = (config.numThreads > 1) ? &cqePtr[tid] : cqePtr;
  (void)myCqe; // Reserved for future use when GPU generates CQEs

  // Get per-thread timing arrays if provided
  unsigned long long int* myStartTimes = nullptr;
  unsigned long long int* myEndTimes = nullptr;
  if (config.startTimes != nullptr) {
    myStartTimes = &config.startTimes[tid * config.iterations];
  }
  if (config.endTimes != nullptr) {
    myEndTimes = &config.endTimes[tid * config.iterations];
  }
  (void)myEndTimes; // Reserved for future use when GPU records end times

  // Calculate delay if needed
  uint64_t delayNs = 0;
  if (config.delayNs < 0) {
    // Fixed delay: use absolute value
    delayNs = static_cast<uint64_t>(-config.delayNs);
  } else if (config.delayNs > 0) {
    // Random delay: generate value between 0 and delayNs
    uint64_t seed = tid * 0x9e3779b9ULL + config.iterations * 0x6c6229e6ULL +
                    wall_clock64();
    seed = (seed * 1103515245ULL + 12345ULL) & 0x7FFFFFFFULL;
    delayNs = seed % (static_cast<uint64_t>(config.delayNs) + 1);
  }

  // Encode thread index in entryId (upper 16 bits) and iteration (lower 16
  // bits) This allows CPU threads to identify which thread/iteration the
  // message is for GPU only writes SQEs - CPU threads will poll and generate
  // CQEs
  for (unsigned i = 0; i < config.iterations; ++i) {
    // Record start time before writing SQE
    if (myStartTimes != nullptr) {
      myStartTimes[i] = wall_clock64();
    }

    // Prepare SQE with thread index encoded
    test_ep::sqeType sqeLocal = {};
    sqeLocal.magicID = TEST_EP_MAGIC_ID;
    sqeLocal.entryId = (tid << 16) | (i & 0xFFFF);
    sqeLocal.timeStamp = wall_clock64();
    sqeLocal.dataPayload = delayNs; // Store delay in dataPayload for CPU to
                                    // read

    // Write submission queue entry
    test_ep::sqeWrite(sqeLocal, mySqe);
    __threadfence_system();

    // Note: CPU threads will poll for this SQE and generate the CQE
    // GPU just waits for the CQE to appear (or times out)
    // For now, GPU doesn't wait - CPU threads handle completions
  }

  // Synchronize threads before returning
  if (config.numThreads > 1) {
    __syncthreads();
  }
}
