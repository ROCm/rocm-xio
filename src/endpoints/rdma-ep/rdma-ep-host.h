/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 */

/**
 * @file rdma-ep-host.h
 * @brief Embeddable host API for GPU-initiated RDMA (one QP per Endpoint).
 */

#ifndef RDMA_EP_HOST_H
#define RDMA_EP_HOST_H

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace xio {
namespace rdma_ep {

class Backend;

/** @brief What a peer needs to connect to this endpoint. */
struct EndpointInfo {
  uint32_t lid = 0;     /**< InfiniBand local identifier. */
  uint32_t qpn = 0;     /**< Queue-pair number. */
  uint32_t psn = 0;     /**< Packet sequence number. */
  uint8_t gid[16] = {}; /**< Global identifier. */
  uint32_t rkey = 0;    /**< Key of the registered buffer. */
  uint64_t addr = 0;    /**< Base address of the registered buffer. */
};

/**
 * @brief One reliable-connected QP driven from the GPU.
 */
class Endpoint {
public:
  /**
   * @param provider "mlx5", "bnxt", "ionic" or "ernic" (must be compiled in).
   * @param device RDMA device name such as "mlx5_0"; empty picks the first.
   * @param gpu HIP device index the QP's doorbell/queues are mapped for.
   */
  Endpoint(const std::string& provider, const std::string& device, int gpu);
  ~Endpoint();
  Endpoint(const Endpoint&) = delete;
  Endpoint& operator=(const Endpoint&) = delete;

  /**
   * @brief Register the buffer the peer may write to and this QP reads from.
   * @param ptr Base address.
   * @param size Size in bytes.
   * @param device True for GPU memory (registered through dmabuf), false for
   *        host memory.
   */
  void registerBuffer(void* ptr, size_t size, bool device);

  /** @brief Local connection info; valid once a buffer is registered. */
  EndpointInfo localInfo() const;

  /** @brief Bring the QP to RTS against the peer and adopt its rkey. */
  void connect(const EndpointInfo& remote);

  /**
   * @brief Words of the device context returned by deviceContext().
   *
   * Word layout (all 64-bit): 0 SQ buffer, 1 SQ doorbell record, 2 doorbell
   * (BlueFlame) pair, 3 SQ depth, 4 CQ buffer, 5 CQ doorbell record, 6 CQ
   * depth, 7 QP number, 8 local key, 9 remote key (both already big-endian, as
   * the WQE wants them), 10 state block (8 device words: next SQ slot to claim,
   * SQ slots rung to the NIC, SQ slots completed, CQ consumer index, error
   * flag), 11 RDMA WRITE opcode, 12 atomic fetch-add opcode, 13 scratch address
   * and 14 its key for an atomic's result, 15 reserved. mlx5 only.
   */
  static constexpr int kDeviceCtxWords = 16;

  /**
   * @brief Pointers and keys a kernel needs to post on this QP directly.
   *
   * Call after registerBuffer() and connect().
   */
  std::vector<uint64_t> deviceContext();

private:
  std::unique_ptr<Backend> backend_;
  std::string device_; /**< Kept alive: the backend keeps a pointer to it. */
  uint64_t* state_ = nullptr;
  int gpu_ = 0;
  uint64_t bufAddr_ = 0;
};

} // namespace rdma_ep
} // namespace xio

#endif // RDMA_EP_HOST_H
