/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <iostream>

#include <hip/hip_runtime.h>
#include "test-ep.h"

__host__ __device__ sqeType sqeRead(volatile sqeType *sqeAddress)
{

	sqeType sqeData;

	sqeData = *sqeAddress;

	return sqeData;
}

__host__ __device__ sqeType cqeRead(volatile cqeType *cqeAddress)
{

	cqeType cqeData;

	cqeData = *cqeAddress;

	return cqeData;
}

__host__ __device__ void sqeWrite(sqeType sqeData, sqeType *sqeAddress)
{
	*sqeAddress = sqeData;
#ifdef __HIP_DEVICE_COMPILE__
	__threadfence();
#endif // __HIP_DEVICE_COMPILE__
}

__host__ __device__ void cqeWrite(cqeType cqeData, cqeType *cqeAddress)
{

	*cqeAddress = cqeData;
#ifdef __HIP_DEVICE_COMPILE__
	__threadfence();
#endif // __HIP_DEVICE_COMPILE__	
}

__host__ __device__ sqeType sqePoll(sqeType sqeLast, sqeType
									*sqeAddress)
{
	volatile sqeType sqeNew;

	while (true)
	{
		sqeNew = sqeRead(sqeAddress);
		if (sqeNew && sqeNew != sqeLast)
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
		if (cqeNew && cqeNew != cqeLast)
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

__host__  void emulateTestEndpoint(unsigned sqeIterations,
				      sqeType *sqeAddr,
				      cqeType *cqeAddr) {
	
	sqeType sqeOld, sqeNew = 0xbeefdead;
	cqeType cqeLocal;

	while (sqeNew != 0xf0f0f0f0)
	{
		sqeNew = sqeRead(sqeAddr);
		cqeLocal = cqeGenFromSqe(sqeNew);
		cqeWrite(cqeLocal, cqeAddr);
	}
}

__host__ unsigned long long int wall_clock64() {
	return 0;
}

__device__ void driveTestEndpoint(unsigned sqeIterations,
				      sqeType *sqeAddr,
					  cqeType *cqeAddr,
					  unsigned long long int *start_time,
					  unsigned long long int *end_time) {
	
	sqeType sqeLocal = 0xdeadbeef;
	cqeType cqeLocal = 0xdeadbeef;
	unsigned sqeCount = 0;

	while (sqeCount < sqeIterations)
	{
		start_time[sqeCount] = wall_clock64();
		sqeWrite(sqeLocal, sqeAddr);
	    //cqeLocal = cqePoll(cqeLocal, cqeAddr);
		end_time[sqeCount] = wall_clock64();
		sqeCount++;
		sqeLocal = 0xbeefdeaf + sqeCount;
	}
	sqeWrite(0xf0f0f0f0, sqeAddr);
}
