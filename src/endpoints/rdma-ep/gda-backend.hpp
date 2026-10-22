/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/backend_gda.hpp, adapted for rocm-xio.
 * Common config mapping, key normalization, QP init, and QP modify dispatch
 * live in rdma-common.h.
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
#include "rdma-ep.h"
#include "vendor-ops.hpp"

namespace xio {
namespace rdma_ep {

class QueuePair;
struct Mlx5DevxState;

/** @brief Queue-pair connection parameters exchanged between RDMA peers. */
struct DestInfo {
  int lid;           /**< Local identifier for InfiniBand transports. */
  int qpn;           /**< Queue-pair number. */
  int psn;           /**< Packet sequence number used for RTR transition. */
  union ibv_gid gid; /**< RoCE global identifier. */
};

/**
 * @brief Runtime configuration consumed by the RDMA backend.
 *
 * This structure is derived from RdmaEpConfig and XioEndpointConfig by
 * make_backend_config(). It contains only values needed to open a provider,
 * create QPs/CQs, allocate queue memory, and connect the local or remote peer.
 */
struct BackendConfig {
  Provider provider{Provider::BNXT}; /**< Provider backend to open. */
  int gpu_device_id{0};              /**< HIP GPU device index. */
  int sq_depth{256};                 /**< Send queue depth in WQEs. */
  int cq_depth{256};                 /**< Completion queue depth in CQEs. */
  uint32_t inline_threshold{28};     /**< Max bytes posted inline. */
  bool pcie_relaxed_ordering{false}; /**< Enable PCIe relaxed ordering. */
  int traffic_class{0};              /**< RoCE traffic class for AH attrs. */
  bool loopback{true};               /**< Connect the QP to itself. */
  DestInfo remote{};                 /**< Remote peer for non-loopback. */
  const char* hca_list{nullptr};     /**< Optional HCA include/exclude list. */
  bool pci_mmio_bridge{false};       /**< Route doorbells through bridge. */
  QueueMemMode queue_mem{QueueMemMode::HOST_COHERENT}; /**< Queue memory. */
};

/** @brief Host-side owner for one provider-specific RDMA QP/CQ pair. */
class Backend {
public:
  /**
   * @brief Store backend configuration.
   * @param config Runtime RDMA backend configuration.
   */
  explicit Backend(const BackendConfig& config);

  /** @brief Release RDMA and provider resources. */
  ~Backend();

  /**
   * @brief Open the device, create queues, and initialize GPU state.
   * @return 0 on success, -1 on failure.
   */
  int init();

  /** @brief Tear down resources allocated by init(). */
  void shutdown();

  /**
   * @brief Return the GPU-resident QueuePair object.
   * @return Pointer to the GPU QueuePair state.
   */
  QueuePair* get_gpu_qp() {
    return gpu_qp_;
  }
  /**
   * @brief Return the resolved provider backend.
   * @return Provider selected during initialization.
   */
  Provider get_provider() const {
    return provider_;
  }
  /**
   * @brief Return the opened verbs context.
   * @return Active verbs context, or nullptr before init().
   */
  struct ibv_context* get_context() const {
    return context_;
  }
  /**
   * @brief Return the protection domain used by the QP.
   * @return Active protection domain, or nullptr before init().
   */
  struct ibv_pd* get_pd() const {
    return pd_;
  }
  /**
   * @brief Return the host verbs QP.
   * @return Active verbs QP, or nullptr before init().
   */
  struct ibv_qp* get_ibv_qp() const {
    return qp_;
  }
  /**
   * @brief Return the host verbs CQ.
   * @return Active verbs CQ, or nullptr before init().
   */
  struct ibv_cq* get_ibv_cq() const {
    return cq_;
  }
  /**
   * @brief Return the host mirror of the QueuePair state.
   * @return Host QueuePair object, or nullptr before init().
   */
  QueuePair* get_host_qp() const {
    return host_qp_;
  }
#if defined(GDA_IONIC)
  /**
   * @brief Return the Ionic GPU doorbell page.
   * @return GPU-visible doorbell page pointer.
   */
  void* get_db_page() const {
    return gpu_db_page_;
  }
#endif
  /**
   * @brief Return the current remote key used by WQEs.
   * @return Remote memory-region key.
   */
  uint32_t get_rkey() const {
    return rkey_;
  }
  /**
   * @brief Return the local key for registered data buffers.
   * @return Local memory-region key.
   */
  uint32_t get_lkey() const {
    return lkey_;
  }

  /**
   * @brief Register a data buffer as an MR and update QueuePair keys.
   * @param buf Buffer base pointer.
   * @param size Buffer size in bytes.
   * @return 0 on success, -1 on failure.
   */
  int register_data_buffer(void* buf, size_t size);

  /**
   * @brief Register GPU memory (VRAM) as the RDMA data buffer.
   *
   * Like register_data_buffer(), but registers through the verbs wrapper's
   * dmabuf path, which is what GPU memory needs: plain ibv_reg_mr() on VRAM
   * fails without a peer-memory driver.
   *
   * @param buf Device pointer (hipMalloc or mapped VMM memory).
   * @param size Size of the range in bytes.
   * @return 0 on success, -1 on failure.
   */
  int register_device_buffer(void* buf, size_t size);

  /**
   * @brief Connect the QP to a remote peer in non-loopback mode.
   * @param remote Remote peer connection information.
   * @return 0 on success, -1 on failure.
   */
  int connect_to_peer(const DestInfo& remote);

