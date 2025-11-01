/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include "axiio-endpoints.h"
#include "nvme-ep.h"
#include "rdma-ep.h"
#include "sdma-ep.h"
#include "test-ep.h"

// Forward declarations for test-ep functions
extern "C" {
__host__ __device__ void test_ep_emulateEndpoint(unsigned, sqeType_s*,
                                                 cqeType_s*);
__device__ void test_ep_driveEndpoint(unsigned, sqeType_s*, cqeType_s*,
                                      unsigned long long int*,
                                      unsigned long long int*);
}

// Forward declarations for nvme-ep functions
extern "C" {
__host__ __device__ void nvme_ep_emulateEndpoint(unsigned, sqeType_s*,
                                                 cqeType_s*);
__device__ void nvme_ep_driveEndpoint(unsigned, sqeType_s*, cqeType_s*,
                                      unsigned long long int*,
                                      unsigned long long int*);
}

// Forward declarations for sdma-ep functions
extern "C" {
__host__ __device__ void sdma_ep_emulateEndpoint(unsigned, sqeType_s*,
                                                 cqeType_s*);
__device__ void sdma_ep_driveEndpoint(unsigned, sqeType_s*, cqeType_s*,
                                      unsigned long long int*,
                                      unsigned long long int*);
}

// Forward declarations for rdma-ep functions
extern "C" {
__host__ __device__ void rdma_ep_emulateEndpoint(unsigned, sqeType_s*,
                                                 cqeType_s*);
__device__ void rdma_ep_driveEndpoint(unsigned, sqeType_s*, cqeType_s*,
                                      unsigned long long int*,
                                      unsigned long long int*);
}

// Static dispatch implementations that don't require object dereferencing
__host__ __device__ void axiioEndPoint::emulateEndpointDispatch(
  EndpointType type, unsigned sqeIterations, sqeType* sqeAddr,
  cqeType* cqeAddr) {
  switch (type) {
    case EndpointType::TEST_EP:
      test_ep_emulateEndpoint(sqeIterations, sqeAddr, cqeAddr);
      break;
    case EndpointType::NVME_EP:
      nvme_ep_emulateEndpoint(sqeIterations, sqeAddr, cqeAddr);
      break;
    case EndpointType::SDMA_EP:
      sdma_ep_emulateEndpoint(sqeIterations, sqeAddr, cqeAddr);
      break;
    case EndpointType::RDMA_EP:
      rdma_ep_emulateEndpoint(sqeIterations, sqeAddr, cqeAddr);
      break;
    default:
      // Default to test-ep
      test_ep_emulateEndpoint(sqeIterations, sqeAddr, cqeAddr);
      break;
  }
}

__device__ void axiioEndPoint::driveEndpointDispatch(
  EndpointType type, unsigned sqeIterations, sqeType* sqeAddr, cqeType* cqeAddr,
  unsigned long long int* startTime, unsigned long long int* endTime) {
  switch (type) {
    case EndpointType::TEST_EP:
      test_ep_driveEndpoint(sqeIterations, sqeAddr, cqeAddr, startTime,
                            endTime);
      break;
    case EndpointType::NVME_EP:
      nvme_ep_driveEndpoint(sqeIterations, sqeAddr, cqeAddr, startTime,
                            endTime);
      break;
    case EndpointType::SDMA_EP:
      sdma_ep_driveEndpoint(sqeIterations, sqeAddr, cqeAddr, startTime,
                            endTime);
      break;
    case EndpointType::RDMA_EP:
      rdma_ep_driveEndpoint(sqeIterations, sqeAddr, cqeAddr, startTime,
                            endTime);
      break;
    default:
      // Default to test-ep
      test_ep_driveEndpoint(sqeIterations, sqeAddr, cqeAddr, startTime,
                            endTime);
      break;
  }
}

// Member function wrappers (require object in GPU-accessible memory)
__host__ __device__ void axiioEndPoint::emulateEndpoint(unsigned sqeIterations,
                                                        sqeType* sqeAddr,
                                                        cqeType* cqeAddr) {
  emulateEndpointDispatch(endpointType, sqeIterations, sqeAddr, cqeAddr);
}

__device__ void axiioEndPoint::driveEndpoint(unsigned sqeIterations,
                                             sqeType* sqeAddr, cqeType* cqeAddr,
                                             unsigned long long int* startTime,
                                             unsigned long long int* endTime) {
  driveEndpointDispatch(endpointType, sqeIterations, sqeAddr, cqeAddr,
                        startTime, endTime);
}
