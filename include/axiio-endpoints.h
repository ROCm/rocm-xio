/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef AXIIO_ENDPOINTS_H
#define AXIIO_ENDPOINTS_H

#include <hip/hip_runtime.h>

// Include test endpoint type definitions
#include "test-ep.h"

class axiioEndPoint {
public:
  typedef struct sqeType_s sqeType;
  typedef struct cqeType_s cqeType;

  __device__ void driveEndpoint(unsigned, sqeType*, cqeType*,
                                unsigned long long int*,
                                unsigned long long int*);
  __host__ __device__ void emulateEndpoint(unsigned, sqeType*, cqeType*);
};

#endif // AXIIO_ENDPOINTS_H
