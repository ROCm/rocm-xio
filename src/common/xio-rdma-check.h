/* Copyright (c) Advanced Micro Devices, Inc.
 * All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Shared error-checking macros and dlsym helpers for
 * the rdma-ep vendor backends and common wrappers.
 */

#ifndef XIO_RDMA_CHECK_H
#define XIO_RDMA_CHECK_H

#include <cstdio>
#include <cstdlib>

#include <dlfcn.h>

/*
 * _XIO_CHECK_ZERO -- assert expr == 0, else print
 *                    and execute 'on_fail'.
 * _XIO_CHECK_NNULL -- assert expr != NULL, else print
 *                     and execute 'on_fail'.
 *
 * Backends define 2-arg convenience wrappers:
 *   #define XIO_CHECK_ZERO(expr, msg) \
 *     _XIO_CHECK_ZERO("rdma_ep::bnxt", (expr), (msg), return)
 */
#define _XIO_CHECK_ZERO(prefix, expr, msg, on_fail)                            \
  do {                                                                         \
    int _err = (expr);                                                         \
    if (_err != 0) {                                                           \
      fprintf(stderr,                                                          \
              "%s: %s failed: "                                                \
              "%d at %s:%d\n",                                                 \
              (prefix), (msg), _err, __FILE__, __LINE__);                      \
      on_fail;                                                                 \
    }                                                                          \
  } while (0)

#define _XIO_CHECK_NNULL(prefix, expr, msg, on_fail)                           \
  do {                                                                         \
    if (!(expr)) {                                                             \
      fprintf(stderr,                                                          \
              "%s: %s returned "                                               \
              "null at %s:%d\n",                                               \
              (prefix), (msg), __FILE__, __LINE__);                            \
      on_fail;                                                                 \
    }                                                                          \
  } while (0)

namespace xio_rdma {

template <typename FuncPtr>
int dlsym_load(FuncPtr& out, void* handle, const char* name,
               const char* vendor_tag) {
  out = reinterpret_cast<FuncPtr>(dlsym(handle, name));
  if (!out) {
    fprintf(stderr,
            "%s: dlsym failed for "
            "%s: %s\n",
            vendor_tag, name, dlerror());
    return -1;
  }
  return 0;
}

template <typename FuncPtr>
int dlsym_load_optional(FuncPtr& out, void* handle, const char* name) {
  out = reinterpret_cast<FuncPtr>(dlsym(handle, name));
  return out ? 0 : -1;
}

template <typename FuncPtr>
int dlsym_load_prefixed(FuncPtr& out, void* handle, const char* prefix,
                        const char* name) {
  char full_name[256];
  snprintf(full_name, sizeof(full_name), "%s%s", prefix, name);
  out = reinterpret_cast<FuncPtr>(dlsym(handle, full_name));
  if (!out) {
    fprintf(stderr, "rdma_ep: dlsym failed for %s: %s\n", full_name, dlerror());
    return -1;
  }
  return 0;
}

template <typename FuncPtr>
void dlsym_load_prefixed_optional(FuncPtr& out, void* handle,
                                  const char* prefix, const char* name) {
  char full_name[256];
  snprintf(full_name, sizeof(full_name), "%s%s", prefix, name);
  out = reinterpret_cast<FuncPtr>(dlsym(handle, full_name));
}

inline void* dv_dlopen(const char* lib_name, const char* vendor_tag,
                       const char* const* extra_paths = nullptr,
                       int n_extra = 0) {
  constexpr int flags = RTLD_LAZY | RTLD_DEEPBIND;
  void* handle = nullptr;

#ifdef RDMA_CORE_LIB_DIR
  {
    char path[512];
    snprintf(path, sizeof(path), "%s/%s", RDMA_CORE_LIB_DIR, lib_name);
    handle = dlopen(path, flags);
  }
#endif

  if (!handle)
    handle = dlopen(lib_name, flags);

  for (int i = 0; !handle && i < n_extra; i++) {
    char path[512];
    snprintf(path, sizeof(path), "%s/%s", extra_paths[i], lib_name);
    handle = dlopen(path, flags);
  }

  if (!handle) {
    char path[512];
    snprintf(path, sizeof(path), "/usr/local/lib/%s", lib_name);
    handle = dlopen(path, flags);
  }

  if (!handle)
    fprintf(stderr,
            "%s: Could not open "
            "%s: %s\n",
            vendor_tag, lib_name, dlerror());
  return handle;
}

} // namespace xio_rdma

#endif /* XIO_RDMA_CHECK_H */
