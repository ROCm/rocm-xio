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
   * @param deviceQueues Put the send and completion queues in GPU memory (mlx5,
   * through DevX) instead of host memory.
   */
  Endpoint(const std::string& provider, const std::string& device, int gpu,
           bool deviceQueues = false);
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

  /**
   * @name CPU posting (Endpoint built with deviceQueues = true, mlx5)
   * One poster per QP: do not mix with kernels posting on the same endpoint.
   * @{
   */

  /**
   * @brief Write an RDMA WRITE into the send queue without ringing.
   * @param remoteAddr Destination in the peer's registered buffer.
   * @param local Source in this endpoint's registered buffer.
   * @param bytes Number of bytes.
   * @param signaled Request a completion.
   * @return The work request's slot index.
   */
  uint64_t hostPostWrite(uint64_t remoteAddr, const void* local, size_t bytes,
                         bool signaled = true);

  /** @brief Ring the doorbell for everything posted (record, flush, doorbell).
   */
  void hostRing();

  /** @brief Flush the CPU's queue writes to the device (HDP) without ringing.
   */
  void hostFlush();

  /**
   * @brief Values that would ring the doorbell for everything posted.
   * @param dbrecBe Doorbell record value, big-endian.
   * @param doorbellVal Doorbell (control header) value.
   */
  void hostStaged(uint32_t* dbrecBe, uint64_t* doorbellVal) const;

  /**
   * @brief Addresses a DMA engine needs to ring the doorbell.
   * @param dbrec SQ doorbell record.
   * @param gpuDoorbell GPU alias of the doorbell register.
   * @param cpuDoorbell CPU alias of the doorbell register.
   */
  void hostAddresses(uint64_t* dbrec, uint64_t* gpuDoorbell,
                     uint64_t* cpuDoorbell) const;

  /**
   * @brief Consume completions; throws on an error completion.
   * @param max Most completions to consume.
   * @return The number consumed.
   */
  unsigned hostPoll(unsigned max);

  /** @brief Work requests posted but not yet completed.
   * @return The count.
   */
  uint64_t hostOutstanding() const;
  /** @} */

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
