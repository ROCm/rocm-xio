/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstring>

#include "gin-ep/doca_gpunetio_host.hip.h"
#include "hip/hip_runtime.h"

/*
 * Test scope: doca_gpu_mem_alloc()/doca_gpu_mem_free() semantics for the
 * DOCA-compatible gin-ep host API.
 *
 * Host-side hipified DOCA APIs explicitly exercised by this test:
 * - doca_gpu_create()
 * - doca_gpu_mem_alloc() with DOCA_GPU_MEM_TYPE_GPU
 * - doca_gpu_mem_alloc() with DOCA_GPU_MEM_TYPE_GPU_CPU
 * - doca_gpu_mem_alloc() with DOCA_GPU_MEM_TYPE_CPU_GPU
 * - doca_gpu_mem_free()
 * - doca_gpu_destroy()
 *
 * Device-side validation in this test (not DOCA device API calls):
 * - fill_u32_kernel(): writes deterministic data into GPU-only allocation.
 * - sum_u32_kernel(): validates GPU read visibility by reducing test buffers.
 * - host_visible_write_kernel(): validates GPU->host visibility with
 *   __threadfence_system().
 *
 * What this test validates:
 * 1) DOCA_GPU_MEM_TYPE_GPU:
 *    - API contract for pointer visibility (GPU pointer valid, CPU alias null).
 *    - Device-side usability by writing and reducing on GPU, then checking an
 *      independently computed expected sum on host.
 * 2) DOCA_GPU_MEM_TYPE_GPU_CPU:
 *    - Host writes are visible to GPU reads.
 *    - Validation is done by host initializing a pattern, GPU reducing it, and
 *      host checking exact expected sum.
 * 3) DOCA_GPU_MEM_TYPE_CPU_GPU:
 *    - GPU writes become visible to host after system-scope fence +
 *      synchronization.
 *    - Validation is done by GPU writing a marker value that host reads back.
 *
 * What this test does NOT validate:
 * - NIC-backed verbs behavior (WQE posting, CQE completion, doorbell/UAR MMIO).
 * - End-to-end network transport correctness.
 * - Performance characteristics or latency/throughput benchmarking.
 */

static int hip_to_errno(hipError_t err) {
  switch (err) {
    case hipErrorInvalidValue:
      return EINVAL;
    case hipErrorOutOfMemory:
      return ENOMEM;
    case hipErrorNoDevice:
      return ENODEV;
    default:
      return EIO;
  }
}

static int doca_to_errno(doca_error_t err) {
  switch (err) {
    case DOCA_SUCCESS:
      return 0;
    case DOCA_ERROR_INVALID_VALUE:
      return EINVAL;
    case DOCA_ERROR_NO_MEMORY:
      return ENOMEM;
    case DOCA_ERROR_NOT_SUPPORTED:
      return ENOTSUP;
    case DOCA_ERROR_NOT_FOUND:
      return ENOENT;
    case DOCA_ERROR_TIME_OUT:
      return ETIMEDOUT;
    default:
      return EIO;
  }
}

#define HIP_CHECK(cmd)                                                         \
  do {                                                                         \
    hipError_t _err = (cmd);                                                   \
    if (_err != hipSuccess) {                                                  \
      errno = hip_to_errno(_err);                                              \
      std::fprintf(stderr, "HIP error %s errno=%d (%s) at %s:%d\n",            \
                   hipGetErrorString(_err), errno, std::strerror(errno),       \
                   __FILE__, __LINE__);                                        \
      return 1;                                                                \
    }                                                                          \
  } while (0)

#define TEST_DOCA_CHECK(cmd)                                                   \
  do {                                                                         \
    doca_error_t _err = (cmd);                                                 \
    if (_err != DOCA_SUCCESS) {                                                \
      errno = doca_to_errno(_err);                                             \
      std::fprintf(stderr, "DOCA error %d errno=%d (%s) at %s:%d\n",           \
                   static_cast<int>(_err), errno, std::strerror(errno),        \
                   __FILE__, __LINE__);                                        \
      return 1;                                                                \
    }                                                                          \
  } while (0)

__global__ void fill_u32_kernel(uint32_t* ptr, uint32_t value, size_t n) {
  const size_t tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid >= n)
    return;
  ptr[tid] = value + static_cast<uint32_t>(tid);
}

__global__ void sum_u32_kernel(const uint32_t* ptr, uint64_t* out_sum,
                               size_t n) {
  __shared__ uint64_t partial[256];
  const size_t tid = blockIdx.x * blockDim.x + threadIdx.x;
  uint64_t v = 0;
  if (tid < n)
    v = ptr[tid];
  partial[threadIdx.x] = v;
  __syncthreads();
  for (int stride = blockDim.x / 2; stride > 0; stride >>= 1) {
    if (threadIdx.x < static_cast<unsigned>(stride)) {
      partial[threadIdx.x] += partial[threadIdx.x + stride];
    }
    __syncthreads();
  }
  if (threadIdx.x == 0)
    atomicAdd(reinterpret_cast<unsigned long long*>(out_sum), partial[0]);
}

