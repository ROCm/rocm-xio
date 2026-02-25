/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstdio>

#include "doca/gin_gdaki.h"
#include "hip/hip_runtime.h"

#define HIP_CHECK(cmd)                                                         \
  do {                                                                         \
    hipError_t _err = (cmd);                                                   \
    if (_err != hipSuccess) {                                                  \
      std::fprintf(stderr, "HIP error %s at %s:%d\n", hipGetErrorString(_err), \
                   __FILE__, __LINE__);                                        \
      return 1;                                                                \
    }                                                                          \
  } while (0)

struct DoorbellTestResult {
  int doorbell_ok;
  uint64_t db_seen;
  uint64_t db_expected;
};

__global__ void doorbell_test_kernel(uint64_t* doorbell_addr,
                                     DoorbellTestResult* out) {
  if (blockIdx.x != 0 || threadIdx.x != 0)
    return;

  struct radaki_dev_qp qp = {};
  qp.sq_db = (uintptr_t)doorbell_addr;
  qp.sq_num_shift8_be = __builtin_bswap32(0x00def000U);

  const uint64_t prod_index = 17;
  radaki_dev_ring_db<DOCA_GPUNETIO_VERBS_SYNC_SCOPE_SYS>(&qp, prod_index);

  out->db_seen = *doorbell_addr;
  out->db_expected = static_cast<uint64_t>(
    radaki_dev_prepare_db(&qp, prod_index));
  out->doorbell_ok = (out->db_seen == out->db_expected);
}

int main() {
  int rc = 0;
  int device_count = 0;
  HIP_CHECK(hipGetDeviceCount(&device_count));
  if (device_count == 0) {
    std::fprintf(stderr, "No HIP device found.\n");
    return 1;
  }

  uint64_t* host_db_ptr = nullptr;
  uint64_t* dev_db_ptr = nullptr;
  DoorbellTestResult* dev_result = nullptr;
  DoorbellTestResult host_result = {};
  bool passed = false;

  HIP_CHECK(hipHostMalloc(reinterpret_cast<void**>(&host_db_ptr),
                          sizeof(uint64_t), hipHostMallocMapped));
  *host_db_ptr = 0;
  HIP_CHECK(hipHostGetDevicePointer(reinterpret_cast<void**>(&dev_db_ptr),
                                    host_db_ptr, 0));
  if (dev_db_ptr == nullptr) {
    std::fprintf(stderr, "Mapped doorbell device pointer is null.\n");
    rc = 2;
    goto cleanup;
  }

  HIP_CHECK(
    hipMalloc(reinterpret_cast<void**>(&dev_result), sizeof(*dev_result)));
  HIP_CHECK(hipMemset(dev_result, 0, sizeof(*dev_result)));

  hipLaunchKernelGGL(doorbell_test_kernel, dim3(1), dim3(1), 0, 0, dev_db_ptr,
                     dev_result);
  HIP_CHECK(hipGetLastError());
  HIP_CHECK(hipDeviceSynchronize());
  HIP_CHECK(hipMemcpy(&host_result, dev_result, sizeof(host_result),
                      hipMemcpyDeviceToHost));

  passed = (host_result.doorbell_ok == 1);
  if (!passed) {
    std::fprintf(stderr,
                 "FAILED doorbell=%d db_seen=0x%llx db_expected=0x%llx\n",
                 host_result.doorbell_ok,
                 static_cast<unsigned long long>(host_result.db_seen),
                 static_cast<unsigned long long>(host_result.db_expected));
    rc = 3;
  } else {
    std::printf("PASS: doorbell system-scope test db_ptr=%p db_seen=0x%llx "
                "db_expected=0x%llx\n",
                static_cast<void*>(host_db_ptr),
                static_cast<unsigned long long>(host_result.db_seen),
                static_cast<unsigned long long>(host_result.db_expected));
  }

cleanup:
  if (dev_result != nullptr)
    HIP_CHECK(hipFree(dev_result));
  if (host_db_ptr != nullptr)
    HIP_CHECK(hipHostFree(host_db_ptr));
  return rc;
}
