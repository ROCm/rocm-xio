/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 */

/**
 * @file rdma-common.h
 * @brief Shared RDMA endpoint helpers used by host and device code.
 *
 * This header contains the vendor-independent parts of the RDMA endpoint:
 * provider metadata, RDMA-to-backend config mapping, key normalization, common
 * RC QP setup, QP modification dispatch, and small device verification helpers.
 * Vendor-specific WQE construction, doorbell programming, CQE parsing, and DV
 * object layout remain in the provider directories.
 */

#ifndef RDMA_EP_RDMA_COMMON_H
#define RDMA_EP_RDMA_COMMON_H

#include <cstddef>
#include <cstdint>

#include <hip/hip_runtime.h>

#include "ibv-core.hpp"
#include "vendor-ops.hpp"

namespace xio {

struct XioEndpointConfig;

namespace rdma_ep {

struct BackendConfig;
struct RdmaEpConfig;

/**
 * @brief Return the supported provider names for diagnostics and Doxygen.
 *
 * The returned string is the single user-facing list used by config
 * validation. Provider aliases remain accepted by provider_from_string().
 *
 * @return Comma-separated canonical provider names.
 */
__host__ const char* provider_allowed_names();

/**
 * @brief Build runtime backend config from the public RDMA endpoint config.
 *
 * @param config Common xio endpoint configuration.
 * @param rdmaConfig User-facing RDMA endpoint configuration.
 * @param loopback True for loopback setup, false for 2-node setup.
 * @return Runtime BackendConfig consumed by Backend.
 */
__host__ BackendConfig make_backend_config(const XioEndpointConfig& config,
                                           const RdmaEpConfig& rdmaConfig,
                                           bool loopback);

/**
 * @brief Convert a key into the device format expected by a provider.
 *
 * MLX5 WQEs expect keys in big-endian order. Other supported providers consume
 * the native libibverbs key value.
 *
 * @param provider Active RDMA provider.
 * @param key Local or remote memory key from libibverbs.
 * @return Provider-specific key value to store in QueuePair device state.
 */
__host__ uint32_t normalize_qp_key(Provider provider, uint32_t key);

/**
 * @brief Normalize local and remote memory keys for QueuePair device state.
 *
 * @param provider Active RDMA provider.
 * @param lkey Local memory key from the registered memory region.
 * @param rkey Remote memory key from the registered memory region.
 * @param normalizedLkey Output local key in provider device format.
 * @param normalizedRkey Output remote key in provider device format.
 */
__host__ void normalize_mr_keys(Provider provider, uint32_t lkey, uint32_t rkey,
                                uint32_t* normalizedLkey,
                                uint32_t* normalizedRkey);

/**
 * @brief Select the RD atomic depth for RTR and RTS transitions.
 *
 * IONIC requires the maximum value used by its driver path. Other providers use
 * the device-reported max_qp_rd_atom, clamped to the 8-bit ibv_qp_attr field.
 *
 * @param provider Active RDMA provider.
 * @param deviceAttr Device attributes returned by ibv_query_device().
 * @return RD atomic depth for max_rd_atomic or max_dest_rd_atomic.
 */
__host__ uint8_t rd_atomic_cap(Provider provider,
                               const struct ibv_device_attr& deviceAttr);

/**
 * @brief Fill common RC QP creation attributes.
 *
 * @param attr Attribute structure to zero and populate.
 * @param pd Protection domain for the QP.
 * @param cq Send and receive completion queue.
 * @param sqDepth Send queue depth.
 * @param recvWr Receive work request depth.
 * @param recvSge Receive scatter-gather entry depth.
 * @param inlineThreshold Maximum inline data size.
 */
__host__ void fill_rc_qp_init_attr(struct ibv_qp_init_attr_ex* attr,
                                   struct ibv_pd* pd, struct ibv_cq* cq,
                                   int sqDepth, int recvWr, int recvSge,
                                   uint32_t inlineThreshold);

/**
 * @brief Dispatch QP state changes through the active provider backend.
 *
 * BNXT and ERNIC use their DV modify_qp entry points. Other providers use the
 * common ibverbs modify_qp path.
 *
 * @param provider Active RDMA provider.
 * @param qp Queue pair to modify.
 * @param attr Attribute values for the transition.
 * @param attrMask ibverbs attribute mask for the transition.
 * @return 0 on success, nonzero provider/libibverbs error otherwise.
 */
__host__ int modify_qp_dispatch(Provider provider, struct ibv_qp* qp,
                                struct ibv_qp_attr* attr, int attrMask);

/**
 * @brief Fill one RDMA verification source buffer and clear its destination.
 *
 * @param src Source buffer to fill with the LFSR data pattern.
 * @param dst Destination buffer to clear before the RDMA operation.
 * @param transferSize Number of bytes in each buffer.
 * @param seed Iteration-specific data pattern seed.
 */
__device__ void prepare_verify_buffer(uint8_t* src, uint8_t* dst,
                                      uint32_t transferSize, uint32_t seed);

/**
 * @brief Verify one RDMA destination buffer and update pass/fail counters.
 *
 * @param dst Destination buffer to verify.
 * @param transferSize Number of bytes in the buffer.
 * @param seed Iteration-specific data pattern seed.
 * @param label Failure message label.
 * @param op Operation or iteration index for diagnostics.
 * @param verifyPass Optional pass counter in host-mapped memory.
 * @param verifyFail Optional failure counter in host-mapped memory.
 */
__device__ void verify_buffer(uint8_t* dst, uint32_t transferSize,
                              uint32_t seed, const char* label, unsigned op,
                              uint32_t* verifyPass, uint32_t* verifyFail);

} // namespace rdma_ep
} // namespace xio

#endif // RDMA_EP_RDMA_COMMON_H
