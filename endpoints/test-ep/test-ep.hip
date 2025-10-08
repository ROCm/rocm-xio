/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <hip/hip_runtime.h>

#define SQE_MAGIC 0xde

typedef long long sqeType;
typedef long cqeType;

__host__ __device__ sqeType sqeRead(sqeType *sqeAddress) {

	volatile sqeType sqeData;

	sqeData = *sqeAddress;

	return sqeData;
}

__host__ __device__ void cqeWrite(cqeType cqeData, cqeType *cqeAddress) {

	*cqeAddress = cqeData;
}

__host__ __device__ sqeType sqePoll(sqeType sqeLast, sqeType
				    *sqeAddress) {
	volatile sqeType sqeNew;

	while (true) {
		sqeNew = sqeRead(sqeAddress);
		if (sqeNew != sqeLast) {
			return sqeNew;
		}
	}
}

__host__ __device__ sqeType cqeGenFromSqe(sqeType sqeData) {

	cqeType cqeNew;

	cqeNew = ~(cqeType)sqeData;

	return cqeNew;
}

__host__ __device__ void testEndpoint(unsigned sqeIterations,
				      sqeType *sqeAddr,
				      cqeType *cqeAddr) {
	sqeType sqeData = 1;
	cqeType cqeData;
	unsigned sqeCount = 0;

	while (sqeCount < sqeIterations) {

		sqeData = sqePoll(sqeData, sqeAddr);
		cqeData = cqeGenFromSqe(sqeData);
		cqeWrite(cqeData, cqeAddr);
		sqeCount++;
	}
}
