/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include "axiio-endpoints.h"
#include "test-ep.h"

// Namespace all test-ep implementation to avoid conflicts
namespace test_ep {

// Use types from test-ep.h
typedef sqeType_s sqeType;
typedef cqeType_s cqeType;

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
extern "C" {

__host__ __device__ void test_ep_emulateEndpoint(unsigned sqeIterations,
                                                 sqeType_s* sqeAddr,
                                                 cqeType_s* cqeAddr) {
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
                                      sqeType_s* sqeAddr, cqeType_s* cqeAddr,
                                      unsigned long long int* startTime,
                                      unsigned long long int* endTime) {
  test_ep::sqeType sqeLocal = {TEST_EP_MAGIC_ID, 0, 0, 0xdeadbeef, {0}};
  test_ep::cqeType cqeLocal = {TEST_EP_MAGIC_ID, 0, 0xdeadbeef, {0}};
  test_ep::sqeType sqeStop = {TEST_EP_MAGIC_ID, 0xFFFF, 0, 0xf0f0f0f0, {0}};
  unsigned sqeCount = 0;

  while (sqeCount < sqeIterations) {
    sqeLocal.entryId = sqeCount;
    startTime[sqeCount] = wall_clock64();
    test_ep::sqeWrite(sqeLocal, (test_ep::sqeType*)sqeAddr);
    cqeLocal = test_ep::cqePoll(cqeLocal, (volatile test_ep::cqeType*)cqeAddr);
    endTime[sqeCount] = wall_clock64();
    sqeCount++;
    sqeLocal.dataPayload = 0xbeefdeaf + sqeCount;
  }
  test_ep::sqeWrite(sqeStop, (test_ep::sqeType*)sqeAddr);
}

} // extern "C"
