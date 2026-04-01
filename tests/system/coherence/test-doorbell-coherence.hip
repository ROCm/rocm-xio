/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Coherence stress test for GPU-to-host doorbell ordering.
 *
 * Reproduces the access pattern from an external GPU-NVMe
 * coherence study (from-germany): a single GPU thread writes
 * sequential "commands" to a shared queue, rings a doorbell
 * (host-pinned memory standing in for BAR0 MMIO), and polls
 * for completions.  A host thread monitors the doorbell,
 * validates commands, and writes completions.
 *
 * The test passes if all iterations complete before the
 * timeout.  Deadlocks indicate that either the doorbell
 * write or the completion write is not visible across the
 * GPU/CPU coherence boundary.
 */

#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

#include <hip/hip_runtime.h>

#include "xio.h"

struct CoherenceCmd {
  volatile uint32_t cmd_id;
  volatile uint32_t payload;
};

struct CoherenceCpl {
  volatile uint32_t cpl_id;
  volatile uint32_t status;
};

__global__ void coherence_kernel(volatile CoherenceCmd* sq,
                                 volatile CoherenceCpl* cq,
                                 volatile uint32_t* doorbell,
                                 unsigned iterations) {
  for (unsigned i = 1; i <= iterations; i++) {
    sq->payload = i * 7;
    __threadfence_system();

    sq->cmd_id = i;
    __threadfence_system();

    xio::ringDoorbell(const_cast<volatile uint32_t*>(doorbell), i);

    while (cq->cpl_id != i) {
      ;
    }
    __threadfence_system();
  }
}

__global__ void coherence_kernel_fenced(volatile CoherenceCmd* sq,
                                        volatile CoherenceCpl* cq,
                                        volatile uint32_t* doorbell,
                                        unsigned iterations) {
  for (unsigned i = 1; i <= iterations; i++) {
    sq->payload = i * 7;
    __threadfence_system();

    sq->cmd_id = i;
    __threadfence_system();

    xio::ringDoorbellFenced(const_cast<volatile uint32_t*>(doorbell), i);

    while (cq->cpl_id != i) {
      ;
    }
    __threadfence_system();
  }
}

struct SharedState {
  CoherenceCmd* sq;
  CoherenceCpl* cq;
  uint32_t* doorbell;
  unsigned iterations;
  std::atomic<bool> host_done{false};
  std::atomic<bool> error{false};
};

static void host_responder(SharedState* state) {
  volatile CoherenceCmd* sq = state->sq;
  volatile CoherenceCpl* cq = state->cq;
  volatile uint32_t* db = state->doorbell;

  for (unsigned expected = 1; expected <= state->iterations; expected++) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);

    while (*db < expected) {
      if (std::chrono::steady_clock::now() > deadline) {
        fprintf(stderr,
                "Host responder timed out waiting for "
                "doorbell %u (current=%u)\n",
                expected, *db);
        state->error.store(true);
        state->host_done.store(true);
        return;
      }
      std::this_thread::yield();
    }

    uint32_t observed_id = sq->cmd_id;
    uint32_t observed_payload = sq->payload;

    if (observed_id != expected) {
      fprintf(stderr,
              "Command mismatch: expected cmd_id=%u, "
              "got %u\n",
              expected, observed_id);
      state->error.store(true);
    }
    if (observed_payload != expected * 7) {
      fprintf(stderr,
              "Payload mismatch at cmd %u: expected %u, "
              "got %u\n",
              expected, expected * 7, observed_payload);
      state->error.store(true);
    }

    cq->cpl_id = expected;
    __sync_synchronize();
  }

  state->host_done.store(true);
}

static int run_test(const char* label, bool use_fenced) {
  static constexpr unsigned kIterations = 4096;

  CoherenceCmd* sq = nullptr;
  CoherenceCpl* cq = nullptr;
  uint32_t* doorbell = nullptr;

  HIP_CHECK(hipHostMalloc(&sq, sizeof(CoherenceCmd), hipHostMallocDefault));
  HIP_CHECK(hipHostMalloc(&cq, sizeof(CoherenceCpl), hipHostMallocDefault));
  HIP_CHECK(hipHostMalloc(&doorbell, sizeof(uint32_t), hipHostMallocDefault));

  memset((void*)sq, 0, sizeof(CoherenceCmd));
  memset((void*)cq, 0, sizeof(CoherenceCpl));
  *doorbell = 0;

  SharedState state;
  state.sq = sq;
  state.cq = cq;
  state.doorbell = doorbell;
  state.iterations = kIterations;

  std::thread responder(host_responder, &state);

  if (use_fenced) {
    hipLaunchKernelGGL(coherence_kernel_fenced, dim3(1), dim3(1), 0, 0, sq, cq,
                       doorbell, kIterations);
  } else {
    hipLaunchKernelGGL(coherence_kernel, dim3(1), dim3(1), 0, 0, sq, cq,
                       doorbell, kIterations);
  }

  HIP_CHECK(hipPeekAtLastError());

  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);

  hipError_t sync_err = hipErrorNotReady;
  while (sync_err == hipErrorNotReady) {
    sync_err = hipStreamQuery(0);
    if (sync_err == hipSuccess)
      break;
    if (sync_err != hipErrorNotReady) {
      fprintf(stderr, "%s: kernel error: %s\n", label,
              hipGetErrorString(sync_err));
      break;
    }
    if (std::chrono::steady_clock::now() > deadline) {
      fprintf(stderr,
              "%s: DEADLOCK detected -- kernel did not "
              "complete within 30 seconds\n",
              label);
      sync_err = hipErrorLaunchTimeOut;
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }

  responder.join();

  int result = 0;
  if (sync_err != hipSuccess) {
    fprintf(stderr, "%s: FAILED (kernel error)\n", label);
    result = 1;
  } else if (state.error.load()) {
    fprintf(stderr, "%s: FAILED (data mismatch)\n", label);
    result = 1;
  } else {
    printf("%s: PASSED (%u iterations)\n", label, kIterations);
  }

  HIP_CHECK(hipHostFree(sq));
  HIP_CHECK(hipHostFree(cq));
  HIP_CHECK(hipHostFree(doorbell));

  return result;
}

int main() {
  int failures = 0;

  printf("=== Doorbell coherence stress test ===\n");
  printf("Tests GPU->host doorbell visibility with "
         "sequential producer/consumer pattern\n\n");

  failures += run_test("threadfence_system doorbell", false);
  failures += run_test("ISA-fenced doorbell", true);

  if (failures == 0) {
    printf("\nAll doorbell coherence tests passed.\n");
    return 0;
  }
  printf("\n%d doorbell coherence test(s) failed.\n", failures);
  return 1;
}
