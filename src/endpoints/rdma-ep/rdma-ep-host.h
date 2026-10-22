/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 */

/**
 * @file rdma-ep-host.h
 * @brief Embeddable host API for GPU-initiated RDMA (one QP per Endpoint).
 *
 * The rdma-ep run() driver owns the whole test flow (QP setup, TCP exchange,
 * kernels).  Endpoint exposes the same building blocks to a host program or
 * a language binding, so the caller can bootstrap the peers its own way:
 *
 *   1. Endpoint ep(provider, device, gpu)       open device, create QP/CQ
 *   2. ep.registerBuffer(ptr, size, device)     register memory (VRAM too)
 *   3. ep.localInfo()  -> exchange with the peer (any transport)
 *   4. ep.connect(peer_info)                    QP to RTS, remote rkey set
 *   5. ep.put(...)                              the GPU posts the WQE
 *
 * Every error is a std::runtime_error.
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
class QueuePair;

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
   * @param sqDepth Send-queue depth in WQEs.
   * @param cqDepth Completion-queue depth in CQEs.
   * @param deviceQueues Put the send and completion queues in GPU memory (mlx5,
   * through DevX) instead of host memory.
   */
  Endpoint(const std::string& provider, const std::string& device, int gpu,
           int sqDepth = 256, int cqDepth = 256, bool deviceQueues = false);
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
   * @brief RDMA WRITE posted by a GPU thread, then wait for its completion.
   * @param remoteAddr Destination address in the peer's registered buffer.
   * @param local Source address in this endpoint's registered buffer.
   * @param bytes Number of bytes.
   */
  void put(uint64_t remoteAddr, const void* local, size_t bytes);

  /**
   * @brief RDMA WRITE followed, on the same QP, by an atomic add to a remote
   * word.
   *
   * The QP delivers in order, so a peer that sees the signal also sees the
   * data. Waits for both to complete.
   * @param remoteAddr Destination of the data in the peer's registered buffer.
   * @param local Source of the data in this endpoint's registered buffer.
   * @param bytes Number of bytes.
   * @param signalAddr 8-byte-aligned word in the peer's registered buffer to
   * add to.
   * @param value Value added to the word.
   */
  void putSignal(uint64_t remoteAddr, const void* local, size_t bytes,
                 uint64_t signalAddr, int64_t value);

  /**
   * @brief Words of the device context returned by deviceContext().
   *
   * Word layout (all 64-bit; for kernels that build WQEs themselves, e.g.
   * Triton): 0 SQ buffer, 1 SQ doorbell record, 2 doorbell (BlueFlame) pair,
   * 3 SQ depth, 4 CQ buffer, 5 CQ doorbell record, 6 CQ depth, 7 QP number,
   * 8 local key, 9 remote key (both already big-endian, as the WQE wants
   * them), 10 state block (8 device words: next SQ slot to claim, SQ slots
   * rung to the NIC, SQ slots completed, CQ consumer index, error flag), 11
   * RDMA WRITE opcode, 12 atomic fetch-add opcode, 13 scratch address and 14
   * its key for an atomic's result, 15 reserved. mlx5 only.
   */
  static constexpr int kDeviceCtxWords = 16;

  /**
   * @brief Pointers and keys a kernel needs to post on this QP directly.
   *
   * Call after registerBuffer() and connect(). Once a kernel drives the QP
   * through this context, put() must not be used on the same endpoint: they
   * keep separate producer indices.
   */
  std::vector<uint64_t> deviceContext();

  /** @brief The device-side QueuePair, for kernels that post directly. */
  QueuePair* gpuQueuePair() const;

private:
  std::unique_ptr<Backend> backend_;
  std::string device_; /**< Kept alive: the backend keeps a pointer to it. */
  uint64_t* state_ = nullptr; /**< Device words for deviceContext(). */
  int gpu_ = 0;
  uint64_t bufAddr_ = 0;
};

} // namespace rdma_ep
} // namespace xio

#endif // RDMA_EP_HOST_H
