/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/backend_gda.hpp, adapted for rocm-xio.
 * Simplified from full-mesh PE topology to single-endpoint model:
 *   - 1 QP + 1 CQ pair per Backend instance (not num_pes * num_contexts)
 *   - No MPI, no team/context multiplexing
 *   - Loopback mode for testing without remote peer
 *   - Connection info provided via config (not MPI Alltoall)
 */

#ifndef RDMA_EP_GDA_BACKEND_HPP
#define RDMA_EP_GDA_BACKEND_HPP

#include <cstdint>
#include <string>
#include <vector>

#include "ibv-core.hpp"
#include "vendor-ops.hpp"

namespace rdma_ep {

class QueuePair;

struct DestInfo {
  int lid;
  int qpn;
  int psn;
  union ibv_gid gid;
};

struct BackendConfig {
  Provider provider{Provider::BNXT};
  int gpu_device_id{0};
  int sq_depth{256};
  int cq_depth{256};
  uint32_t inline_threshold{28};
  bool pcie_relaxed_ordering{false};
  int traffic_class{0};
  bool loopback{true};
  DestInfo remote{};
  const char *hca_list{nullptr};
};

class Backend {
public:
  explicit Backend(const BackendConfig &config);
  ~Backend();

  int init();
  void shutdown();

  QueuePair *get_gpu_qp() { return gpu_qp_; }
  Provider get_provider() const { return provider_; }
  struct ibv_context *get_context() const { return context_; }
  struct ibv_pd *get_pd() const { return pd_; }
  uint32_t get_rkey() const { return rkey_; }
  uint32_t get_lkey() const { return lkey_; }

  /**
   * Register a data buffer as an MR and update the QueuePair's lkey/rkey.
   * Must be called after init(). Re-syncs QueuePair to GPU.
   * Returns 0 on success, -1 on failure.
   */
  int register_data_buffer(void *buf, size_t size);

  /**
   * Connect QP to a remote peer (non-loopback).
   * Transitions QP through RESET -> INIT -> RTR -> RTS using the
   * remote peer's connection info. Must be called after init() on
   * a Backend created with loopback=false.
   * Returns 0 on success, -1 on failure.
   */
  int connect_to_peer(const DestInfo &remote);

  /**
   * Get local connection info for TCP exchange with remote peer.
   * Valid after init().
   */
  DestInfo get_local_dest_info() const;

  /**
   * Set the remote peer's rkey on the QueuePair.
   * For RDMA WRITE to a remote node, the WQE needs the remote MR's rkey,
   * not the local MR's rkey. Call after TCP exchange.
   * Re-syncs QueuePair to GPU.
   */
  int set_remote_rkey(uint32_t remote_rkey);

private:
  BackendConfig config_;
  Provider provider_{Provider::UNKNOWN};

  struct ibv_device *device_{nullptr};
  struct ibv_context *context_{nullptr};
  struct ibv_device_attr device_attr_{};
  struct ibv_pd *pd_{nullptr};
  struct ibv_pd *pd_parent_{nullptr};
  struct ibv_port_attr port_attr_{};
  union ibv_gid local_gid_{};
  int port_{1};
  int gid_index_{0};

  struct ibv_cq *cq_{nullptr};
  struct ibv_qp *qp_{nullptr};

  uint32_t rkey_{0};
  uint32_t lkey_{0};
  struct ibv_mr *heap_mr_{nullptr};

  QueuePair *host_qp_{nullptr};
  QueuePair *gpu_qp_{nullptr};

  void *dv_handle_{nullptr};

  void open_dv_libs();
  void close_dv_libs();
  void open_ib_device();
  void create_queues();
  void setup_qp_loopback();

  void modify_qp_reset_to_init();
  void modify_qp_init_to_rtr(const DestInfo &remote);
  void modify_qp_rtr_to_rts();

  int ibv_mtu_to_int(enum ibv_mtu mtu);

  void initialize_gpu_qp();
  void setup_gpu_qp();
  void cleanup_gpu_qp();

  static void *pd_alloc_device_uncached(ibv_pd *pd, void *pd_context,
                                        size_t size, size_t alignment,
                                        uint64_t resource_type);
  static void pd_release(ibv_pd *pd, void *pd_context, void *ptr,
                         uint64_t resource_type);
  void create_parent_domain();

#if defined(GDA_BNXT)
  struct bnxt_host_qp *bnxt_qp_{nullptr};
  struct bnxt_host_cq *bnxt_scq_{nullptr};
  struct bnxt_host_cq *bnxt_rcq_{nullptr};
  void *bnxt_dv_handle_{nullptr};
  void bnxt_create_cqs(int ncqes);
  void bnxt_create_qps(int sq_length);
  void bnxt_initialize_gpu_qp();
  int bnxt_dv_dl_init();
  static void *bnxt_dv_dlopen();
#endif

#if defined(GDA_MLX5)
  void *mlx5dv_handle_{nullptr};
  void mlx5_initialize_gpu_qp();
  int mlx5_dv_dl_init();
  static void *mlx5_dv_dlopen();
#endif

#if defined(GDA_IONIC)
  struct ibv_pd *pd_uxdma_[2]{nullptr, nullptr};
  void *gpu_db_page_{nullptr};
  uint64_t *gpu_db_cq_{nullptr};
  uint64_t *gpu_db_sq_{nullptr};
  void *ionicdv_handle_{nullptr};
  void ionic_create_cqs(int ncqes);
  void ionic_initialize_gpu_qp();
  int ionic_dv_dl_init();
  static void *ionic_dv_dlopen();
  void ionic_setup_parent_domain(struct ibv_parent_domain_init_attr *pattr);
#endif
};

} // namespace rdma_ep

#endif // RDMA_EP_GDA_BACKEND_HPP
