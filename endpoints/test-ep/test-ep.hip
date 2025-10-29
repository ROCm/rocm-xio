/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <iostream>

#include <hip/hip_runtime.h>
#include <axiio.h>

__host__ __device__ sqeType sqeRead(volatile sqeType *sqeAddress)
{
	return *sqeAddress;
}

__host__ __device__ sqeType cqeRead(volatile cqeType *cqeAddress)
{
	return *cqeAddress;
}

__host__ __device__ void sqeWrite(sqeType sqeData, sqeType *sqeAddress)
{
	*sqeAddress = sqeData;
#ifdef __HIP_DEVICE_COMPILE__
	__threadfence_system();
#endif // __HIP_DEVICE_COMPILE__
}

__host__ __device__ void cqeWrite(cqeType cqeData, cqeType *cqeAddress)
{
	*cqeAddress = cqeData;
#ifdef __HIP_DEVICE_COMPILE__
	__threadfence_system();
#endif // __HIP_DEVICE_COMPILE__	
}

__host__ __device__ sqeType sqePoll(sqeType sqeLast,
	volatile sqeType *sqeAddress)
{
	sqeType sqeNew;
	while (true) {
		sqeNew = sqeRead(sqeAddress);
		if (sqeNew != sqeLast)
			return sqeNew;
	}
}

__host__ __device__ cqeType cqePoll(cqeType cqeLast,
	volatile cqeType *cqeAddress)
{
	cqeType cqeNew;
	while (true) {
		cqeNew = cqeRead(cqeAddress);
		if (cqeNew != cqeLast)
			return cqeNew;
	}
}

__host__ __device__ sqeType cqeGenFromSqe(sqeType sqeData) {
	return ~(cqeType)sqeData;
}

 __host__ __device__ void axiioEndPoint::emulateEndpoint(
	unsigned sqeIterations,
	sqeType *sqeAddr, cqeType *cqeAddr) {
	
	volatile sqeType sqeNew = 0xbeefdead;
	sqeType sqeOld=0xf000f000;
	cqeType cqeLocal;

	while (sqeNew != 0xf0f0f0f0)
	{
		sqeNew = sqePoll(sqeOld, sqeAddr);
	    //std::cout << std::hex << sqeOld << ": " << sqeNew << std::endl; 
		cqeLocal = cqeGenFromSqe(sqeNew);
		cqeWrite(cqeLocal, cqeAddr);
	}
}

__host__ unsigned long long int wall_clock64() {
	return 0;
}

__device__ void axiioEndPoint::driveEndpoint(
	unsigned sqeIterations, sqeType *sqeAddr,
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
	    cqeLocal = cqePoll(cqeLocal, cqeAddr);
		end_time[sqeCount] = wall_clock64();
		sqeCount++;
		sqeLocal = 0xbeefdeaf + sqeCount;
	}
	sqeWrite(0xf0f0f0f0, sqeAddr);
}

