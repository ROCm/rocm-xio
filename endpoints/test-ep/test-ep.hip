/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <hip/hip_runtime.h>
#include "test-ep.h"

__host__ __device__ sqeType sqeRead(sqeType *sqeAddress)
{

	volatile sqeType sqeData;

	sqeData = *sqeAddress;

	return sqeData;
}

__host__ __device__ sqeType cqeRead(cqeType *cqeAddress)
{

	volatile cqeType cqeData;

	cqeData = *cqeAddress;

	return cqeData;
}

__host__ __device__ void sqeWrite(sqeType sqeData, sqeType *sqeAddress)
{

	*sqeAddress = sqeData;
}

__host__ __device__ void cqeWrite(cqeType cqeData, cqeType *cqeAddress)
{

	*cqeAddress = cqeData;
}

__host__ __device__ sqeType sqePoll(sqeType sqeLast, sqeType
									*sqeAddress)
{
	volatile sqeType sqeNew;

	while (true)
	{
		sqeNew = sqeRead(sqeAddress);
		if (sqeNew != sqeLast)
		{
			return sqeNew;
		}
	}
}

__host__ __device__ cqeType cqePoll(cqeType cqeLast, cqeType
									*cqeAddress)
{
	volatile cqeType cqeNew;

	while (true)
	{
		cqeNew = cqeRead(cqeAddress);
		if (cqeNew != cqeLast)
		{
			return cqeNew;
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
	
	sqeType sqeLocal = 0xbeefdead;
	cqeType cqeLocal;

	while (sqeLocal != 0xF0F0F0F0)
	{
		sqeLocal = sqePoll(sqeLocal, sqeAddr);
		cqeLocal = cqeGenFromSqe(sqeLocal);
		cqeWrite(cqeLocal, cqeAddr);
	}
}

__host__ __device__ void driveTestEndpoint(unsigned sqeIterations,
				      sqeType *sqeAddr,
				      cqeType *cqeAddr) {
	
	sqeType sqeLocal = 0xbeefdead;
	cqeType cqeData;
	unsigned sqeCount = 0;

	while (sqeCount < sqeIterations)
	{
		sqeWrite(sqeLocal, sqeAddr);
		cqeData = cqePoll(cqeData, cqeAddr);
		sqeCount++;
		sqeLocal = 0xbeefdead + sqeCount;
	}
	sqeWrite(0xF0F0F0F0, sqeAddr);
}
