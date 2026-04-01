/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include "xio-env.h"

#include <cstdlib>
#include <cstring>

namespace xio {

int getEnvInt(const char* name, int defaultVal) {
  const char* val = std::getenv(name);
  if (!val || val[0] == '\0')
    return defaultVal;
  char* end = nullptr;
  long result = std::strtol(val, &end, 10);
  if (end == val || *end != '\0')
    return defaultVal;
  return static_cast<int>(result);
}

const char* getEnvStr(const char* name, const char* defaultVal) {
  const char* val = std::getenv(name);
  if (!val || val[0] == '\0')
    return defaultVal;
  return val;
}

int rocxioLogLevel() {
  static int level = [] {
    int v = getEnvInt("ROCXIO_LOG_LEVEL", LOG_WARN);
    if (rocxioVerbose() && v < LOG_INFO)
      v = LOG_INFO;
    if (v < LOG_NONE)
      return static_cast<int>(LOG_NONE);
    if (v > LOG_TRACE)
      return static_cast<int>(LOG_TRACE);
    return v;
  }();
  return level;
}

bool rocxioVerbose() {
  static bool verbose = [] {
    const char* val = std::getenv("ROCXIO_VERBOSE");
    if (!val)
      return false;
    return std::strcmp(val, "1") == 0 || std::strcmp(val, "true") == 0;
  }();
  return verbose;
}

} // namespace xio