__global__ void host_visible_write_kernel(uint32_t* mapped_ptr,
                                          uint32_t marker) {
  if (blockIdx.x == 0 && threadIdx.x == 0) {
    mapped_ptr[0] = marker;
    __threadfence_system();
  }
}

static uint64_t expected_sum(uint32_t base, size_t n) {
  return static_cast<uint64_t>(n) * static_cast<uint64_t>(base) +
         (static_cast<uint64_t>(n) * (n - 1)) / 2;
}

int main(int argc, char** argv) {
  bool run_device = true;
  bool run_host = true;
  bool saw_mode_flag = false;

  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--device") == 0) {
      run_device = true;
      if (!saw_mode_flag)
        run_host = false;
      saw_mode_flag = true;
    } else if (std::strcmp(argv[i], "--host") == 0) {
      run_host = true;
      if (!saw_mode_flag)
        run_device = false;
      saw_mode_flag = true;
    } else {
      errno = EINVAL;
      std::fprintf(stderr, "Usage: %s [--host] [--device] errno=%d (%s)\n",
                   argv[0], errno, std::strerror(errno));
      return 64;
    }
  }

  if (!run_device && !run_host) {
    errno = EINVAL;
    std::fprintf(stderr, "At least one mode must be enabled errno=%d (%s)\n",
                 errno, std::strerror(errno));
    return 64;
  }

  int rc = 0;
  int device_count = 0;
  HIP_CHECK(hipGetDeviceCount(&device_count));
  if (device_count == 0) {
    errno = ENODEV;
    std::fprintf(stderr, "No HIP device found errno=%d (%s)\n", errno,
                 std::strerror(errno));
    return 1;
  }

  int dev = 0;
  HIP_CHECK(hipGetDevice(&dev));
  char pci_bus_id[32] = {0};
  HIP_CHECK(hipDeviceGetPCIBusId(pci_bus_id, sizeof(pci_bus_id), dev));

  doca_gpu* gpu = nullptr;
  TEST_DOCA_CHECK(doca_gpu_create(pci_bus_id, &gpu));

  constexpr size_t kCount = 1024;
  constexpr size_t kBytes = kCount * sizeof(uint32_t);
  constexpr uint32_t kBase = 0x1234U;

  uint64_t* d_sum = nullptr;
  HIP_CHECK(hipMalloc(&d_sum, sizeof(uint64_t)));
  uint64_t got_sum = 0;
  uint32_t* gpu_only = nullptr;
  uint32_t* gpu_cpu_gpu = nullptr;
  uint32_t* gpu_cpu_host = nullptr;
  uint32_t* cpu_gpu_gpu = nullptr;
  uint32_t* cpu_gpu_host = nullptr;

  if (run_device) {
    void* cpu_alias = nullptr;
    TEST_DOCA_CHECK(doca_gpu_mem_alloc(gpu, kBytes, 0, DOCA_GPU_MEM_TYPE_GPU,
                                       reinterpret_cast<void**>(&gpu_only),
                                       &cpu_alias));
    if (cpu_alias != nullptr) {
      errno = EINVAL;
      std::fprintf(stderr,
                   "Expected null CPU pointer for GPU-only allocation errno=%d "
                   "(%s) cpu_alias=%p\n",
                   errno, std::strerror(errno), cpu_alias);
      rc = 2;
      goto cleanup;
    }
    HIP_CHECK(hipMemset(d_sum, 0, sizeof(uint64_t)));
    hipLaunchKernelGGL(fill_u32_kernel, dim3((kCount + 255) / 256), dim3(256),
                       0, 0, gpu_only, kBase, kCount);
    HIP_CHECK(hipGetLastError());
    hipLaunchKernelGGL(sum_u32_kernel, dim3((kCount + 255) / 256), dim3(256), 0,
                       0, gpu_only, d_sum, kCount);
    HIP_CHECK(hipGetLastError());
    HIP_CHECK(hipDeviceSynchronize());

    HIP_CHECK(
      hipMemcpy(&got_sum, d_sum, sizeof(got_sum), hipMemcpyDeviceToHost));
    const uint64_t exp_sum = expected_sum(kBase, kCount);
    if (got_sum != exp_sum) {
      errno = EIO;
      std::fprintf(stderr,
                   "GPU-only alloc mismatch got=%" PRIu64 " expected=%" PRIu64
                   " errno=%d (%s)\n",
                   got_sum, exp_sum, errno, std::strerror(errno));
      rc = 3;
      goto cleanup;
    }
  }

  if (run_host) {
    TEST_DOCA_CHECK(
      doca_gpu_mem_alloc(gpu, kBytes, 0, DOCA_GPU_MEM_TYPE_GPU_CPU,
                         reinterpret_cast<void**>(&gpu_cpu_gpu),
                         reinterpret_cast<void**>(&gpu_cpu_host)));
    if (gpu_cpu_gpu == nullptr || gpu_cpu_host == nullptr) {
      errno = (gpu_cpu_gpu == nullptr && gpu_cpu_host == nullptr) ? ENOMEM
                                                                  : EFAULT;
      std::fprintf(stderr,
                   "GPU_CPU alloc returned null pointers errno=%d (%s) "
                   "gpu_ptr=%p host_ptr=%p\n",
                   errno, std::strerror(errno), static_cast<void*>(gpu_cpu_gpu),
                   static_cast<void*>(gpu_cpu_host));
      rc = 4;
      goto cleanup;
    }
    for (size_t i = 0; i < kCount; ++i)
      gpu_cpu_host[i] = static_cast<uint32_t>(i ^ 0x55aaU);
    HIP_CHECK(hipMemset(d_sum, 0, sizeof(uint64_t)));
    hipLaunchKernelGGL(sum_u32_kernel, dim3((kCount + 255) / 256), dim3(256), 0,
                       0, gpu_cpu_gpu, d_sum, kCount);
    HIP_CHECK(hipGetLastError());
    HIP_CHECK(hipDeviceSynchronize());
    HIP_CHECK(
      hipMemcpy(&got_sum, d_sum, sizeof(got_sum), hipMemcpyDeviceToHost));
    uint64_t exp_host_sum = 0;
    for (size_t i = 0; i < kCount; ++i)
      exp_host_sum += static_cast<uint64_t>(i ^ 0x55aaU);
    if (got_sum != exp_host_sum) {
      errno = EIO;
      std::fprintf(stderr,
                   "GPU_CPU visibility mismatch got=%" PRIu64
                   " expected=%" PRIu64 " errno=%d (%s)\n",
                   got_sum, exp_host_sum, errno, std::strerror(errno));
      rc = 5;
      goto cleanup;
    }

    TEST_DOCA_CHECK(
      doca_gpu_mem_alloc(gpu, kBytes, 0, DOCA_GPU_MEM_TYPE_CPU_GPU,
                         reinterpret_cast<void**>(&cpu_gpu_gpu),
                         reinterpret_cast<void**>(&cpu_gpu_host)));
    if (cpu_gpu_gpu == nullptr || cpu_gpu_host == nullptr) {
      errno = (cpu_gpu_gpu == nullptr && cpu_gpu_host == nullptr) ? ENOMEM
                                                                  : EFAULT;
      std::fprintf(stderr,
                   "CPU_GPU alloc returned null pointers errno=%d (%s) "
                   "gpu_ptr=%p host_ptr=%p\n",
                   errno, std::strerror(errno), static_cast<void*>(cpu_gpu_gpu),
                   static_cast<void*>(cpu_gpu_host));
      rc = 6;
      goto cleanup;
    }
    std::memset(cpu_gpu_host, 0, kBytes);
    const uint32_t marker = 0xdec0deU;
    hipLaunchKernelGGL(host_visible_write_kernel, dim3(1), dim3(1), 0, 0,
                       cpu_gpu_gpu, marker);
    HIP_CHECK(hipGetLastError());
    HIP_CHECK(hipDeviceSynchronize());
    if (cpu_gpu_host[0] != marker) {
      errno = EIO;
      std::fprintf(stderr,
                   "CPU_GPU host visibility mismatch got=0x%x expected=0x%x "
                   "errno=%d (%s)\n",
                   cpu_gpu_host[0], marker, errno, std::strerror(errno));
      rc = 7;
      goto cleanup;
    }
  }

cleanup:
  if (cpu_gpu_gpu != nullptr)
    TEST_DOCA_CHECK(doca_gpu_mem_free(gpu, cpu_gpu_gpu));
  if (gpu_cpu_gpu != nullptr)
    TEST_DOCA_CHECK(doca_gpu_mem_free(gpu, gpu_cpu_gpu));
  if (gpu_only != nullptr)
    TEST_DOCA_CHECK(doca_gpu_mem_free(gpu, gpu_only));
  if (d_sum != nullptr)
    HIP_CHECK(hipFree(d_sum));
  if (gpu != nullptr)
    TEST_DOCA_CHECK(doca_gpu_destroy(gpu));

  if (rc == 0) {
    std::printf("PASS: alloc/mapped-memory semantics test mode=%s%s%s\n",
                run_device ? "device" : "", (run_device && run_host) ? "+" : "",
                run_host ? "host" : "");
  }
  return rc;
}
