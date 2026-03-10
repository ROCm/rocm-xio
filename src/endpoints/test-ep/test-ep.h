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

namespace test_ep {

/**
 * Test endpoint configuration structure
 *
 * Contains test-ep-specific configuration parameters.
 */
struct TestEpConfig {
  // Enable CPU threads to poll SQEs and generate CQEs
  // When enabled, CPU threads will poll host memory for SQEs written by GPU
  // and generate CQEs with delay support
  bool enableCpuThreads = true; // Default: enabled to match simple-test
                                // behavior

  // Doorbell mode queue length
  // When > 0, enables doorbell mode with the specified queue length.
  // CPU threads do not poll individual SQEs. Instead, a single CPU thread polls
  // a doorbell address. The GPU writes SQEs to the submission queue and rings
  // the doorbell after each SQE enqueue. Doorbell location is controlled by
  // memory mode bit 2 (0=host, 1=device).
  unsigned doorbell = 0; // Default: 0 (disabled, polling mode)

  // Emulate mode: run kernel code on CPU instead of GPU
  // Useful for testing without a GPU or in CI environments
  bool emulate = false; // Default: false (use GPU)

  // Number of iterations to run
  unsigned iterations = 128; // Default: 128

  // Default constructor
  TestEpConfig() = default;
};

} // namespace test_ep

// Magic ID for test-ep queue entries (matches simple-test)
#define TEST_EP_MAGIC_ID 0xDEADBEEFCAFEBABEULL
#define TEST_EP_CQE_MAGIC_ID 0xBABECAFEBEEFDEADULL

// Test endpoint queue entry sizes (matches simple-test)
#define TEST_EP_SQE_SIZE 64 // Matches GpuToCpuMsg
#define TEST_EP_CQE_SIZE 16 // Matches CpuToGpuMsg

// Test endpoint queue entry structures (matches simple-test structures)
struct test_sqe {
  uint64_t magic;     // 8 bytes - magic number for validation
  uint64_t iteration; // 8 bytes - iteration number (thread ID in upper 32 bits,
                      // iteration in lower 32 bits)
  uint64_t gpuTime;   // 8 bytes - GPU wall clock time
  uint64_t data[5];   // 40 bytes - data payload
};

struct test_cqe {
  uint64_t magic;   // 8 bytes - magic number for validation
  uint64_t cpuTime; // 8 bytes - CPU wall clock time
};

static_assert(sizeof(struct test_sqe) == TEST_EP_SQE_SIZE,
              "test_sqe size mismatch");
static_assert(sizeof(struct test_cqe) == TEST_EP_CQE_SIZE,
              "test_cqe size mismatch");

// Forward declarations for CPU thread support
// CPU thread launcher function (host-only)
// Launches CPU threads to poll SQEs and generate CQEs
// Parameters:
//   hostSqeAddr: Host-accessible SQE buffer (from hipHostMalloc)
//   hostCqeAddr: Host-accessible CQE buffer (from hipHostMalloc)
//   hostEndTimes: Host-accessible end times array (optional, can be nullptr)
//   numThreads: Number of CPU threads to launch (one per GPU thread)
//   iterations: Number of iterations per thread
//   delayNs: Delay configuration (from XioEndpointConfig)
//   doorbellMode: If true, use doorbell mode (single CPU thread polling
//   doorbell) doorbell: Doorbell address (nullptr if not in doorbell mode)
//   queueSize: Size of submission queue in doorbell mode
// Returns: Vector of thread handles (caller must join)
std::vector<std::thread> launchCpuThreads(
  void* hostSqeAddr, void* hostCqeAddr, unsigned numThreads,
  unsigned iterations, long long delayNs, bool doorbellMode = false,
  void* doorbell = nullptr, unsigned queueSize = 0);

// Run endpoint test - launches GPU kernel and waits for completion
// Parameters:
//   config: Endpoint configuration (includes submissionQueue and
//   completionQueue)
// Returns: HIP error code
hipError_t test_ep_run(xio::XioEndpointConfig* config);

#endif // TEST_EP_H
