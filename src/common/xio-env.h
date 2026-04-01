/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef XIO_ENV_H
#define XIO_ENV_H

#include <cstdio>

namespace xio {

enum LogLevel : int {
  LOG_NONE = 0,
  LOG_ERROR = 1,
  LOG_WARN = 2,
  LOG_INFO = 3,
  LOG_DEBUG = 4,
  LOG_TRACE = 5
};

int getEnvInt(const char* name, int defaultVal);
const char* getEnvStr(const char* name, const char* defaultVal);

int rocxioLogLevel();
bool rocxioVerbose();

} // namespace xio

#define ROCXIO_LOG_ERROR(fmt, ...)                                             \
  do {                                                                         \
    if (xio::rocxioLogLevel() >= xio::LOG_ERROR)                               \
      fprintf(stderr, "rocm-xio ERROR: " fmt, ##__VA_ARGS__);                  \
  } while (0)

#define ROCXIO_LOG_WARN(fmt, ...)                                              \
  do {                                                                         \
    if (xio::rocxioLogLevel() >= xio::LOG_WARN)                                \
      fprintf(stderr, "rocm-xio WARN: " fmt, ##__VA_ARGS__);                   \
  } while (0)

#define ROCXIO_LOG_INFO(fmt, ...)                                              \
  do {                                                                         \
    if (xio::rocxioLogLevel() >= xio::LOG_INFO)                                \
      fprintf(stdout, "rocm-xio INFO: " fmt, ##__VA_ARGS__);                   \
  } while (0)

#define ROCXIO_LOG_DEBUG(fmt, ...)                                             \
  do {                                                                         \
    if (xio::rocxioLogLevel() >= xio::LOG_DEBUG)                               \
      fprintf(stderr, "rocm-xio DEBUG: " fmt, ##__VA_ARGS__);                  \
  } while (0)

#define ROCXIO_LOG_TRACE(fmt, ...)                                             \
  do {                                                                         \
    if (xio::rocxioLogLevel() >= xio::LOG_TRACE)                               \
      fprintf(stderr, "rocm-xio TRACE: " fmt, ##__VA_ARGS__);                  \
  } while (0)

#endif // XIO_ENV_H
