/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <iostream>
#include <cstring>

#include <hip/hip_runtime.h>
#include "test-ep.h"
#include <axiio.h>

// Type aliases for convenience (types defined in test-ep.h)
typedef axiioEndPoint::sqeType sqeType;
typedef axiioEndPoint::cqeType cqeType;

// Helper function to compare sqeType structs
__host__ __device__ bool sqeEqual(const sqeType *a, const sqeType *b)
{
	return (a->dataPayload == b->dataPayload &&
	        a->entryId == b->entryId &&
	        a->magicID == b->magicID);
}

// Helper function to compare cqeType structs
__host__ __device__ bool cqeEqual(const cqeType *a, const cqeType *b)
{
	return (a->dataPayload == b->dataPayload &&
	        a->entryId == b->entryId &&
	        a->magicID == b->magicID);
}

__host__ __device__ sqeType sqeRead(volatile sqeType *sqeAddress)
{
	sqeType result;
	result.magicID = sqeAddress->magicID;
	result.entryId = sqeAddress->entryId;
	result.timeStamp = sqeAddress->timeStamp;
	result.dataPayload = sqeAddress->dataPayload;
	return result;
}

__host__ __device__ cqeType cqeRead(volatile cqeType *cqeAddress)
{
	cqeType result;
	result.magicID = cqeAddress->magicID;
	result.entryId = cqeAddress->entryId;
	result.dataPayload = cqeAddress->dataPayload;
	return result;
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
		if (sqeNew.magicID == TEST_EP_MAGIC_ID &&
		    !sqeEqual(&sqeNew, &sqeLast))
			return sqeNew;
	}
}

__host__ __device__ cqeType cqePoll(cqeType cqeLast,
	volatile cqeType *cqeAddress)
{
	cqeType cqeNew;
	while (true) {
		cqeNew = cqeRead(cqeAddress);
		if (cqeNew.magicID == TEST_EP_MAGIC_ID &&
		    !cqeEqual(&cqeNew, &cqeLast))
			return cqeNew;
	}
}

__host__ __device__ cqeType cqeGenFromSqe(const sqeType *sqeData) {
	cqeType result;
	result.magicID = TEST_EP_MAGIC_ID;
	result.entryId = sqeData->entryId;
	result.dataPayload = ~sqeData->dataPayload;
	return result;
}

 __host__ __device__ void axiioEndPoint::emulateEndpoint(
	unsigned sqeIterations,
	sqeType *sqeAddr, cqeType *cqeAddr) {

	sqeType sqeNew = {TEST_EP_MAGIC_ID, 0, 0, 0xbeefdead, {0}};
	sqeType sqeOld = {TEST_EP_MAGIC_ID, 0, 0, 0xf000f000, {0}};
	sqeType sqeStop = {TEST_EP_MAGIC_ID, 0xFFFF, 0, 0xf0f0f0f0, {0}};
	cqeType cqeLocal;

	while (!sqeEqual(&sqeNew, &sqeStop))
	{
		sqeNew = sqePoll(sqeOld, sqeAddr);
		cqeLocal = cqeGenFromSqe(&sqeNew);
		cqeWrite(cqeLocal, cqeAddr);
		sqeOld = sqeNew;
	}
}

__host__ unsigned long long int wall_clock64() {
	return 0;
}

__device__ void axiioEndPoint::driveEndpoint(
	unsigned sqeIterations, sqeType *sqeAddr,
	cqeType *cqeAddr,
	unsigned long long int *startTime,
	unsigned long long int *endTime) {

	sqeType sqeLocal = {TEST_EP_MAGIC_ID, 0, 0, 0xdeadbeef, {0}};
	cqeType cqeLocal = {TEST_EP_MAGIC_ID, 0, 0xdeadbeef, {0}};
	sqeType sqeStop = {TEST_EP_MAGIC_ID, 0xFFFF, 0, 0xf0f0f0f0, {0}};
	unsigned sqeCount = 0;

	while (sqeCount < sqeIterations)
	{
		sqeLocal.entryId = sqeCount;
		startTime[sqeCount] = wall_clock64();
		sqeWrite(sqeLocal, sqeAddr);
		cqeLocal = cqePoll(cqeLocal, cqeAddr);
		endTime[sqeCount] = wall_clock64();
		sqeCount++;
		sqeLocal.dataPayload = 0xbeefdeaf + sqeCount;
	}
	sqeWrite(sqeStop, sqeAddr);
}

