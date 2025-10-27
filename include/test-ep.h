/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef AXIIO_TEST_ENDPOINT_H
#define AXIIO_TEST_ENDPOINT_H

#include <hip/hip_runtime.h>

typedef long long sqeType;
typedef long cqeType;

__host__ void testEndpoint(unsigned sqeIterations,
				    sqeType *sqeAddr,
				    cqeType *cqeAddr);

__device__ void driveTestEndpoint(unsigned sqeIterations,
									  sqeType *sqeAddr,
									  cqeType *cqeAddr, 
									  unsigned long long int *start_time,
									  unsigned long long int *end_time);

#endif //AXIIO_TEST_ENDPOINT_H
