/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef TEST_EP_H
#define TEST_EP_H

#include <cstdint>
#include <thread>
#include <vector>

#include <hip/hip_runtime.h>

// Forward declaration - full definition in xio.h
namespace xio {
struct XioEndpointConfig;
} // namespace xio

namespace xio::test_ep {

/**
 * Magic identifier written into the magic field of every
 * submission queue entry (SQE) by the GPU. The CPU-side
 * polling threads use this value to detect a valid SQE.
 */
constexpr uint64_t magicId = 0xDEADBEEFCAFEBABEULL;

/**
 * Magic identifier written into the magic field of every
 * completion queue entry (CQE) by the CPU. The GPU polls
 * for this value to detect a valid completion.
 */
constexpr uint64_t cqeMagicId = 0xBABECAFEBEEFDEADULL;

/**
 * Size of a submission queue entry in bytes.
 */
constexpr size_t sqeSize = 64;

/**
 * Size of a completion queue entry in bytes.
 */
constexpr size_t cqeSize = 16;

/**
 * Test endpoint configuration structure
 *
 * Contains test-ep-specific configuration parameters that
 * control CPU thread behaviour, doorbell mode, emulation,
 * and iteration count.
 */
struct TestEpConfig {
  /**
   * @brief Enable CPU threads to poll SQEs and generate
   *        CQEs.
   *
   * When enabled, CPU threads poll host memory for SQEs
   * written by the GPU and generate CQEs with optional
   * delay support.
   */
  bool enableCpuThreads = true;

  /**
   * @brief Doorbell mode queue length.
   *
   * When greater than 0 doorbell mode is enabled with the
   * specified queue length. A single CPU thread polls a
   * doorbell address instead of individual SQEs. The GPU
   * writes SQEs to the submission queue and rings the
   * doorbell after each enqueue. Doorbell location is
   * controlled by memory mode bit 2 (0=host, 1=device).
   * A value of 0 disables doorbell mode (polling mode).
   */
  unsigned doorbell = 0;

  /**
   * @brief Emulate mode flag.
   *
   * When true the kernel code runs on CPU threads instead
   * of the GPU. Useful for testing without a GPU or in CI
   * environments.
   */
  bool emulate = false;

  /**
   * @brief Number of iterations to run.
   */
  unsigned iterations = 128;

  /** @brief Default constructor. */
  TestEpConfig() = default;
};

/**
 * Submission queue entry (SQE) for the test endpoint
 *
 * Written by the GPU and read by CPU polling threads.
 * Layout matches the simple-test GpuToCpuMsg structure.
 */
struct test_sqe {
  uint64_t magic;     ///< Magic number for validation
  uint64_t iteration; ///< Iteration number (thread ID in
                      ///< upper 32 bits, iteration in
                      ///< lower 32 bits)
  uint64_t gpuTime;   ///< GPU wall clock timestamp
  uint64_t data[5];   ///< Data payload (40 bytes)
};

/**
 * Completion queue entry (CQE) for the test endpoint
 *
 * Written by the CPU and polled by the GPU.
 * Layout matches the simple-test CpuToGpuMsg structure.
 */
struct test_cqe {
  uint64_t magic;   ///< Magic number for validation
  uint64_t cpuTime; ///< CPU wall clock timestamp
};

static_assert(sizeof(test_sqe) == sqeSize, "test_sqe size mismatch");
static_assert(sizeof(test_cqe) == cqeSize, "test_cqe size mismatch");

/**
 * Type aliases for queue entry types
 */
typedef struct test_sqe sqeType;
typedef struct test_cqe cqeType;

/**
 * Launch CPU threads that poll SQEs and generate CQEs
 *
 * Each CPU thread services one GPU thread's queue buffer
 * (polling mode) or a single CPU thread services a shared
 * circular queue via doorbell notification.
 *
 * @param hostSqeAddr  Host-accessible SQE buffer
 *                     (from hipHostMalloc).
 * @param hostCqeAddr  Host-accessible CQE buffer
 *                     (from hipHostMalloc).
 * @param numThreads   Number of CPU threads to launch
 *                     (one per GPU thread in polling mode).
 * @param iterations   Number of iterations per thread.
 * @param delayNs      Delay in nanoseconds before each CQE
 *                     response. Negative values denote a
 *                     fixed delay; positive values denote a
 *                     random delay up to this value.
 * @param doorbell     Doorbell queue length. When greater
 *                     than 0, enables doorbell mode with a
 *                     single CPU polling thread.
 * @param doorbellAddr Doorbell address (nullptr when not in
 *                     doorbell mode).
 * @param queueSize    Submission queue size in entries
 *                     (doorbell mode only).
 * @return Vector of std::thread handles. The caller must
 *         join all returned threads before tearing down
 *         the queue buffers.
 *
 * @note This is a host-only function.
 */
std::vector<std::thread> launchCpuThreads(
  void* hostSqeAddr, void* hostCqeAddr, unsigned numThreads,
  unsigned iterations, long long delayNs, unsigned doorbell = 0,
  void* doorbellAddr = nullptr, unsigned queueSize = 0);

/**
 * Run the test endpoint
 *
 * Launches the GPU kernel (or CPU emulation threads) and
 * waits for completion. CPU polling threads are started
 * automatically when numThreads > 0.
 *
 * @param config Endpoint configuration containing queue
 *               pointers, timing arrays, thread count,
 *               and the endpoint-specific TestEpConfig
 *               in the endpointConfig field.
 * @return hipSuccess on success, or a HIP error code on
 *         failure.
 */
hipError_t run(XioEndpointConfig* config);

} // namespace xio::test_ep

#endif // TEST_EP_H
