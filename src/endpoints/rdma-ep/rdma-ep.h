/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 */

/**
 * @file rdma-ep.h
 * @brief RDMA Endpoint -- GPU-Direct Access (GDA) for RDMA NICs.
 *
 * Derived from ROCm/rocSHMEM GDA backend, adapted for rocm-xio.
 * Supports four RDMA vendors:
 *   - BNXT   (Broadcom Thor 2)
 *   - MLX5   (Mellanox/NVIDIA ConnectX)
 *   - IONIC  (Pensando)
 *   - ERNIC  (AMD ROCm ERNIC)
 *
 * Operating modes:
 *   - Loopback  -- QP connected to itself (default, single node)
 *   - 2-node    -- server/client over TCP QP exchange, then
 *                  GPU-initiated RDMA WRITE + ping-pong
 */

#ifndef RDMA_EP_H
#define RDMA_EP_H

#include <cstdint>
#include <string>

#include <hip/hip_runtime.h>

#include "vendor-ops.hpp"

#define RDMA_EP_SQE_SIZE 0
#define RDMA_EP_CQE_SIZE 0

namespace rdma_ep {

/**
 * @brief Configuration for the RDMA endpoint.
 *
 * Validated by validateConfig().  Controls provider selection,
 * queue sizing, loopback vs 2-node mode, and optional
 * data-pattern verification.
 */
struct RdmaEpConfig {
  std::string providerStr = "bnxt";   /**< Provider name string.    */
  Provider provider = Provider::BNXT; /**< Resolved provider enum.  */
  unsigned iterations = 128;          /**< RDMA ops per run.        */
  unsigned sqDepth = 256;             /**< Send-queue depth.        */
  unsigned cqDepth = 256;             /**< Completion-queue depth.  */
  uint32_t transferSize = 4096;       /**< Bytes per RDMA WRITE.    */
  uint32_t inlineThreshold = 28;      /**< Max inline send bytes.   */
  bool pcieRelaxedOrdering = false;   /**< PCIe relaxed ordering.   */
  int trafficClass = 0;               /**< QP address-handle TC.    */
  bool loopback = true;               /**< Loopback mode (default). */
  int gpuDeviceId = 0;                /**< HIP GPU device index.    */
  bool verify = false;                /**< LFSR verification flag.  */
  uint32_t seed = 1;                  /**< LFSR seed value.         */
  std::string deviceName;             /**< RDMA device name filter. */
  QueueMemMode queueMem = QueueMemMode::HOST_COHERENT; /**< Queue buffer
                                                          placement. */

  /** @name 2-Node Mode Fields
   *  Mutually exclusive with loopback mode.
   *  @{
   */
  bool isServer = false;  /**< Run as 2-node server.    */
  bool isClient = false;  /**< Run as 2-node client.    */
  std::string serverHost; /**< Server hostname/IP.      */
  uint32_t ppSize = 64;   /**< Ping-pong total bytes (seq + payload). */
  uint32_t ppIters = 100; /**< Ping-pong iterations.    */
  /** @} */
};

} // namespace rdma_ep

namespace rdma_ep {

__host__ std::string validateConfig(RdmaEpConfig* config);
__host__ unsigned getIterations(void* endpointConfig);

} // namespace rdma_ep

#endif // RDMA_EP_H
