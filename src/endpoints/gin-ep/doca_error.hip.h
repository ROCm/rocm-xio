/*
 * SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION &
 * AFFILIATES. All rights reserved.
 * SPDX-FileCopyrightText: Modifications Copyright (c) 2025-2026 Advanced
 * Micro Devices, Inc. All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

#ifndef DOCA_ERROR_HIP_H
#define DOCA_ERROR_HIP_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum doca_error {
  DOCA_SUCCESS = 0,
  DOCA_ERROR_UNKNOWN = 1,
  DOCA_ERROR_NOT_PERMITTED = 2,
  DOCA_ERROR_IN_USE = 3,
  DOCA_ERROR_NOT_SUPPORTED = 4,
  DOCA_ERROR_AGAIN = 5,
  DOCA_ERROR_INVALID_VALUE = 6,
  DOCA_ERROR_NO_MEMORY = 7,
  DOCA_ERROR_INITIALIZATION = 8,
  DOCA_ERROR_TIME_OUT = 9,
  DOCA_ERROR_SHUTDOWN = 10,
  DOCA_ERROR_CONNECTION_RESET = 11,
  DOCA_ERROR_CONNECTION_ABORTED = 12,
  DOCA_ERROR_CONNECTION_INPROGRESS = 13,
  DOCA_ERROR_NOT_CONNECTED = 14,
  DOCA_ERROR_NO_LOCK = 15,
  DOCA_ERROR_NOT_FOUND = 16,
  DOCA_ERROR_IO_FAILED = 17,
  DOCA_ERROR_BAD_STATE = 18,
  DOCA_ERROR_UNSUPPORTED_VERSION = 19,
  DOCA_ERROR_OPERATING_SYSTEM = 20,
  DOCA_ERROR_DRIVER = 21,
  DOCA_ERROR_UNEXPECTED = 22,
  DOCA_ERROR_ALREADY_EXIST = 23,
  DOCA_ERROR_FULL = 24,
  DOCA_ERROR_EMPTY = 25,
  DOCA_ERROR_IN_PROGRESS = 26,
  DOCA_ERROR_TOO_BIG = 27,
  DOCA_ERROR_AUTHENTICATION = 28,
  DOCA_ERROR_BAD_CONFIG = 29,
  DOCA_ERROR_SKIPPED = 30,
  DOCA_ERROR_DEVICE_FATAL_ERROR = 31
} doca_error_t;

#ifdef __cplusplus
}
#endif

#endif
