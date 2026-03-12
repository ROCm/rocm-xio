/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/queue_pair.hpp, adapted for rocm-xio.
 * Simplified for single-endpoint model (no PE parameter in device methods).
 *
 * Vendor-specific device code lives in rdma_ep::bnxt::, rdma_ep::mlx5::,
 * rdma_ep::ionic:: namespaces as free functions. QueuePair dispatches to
 * them at compile time via #if defined(GDA_*).
 */

#ifndef RDMA_EP_QUEUE_PAIR_HPP
#define RDMA_EP_QUEUE_PAIR_HPP

#include <cstdint>

#include <hip/hip_runtime.h>

#include "vendor-ops.hpp"
#include "ibv-core.hpp"
#include "endian.hpp"

#if defined(GDA_BNXT)
#include "bnxt/bnxt-provider.hpp"
#endif

#if defined(GDA_MLX5)
#include "mlx5/mlx5-provider.hpp"
#endif

#if defined(GDA_IONIC)
#include "ionic/ionic-provider.hpp"
#endif

namespace rdma_ep {

// Forward declarations for vendor namespace free functions.
// Each vendor namespace provides the same set of function names.
namespace bnxt { class Ops; }
namespace mlx5 { class Ops; }
namespace ionic { class Ops; }

class Backend;

class QueuePair {
public:
  friend Backend;
  friend class bnxt::Ops;
  friend class mlx5::Ops;
  friend class ionic::Ops;

  explicit QueuePair(struct ibv_pd *pd, Provider provider);
  ~QueuePair();

  // --- Public device API ---
  __device__ void put_nbi(void *dest, const void *source, size_t nelems);
  __device__ void get_nbi(void *dest, const void *source, size_t nelems);
  __device__ void quiet();

  __device__ int64_t atomic_fetch(void *dest, int64_t value, int64_t cond);
  __device__ void atomic_nofetch(void *dest, int64_t value, int64_t cond);
  __device__ int64_t atomic_cas(void *dest, int64_t data, int64_t cmp);

  __device__ void put_nbi_single(void *dest, const void *source, size_t nelems,
                                 bool ring_db = true);
  __device__ void get_nbi_single(void *dest, const void *source, size_t nelems,
                                 bool ring_db = true);
  __device__ void quiet_single();

  // --- Common accessor for vendor code ---
  __device__ uint64_t get_same_qp_lane_mask();

//private:
  __device__ void post_wqe_rma(int32_t size, uintptr_t laddr,
                                uintptr_t raddr, uint8_t opcode);
  __device__ void post_wqe_rma_single(int32_t size, uintptr_t laddr,
                                       uintptr_t raddr, uint8_t opcode,
                                       bool ring_db);
  __device__ uint64_t post_wqe_amo(int32_t size, uintptr_t raddr,
                                    uint8_t opcode, int64_t atomic_data,
                                    int64_t atomic_cmp, bool fetching);

  Provider provider_{Provider::UNKNOWN};

  uint8_t op_rdma_write_;
  uint8_t op_rdma_read_;
  uint8_t op_atomic_fa_;
  uint8_t op_atomic_cs_;

  uint32_t rkey_{0};
  uint32_t lkey_{0};
  uint32_t qp_num_{0};
  uint32_t inline_threshold_{0};

  uint64_t *nonfetching_atomic_{nullptr};
  uint32_t nonfetching_atomic_lkey_{0};
  struct ibv_mr *mr_nonfetching_atomic_{nullptr};

  uint64_t *fetching_atomic_{nullptr};
  uint32_t fetching_atomic_lkey_{0};
  uint32_t fetching_atomic_idx_{0};
  struct ibv_mr *mr_fetching_atomic_{nullptr};

  static constexpr uint32_t FETCHING_ATOMIC_CNT{1024};

  // --- Vendor-specific device state (data only, no methods) ---
#if defined(GDA_BNXT)
  uint64_t *bnxt_dbr_{nullptr};
  bnxt_device_cq bnxt_cq_{};
  bnxt_device_sq bnxt_sq_{};
#endif

#if defined(GDA_MLX5)
  gda_mlx5_device_cq mlx5_cq_{};
  gda_mlx5_device_sq mlx5_sq_{};
#endif

#if defined(GDA_IONIC)
  uint64_t *cq_dbreg_{nullptr};
  uint64_t cq_dbval_{0};
  uint64_t cq_mask_{0};
  struct ionic_v1_cqe *ionic_cq_buf_{nullptr};
  uint32_t cq_lock_{0};
  uint32_t cq_pos_{0};
  uint32_t cq_dbpos_{0};

