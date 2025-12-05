/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include "axiio-endpoint.h"
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

__host__ __device__ unsigned long long int wall_clock64() {
#ifdef __HIP_DEVICE_COMPILE__
  return __builtin_readcyclecounter();
#else
  return 0;
#endif
}

} // namespace test_ep

// Export test-ep functions for runtime dispatch
__host__ __device__ void test_ep_emulateEndpoint(unsigned sqeIterations,
                                                 void* sqeAddr,
                                                 void* cqeAddr) {
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

__device__ void test_ep_driveEndpoint(unsigned sqeIterations,
                                      void* sqeAddr, void* cqeAddr,
                                      unsigned long long int* startTime,
                                      unsigned long long int* endTime) {
  // Cast void* to endpoint-specific types
  test_ep::sqeType* sqePtr = static_cast<test_ep::sqeType*>(sqeAddr);
  test_ep::cqeType* cqePtr = static_cast<test_ep::cqeType*>(cqeAddr);

  // Use cooperative threading: thread 0 generates SQEs, thread 1 processes them
  // If only one thread is available, it will handle both roles sequentially
  const bool isProducer = (blockDim.x >= 2) ? (threadIdx.x == 0) : true;
  const bool isConsumer = (blockDim.x >= 2) ? (threadIdx.x == 1) : true;

  if (isProducer) {
    // Producer: Generate SQEs
    test_ep::sqeType sqeLocal = {TEST_EP_MAGIC_ID, 0, 0, 0xdeadbeef, {0}};
    test_ep::sqeType sqeStop = {TEST_EP_MAGIC_ID, 0xFFFF, 0, 0xf0f0f0f0, {0}};
    
    for (unsigned sqeCount = 0; sqeCount < sqeIterations; sqeCount++) {
      sqeLocal.entryId = sqeCount;
      sqeLocal.dataPayload = 0xbeefdeaf + sqeCount;
      
      // Record start time before writing SQE
      startTime[sqeCount] = test_ep::wall_clock64();
      
      // Write submission queue entry
      test_ep::sqeWrite(sqeLocal, sqePtr);
      
      // Memory fence to ensure SQE is visible to consumer thread
      __threadfence();
      
      // If single-threaded, process immediately
      if (blockDim.x < 2) {
        test_ep::cqeType cqeLocal = test_ep::cqeGenFromSqe(&sqeLocal);
        endTime[sqeCount] = test_ep::wall_clock64();
        test_ep::cqeWrite(cqeLocal, cqePtr);
      }
    }
    
    // Write stop command to signal completion (only needed for multi-threaded)
    if (blockDim.x >= 2) {
      test_ep::sqeWrite(sqeStop, sqePtr);
      __threadfence();
    }
  }
  
  if (isConsumer && blockDim.x >= 2) {
    // Consumer: Poll for SQEs and generate CQEs (only in multi-threaded mode)
    // Initialize with a value that won't match any real SQE
    test_ep::sqeType sqeOld = {TEST_EP_MAGIC_ID, 0xFFFF, 0, 0xFFFFFFFFFFFFFFFF, {0}};
    test_ep::sqeType sqeNew;
    test_ep::sqeType sqeStop = {TEST_EP_MAGIC_ID, 0xFFFF, 0, 0xf0f0f0f0, {0}};
    unsigned cqeCount = 0;
    
    // Read initial state to sync with producer
    sqeOld = test_ep::sqeRead((volatile test_ep::sqeType*)sqePtr);
    
    while (cqeCount < sqeIterations) {
      // Poll for new SQE (waits until it detects a change)
      sqeNew = test_ep::sqePoll(sqeOld, (volatile test_ep::sqeType*)sqePtr);
      
      // Check for stop command
      if (test_ep::sqeEqual(&sqeNew, &sqeStop)) {
        break;
      }
      
      // Generate completion from SQE
      test_ep::cqeType cqeLocal = test_ep::cqeGenFromSqe(&sqeNew);
      
      // Record end time before writing CQE
      // Use entryId to index into the timing array
      if (sqeNew.entryId < sqeIterations) {
        endTime[sqeNew.entryId] = test_ep::wall_clock64();
      }
      
      // Write completion queue entry
      test_ep::cqeWrite(cqeLocal, cqePtr);
      
      sqeOld = sqeNew;
      cqeCount++;
    }
  }
  
  // Synchronize threads before returning
  if (blockDim.x >= 2) {
    __syncthreads();
  }
}
