/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef AXIIO_TEST_ENDPOINT_H
#define AXIIO_TEST_ENDPOINT_H

#define TEST_EP_SQE_MAGIC 0xde

typedef long long sqeType;
typedef long cqeType;

__host__ __device__ void testEndpoint(unsigned sqeIterations,
				      sqeType *sqeAddr,
				      cqeType *cqeAddr);

__host__ __device__ void driveTestEndpoint(unsigned sqeIterations,
									  sqeType *sqeAddr,
									  cqeType *cqeAddr);

#endif //AXIIO_TEST_ENDPOINT_H