  /**
   * @brief Get local connection info for TCP exchange with a peer.
   * @return Local LID, QPN, PSN, and GID values valid after init().
   */
  DestInfo get_local_dest_info() const;

  /**
   * @brief Set the remote peer's memory-region key on the QueuePair.
   * @param remote_rkey Remote MR key received during TCP exchange.
   * @return 0 on success, -1 on failure.
   */
  int set_remote_rkey(uint32_t remote_rkey);

private:
  /** @cond INTERNAL */
  BackendConfig config_;
  Provider provider_{Provider::UNKNOWN};

  struct ibv_device* device_{nullptr};
  struct ibv_context* context_{nullptr};
  struct ibv_device_attr device_attr_ {};
  struct ibv_pd* pd_{nullptr};
  struct ibv_pd* pd_parent_{nullptr};
  struct ibv_port_attr port_attr_ {};
  union ibv_gid local_gid_ {};
  int port_{1};
  int gid_index_{0};

  struct ibv_cq* cq_{nullptr};
  struct ibv_qp* qp_{nullptr};

  uint32_t rkey_{0};
  uint32_t lkey_{0};
  struct ibv_mr* heap_mr_{nullptr};

  QueuePair* host_qp_{nullptr};
  QueuePair* gpu_qp_{nullptr};

  void* dv_handle_{nullptr};

  int register_buffer(void* buf, size_t size, bool device);
  void open_dv_libs();
  void close_dv_libs();
  void open_ib_device();
  void create_queues();
  void setup_qp_loopback();

  void modify_qp_reset_to_init();
  void modify_qp_init_to_rtr(const DestInfo& remote);
  void modify_qp_rtr_to_rts();

  int ibv_mtu_to_int(enum ibv_mtu mtu);

  void initialize_gpu_qp();
  void setup_gpu_qp();
  void cleanup_gpu_qp();

  static void* pd_alloc_device_uncached(ibv_pd* pd, void* pd_context,
                                        size_t size, size_t alignment,
                                        uint64_t resource_type);
  static void* pd_alloc_host_pinned(ibv_pd* pd, void* pd_context, size_t size,
                                    size_t alignment, uint64_t resource_type);
  static void pd_release(ibv_pd* pd, void* pd_context, void* ptr,
                         uint64_t resource_type);
  static void pd_release_host(ibv_pd* pd, void* pd_context, void* ptr,
                              uint64_t resource_type);
  void create_parent_domain();

#if defined(GDA_BNXT)
  struct bnxt_host_qp* bnxt_qp_{nullptr};
  struct bnxt_host_cq* bnxt_scq_{nullptr};
  struct bnxt_host_cq* bnxt_rcq_{nullptr};
  void* bnxt_dv_handle_{nullptr};
  void bnxt_create_cqs(int ncqes);
  void bnxt_create_qps(int sq_length);
  void bnxt_initialize_gpu_qp();
  void bnxt_cleanup();
  int bnxt_dv_dl_init();
  static void* bnxt_dv_dlopen();
#endif

#if defined(GDA_MLX5)
  // Queues in GPU memory through DevX (mlx5-devx.cpp), used when
  // BackendConfig::queue_mem is DEVICE_VRAM
  Mlx5DevxState* devx_{nullptr};
  bool devx_queues_{false};
  int mlx5_devx_create_queues();
  int mlx5_devx_connect(const DestInfo& remote);
  uint32_t mlx5_devx_qpn() const;
  void mlx5_devx_initialize_gpu_qp();
  void mlx5_devx_cleanup();
  void* mlx5dv_handle_{nullptr};
  void* mlx5_registered_sq_{nullptr};
  void* mlx5_registered_cq_{nullptr};
  void* mlx5_registered_sq_dbr_page_{nullptr};
  void* mlx5_registered_cq_dbr_page_{nullptr};
  void* mlx5_registered_bf_{nullptr};
  void mlx5_initialize_gpu_qp();
  void mlx5_cleanup();
  int mlx5_cpu_loopback_smoke_test();
  int mlx5_dv_dl_init();
  static void* mlx5_dv_dlopen();
#endif

#if defined(GDA_IONIC)
  struct ibv_pd* pd_uxdma_[2]{nullptr, nullptr};
  void* gpu_db_page_{nullptr};
  uint64_t* gpu_db_cq_{nullptr};
  uint64_t* gpu_db_sq_{nullptr};
  void* ionicdv_handle_{nullptr};
  void ionic_create_cqs(int ncqes);
  void ionic_initialize_gpu_qp();
  int ionic_dv_dl_init();
  static void* ionic_dv_dlopen();
  void ionic_setup_parent_domain(struct ibv_parent_domain_init_attr* pattr);
#endif

#if defined(GDA_ERNIC)
  struct ernic_host_qp* ernic_qp_{nullptr};
  struct ernic_host_cq* ernic_scq_{nullptr};
  struct ernic_host_cq* ernic_rcq_{nullptr};
  void ernic_create_cqs(int ncqes);
  void ernic_create_qps(int sq_length);
  void ernic_initialize_gpu_qp();
  int ernic_dv_dl_init();
  static void* ernic_dv_dlopen();
#endif
  /** @endcond */
};

} // namespace rdma_ep
} // namespace xio

#endif // RDMA_EP_GDA_BACKEND_HPP
