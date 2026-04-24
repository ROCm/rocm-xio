/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Shared-library symbol visibility for librocm-xio.
 */

#ifndef XIO_EXPORT_H
#define XIO_EXPORT_H

#if defined(_WIN32) || defined(_WIN64)
#error "rocm-xio visibility macros are not defined for Windows builds"
#elif defined(ROCM_XIO_BUILDING_LIBRARY) && defined(ROCM_XIO_SHARED)
#define XIO_API __attribute__((visibility("default")))
#else
#define XIO_API
#endif

#endif /* XIO_EXPORT_H */
