/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef AXIIO_ENDPOINTS_H
#define AXIIO_ENDPOINTS_H

#include <hip/hip_runtime.h>

typedef long long sqeType;
typedef long cqeType;

class axiioEndPoint {
public:
    __device__ void driveEndpoint(unsigned, sqeType *, cqeType *,
        unsigned long long int *, unsigned long long int *);
    __host__ __device__ void emulateEndpoint(unsigned, sqeType *, cqeType *);
};

#endif // AXIIO_ENDPOINTS_H