  uint64_t *sq_dbreg_{nullptr};
  uint64_t sq_dbval_{0};
  uint64_t sq_mask_{0};
  struct ionic_v1_wqe *ionic_sq_buf_{nullptr};
  uint32_t sq_lock_{0};
  uint32_t sq_dbprod_{0};
  uint32_t sq_prod_{0};
  uint32_t sq_msn_{0};
#endif
};

// ============================================================================
// Vendor namespace declarations
// Each vendor provides the same function names for the common operations.
// ============================================================================

#if defined(GDA_BNXT)
namespace bnxt {
  class Ops {
  public:
    __device__ static void post_wqe_rma(QueuePair &qp, int32_t length,
                                        uintptr_t laddr, uintptr_t raddr,
                                        uint8_t opcode);
    __device__ static void post_wqe_rma_single(QueuePair &qp, int32_t length,
                                               uintptr_t laddr, uintptr_t raddr,
                                               uint8_t opcode, bool ring_db);
    __device__ static uint64_t post_wqe_amo(QueuePair &qp, uintptr_t raddr,
                                            uint8_t opcode, int64_t atomic_data,
                                            int64_t atomic_cmp, bool fetching);
    __device__ static uint64_t post_wqe_amo_single(QueuePair &qp, uintptr_t raddr,
                                                   uint8_t opcode, int64_t atomic_data,
                                                   int64_t atomic_cmp, bool fetching);
    __device__ static void quiet(QueuePair &qp);
    __device__ static void quiet_single(QueuePair &qp);

    __device__ static void ring_doorbell(QueuePair &qp, uint32_t slot_idx);
    __device__ static void poll_cq_until(QueuePair &qp, uint32_t requested);
    __device__ static void write_rma_wqe(QueuePair &qp, uintptr_t raddr,
                                         uintptr_t laddr, int32_t length,
                                         uint8_t opcode);
    __device__ static uint32_t write_amo_wqe(QueuePair &qp, uintptr_t raddr,
                                             uint8_t opcode, int64_t atomic_data,
                                             int64_t atomic_cmp, bool fetching);
    __device__ static void check_cqe_error(QueuePair &qp, struct bnxt_re_req_cqe *cqe);
  };
} // namespace bnxt
#endif

#if defined(GDA_MLX5)
namespace mlx5 {
  class Ops {
  public:
    __device__ static void post_wqe_rma(QueuePair &qp, int32_t length,
                                        uintptr_t laddr, uintptr_t raddr,
                                        uint8_t opcode);
    __device__ static void post_wqe_rma_single(QueuePair &qp, int32_t length,
                                               uintptr_t laddr, uintptr_t raddr,
                                               uint8_t opcode, bool ring_db);
    __device__ static uint64_t post_wqe_amo(QueuePair &qp, uintptr_t raddr,
                                            uint8_t opcode, int64_t atomic_data,
                                            int64_t atomic_cmp, bool fetching);
    __device__ static uint64_t post_wqe_amo_single(QueuePair &qp, uintptr_t raddr,
                                                   uint8_t opcode, int64_t atomic_data,
                                                   int64_t atomic_cmp, bool fetching);
    __device__ static void quiet(QueuePair &qp);
    __device__ static void quiet_single(QueuePair &qp);

    __device__ static void ring_doorbell(QueuePair &qp, uint16_t counter,
                                         const gda_mlx5_wqe &wqe);
    __device__ static void poll_cq_until(QueuePair &qp, uint16_t requested);
    __device__ static void check_cqe_error(QueuePair &qp, const mlx5_cqe64 *cqe);
  };
} // namespace mlx5
#endif

#if defined(GDA_IONIC)
namespace ionic {
  class Ops {
  public:
    __device__ static void post_wqe_rma(QueuePair &qp, int32_t size,
                                        uintptr_t laddr, uintptr_t raddr,
                                        uint8_t opcode);
    __device__ static void post_wqe_rma_single(QueuePair &qp, int32_t size,
                                               uintptr_t laddr, uintptr_t raddr,
                                               uint8_t opcode, bool ring_db);
    __device__ static uint64_t post_wqe_amo(QueuePair &qp, uintptr_t raddr,
                                            uint8_t opcode, int64_t atomic_data,
                                            int64_t atomic_cmp, bool fetching);
    __device__ static uint64_t post_wqe_amo_single(QueuePair &qp, uintptr_t raddr,
                                                   uint8_t opcode, int64_t atomic_data,
                                                   int64_t atomic_cmp, bool fetching);
    __device__ static void quiet(QueuePair &qp);
    __device__ static void quiet_single(QueuePair &qp);

    __device__ static void ring_doorbell(QueuePair &qp, uint32_t pos);
    __device__ static void ring_doorbell_single(QueuePair &qp, uint32_t pos);
    __device__ static uint32_t reserve_sq(QueuePair &qp, uint64_t activemask, uint32_t num_wqes);
    __device__ static uint32_t reserve_sq_single(QueuePair &qp, uint32_t num_wqes);
    __device__ static uint32_t commit_sq(QueuePair &qp, uint64_t activemask,
                                         uint32_t my_sq_prod, uint32_t my_sq_pos, uint32_t num_wqes);
    __device__ static uint32_t commit_sq_single(QueuePair &qp, uint32_t my_sq_prod,
                                                uint32_t my_sq_pos, uint32_t num_wqes);
    __device__ static void poll_wave_cqes(QueuePair &qp, uint64_t activemask);
    __device__ static void quiet_internal(QueuePair &qp, uint64_t activemask, uint32_t cons);
    __device__ static void quiet_internal_ccqe(QueuePair &qp, uint64_t activemask, uint32_t cons);
    __device__ static void quiet_internal_ccqe_single(QueuePair &qp, uint32_t cons);
  };
} // namespace ionic
#endif

} // namespace rdma_ep

#endif // RDMA_EP_QUEUE_PAIR_HPP
