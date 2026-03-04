/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef DOCA_VERBS_HIP_H
#define DOCA_VERBS_HIP_H

#include <cstdint>
#include <cstdlib>

#include "doca_error.hip.h"
#include "doca_gpunetio_verbs_def.hip.h"

#ifdef __cplusplus
extern "C" {
#endif

struct ibv_context;

enum doca_verbs_qp_state {
  DOCA_VERBS_QP_STATE_RST = 0x0,
  DOCA_VERBS_QP_STATE_INIT = 0x1,
  DOCA_VERBS_QP_STATE_RTR = 0x2,
  DOCA_VERBS_QP_STATE_RTS = 0x3,
  DOCA_VERBS_QP_STATE_ERR = 0x4,
};

enum doca_verbs_addr_type {
  DOCA_VERBS_ADDR_TYPE_IPv4,
  DOCA_VERBS_ADDR_TYPE_IPv6,
  DOCA_VERBS_ADDR_TYPE_IB_GRH,
  DOCA_VERBS_ADDR_TYPE_IB_NO_GRH,
};

enum doca_verbs_mtu_size {
  DOCA_VERBS_MTU_SIZE_256_BYTES = 0x0,
  DOCA_VERBS_MTU_SIZE_512_BYTES = 0x1,
  DOCA_VERBS_MTU_SIZE_1K_BYTES = 0x2,
  DOCA_VERBS_MTU_SIZE_2K_BYTES = 0x3,
  DOCA_VERBS_MTU_SIZE_4K_BYTES = 0x4,
  DOCA_VERBS_MTU_SIZE_RAW_ETHERNET = 0x5,
};

enum doca_verbs_qp_atomic_type {
  DOCA_VERBS_QP_ATOMIC_MODE_NONE = 0x0,
  DOCA_VERBS_QP_ATOMIC_MODE_IB_SPEC = 0x1,
  DOCA_VERBS_QP_ATOMIC_MODE_UP_TO_8BYTES = 0x3
};

enum {
  DOCA_VERBS_QP_ATTR_ALLOW_REMOTE_WRITE = (1 << 0),
  DOCA_VERBS_QP_ATTR_ALLOW_REMOTE_READ = (1 << 1),
  DOCA_VERBS_QP_ATTR_PKEY_INDEX = (1 << 2),
  DOCA_VERBS_QP_ATTR_MIN_RNR_TIMER = (1 << 3),
  DOCA_VERBS_QP_ATTR_PORT_NUM = (1 << 4),
  DOCA_VERBS_QP_ATTR_NEXT_STATE = (1 << 5),
  DOCA_VERBS_QP_ATTR_PATH_MTU = (1 << 7),
  DOCA_VERBS_QP_ATTR_RQ_PSN = (1 << 8),
  DOCA_VERBS_QP_ATTR_SQ_PSN = (1 << 9),
  DOCA_VERBS_QP_ATTR_DEST_QP_NUM = (1 << 10),
  DOCA_VERBS_QP_ATTR_AH_ATTR = (1 << 11),
  DOCA_VERBS_QP_ATTR_ACK_TIMEOUT = (1 << 13),
  DOCA_VERBS_QP_ATTR_RETRY_CNT = (1 << 14),
  DOCA_VERBS_QP_ATTR_RNR_RETRY = (1 << 15),
};

struct doca_verbs_gid {
  uint8_t raw[16];
};

struct doca_verbs_qp {
  uint32_t qpn;
};

struct doca_verbs_cq {
  int unused;
};

struct doca_verbs_ah_attr {
  struct ibv_context* context;
  struct doca_verbs_gid gid;
  enum doca_verbs_addr_type addr_type;
  uint32_t dlid;
  uint8_t sl;
  uint8_t sgid_index;
  uint8_t hop_limit;
  uint8_t traffic_class;
  bool has_gid;
};

struct doca_verbs_qp_attr {
  enum doca_verbs_qp_state next_state;
  enum doca_verbs_mtu_size path_mtu;
  uint32_t rq_psn;
  uint32_t sq_psn;
  uint32_t dest_qp_num;
  int allow_remote_write;
  int allow_remote_read;
  enum doca_verbs_qp_atomic_type allow_remote_atomic;
  struct doca_verbs_ah_attr* ah_attr;
  uint16_t pkey_index;
  uint16_t port_num;
  uint16_t ack_timeout;
  uint16_t retry_cnt;
  uint16_t rnr_retry;
  uint16_t min_rnr_timer;
};

doca_error_t doca_verbs_qp_attr_create(
  struct doca_verbs_qp_attr** verbs_qp_attr);
doca_error_t doca_verbs_qp_attr_destroy(
  struct doca_verbs_qp_attr* verbs_qp_attr);
doca_error_t doca_verbs_qp_attr_set_next_state(
  struct doca_verbs_qp_attr* verbs_qp_attr,
  enum doca_verbs_qp_state next_state);
doca_error_t doca_verbs_qp_attr_set_path_mtu(
  struct doca_verbs_qp_attr* verbs_qp_attr, enum doca_verbs_mtu_size path_mtu);
doca_error_t doca_verbs_qp_attr_set_rq_psn(
  struct doca_verbs_qp_attr* verbs_qp_attr, uint32_t rq_psn);
doca_error_t doca_verbs_qp_attr_set_sq_psn(
  struct doca_verbs_qp_attr* verbs_qp_attr, uint32_t sq_psn);
doca_error_t doca_verbs_qp_attr_set_port_num(
  struct doca_verbs_qp_attr* verbs_qp_attr, uint16_t port_num);
doca_error_t doca_verbs_qp_attr_set_ack_timeout(
  struct doca_verbs_qp_attr* verbs_qp_attr, uint16_t ack_timeout);
doca_error_t doca_verbs_qp_attr_set_retry_cnt(
  struct doca_verbs_qp_attr* verbs_qp_attr, uint16_t retry_cnt);
doca_error_t doca_verbs_qp_attr_set_rnr_retry(
  struct doca_verbs_qp_attr* verbs_qp_attr, uint16_t rnr_retry);
doca_error_t doca_verbs_qp_attr_set_min_rnr_timer(
  struct doca_verbs_qp_attr* verbs_qp_attr, uint16_t min_rnr_timer);
doca_error_t doca_verbs_qp_attr_set_allow_remote_write(
  struct doca_verbs_qp_attr* verbs_qp_attr, int allow_remote_write);
doca_error_t doca_verbs_qp_attr_set_allow_remote_read(
  struct doca_verbs_qp_attr* verbs_qp_attr, int allow_remote_read);
doca_error_t doca_verbs_qp_attr_set_allow_remote_atomic(
  struct doca_verbs_qp_attr* verbs_qp_attr,
  enum doca_verbs_qp_atomic_type allow_remote_atomic);
doca_error_t doca_verbs_qp_attr_set_ah_attr(
  struct doca_verbs_qp_attr* verbs_qp_attr,
  struct doca_verbs_ah_attr* verbs_ah);
doca_error_t doca_verbs_qp_attr_set_dest_qp_num(
  struct doca_verbs_qp_attr* verbs_qp_attr, uint32_t dest_qp_num);
doca_error_t doca_verbs_qp_attr_set_pkey_index(
  struct doca_verbs_qp_attr* verbs_qp_attr, uint16_t pkey_index);
doca_error_t doca_verbs_qp_modify(struct doca_verbs_qp* qp,
                                  struct doca_verbs_qp_attr* verbs_qp_attr,
                                  uint64_t attr_mask);
uint32_t doca_verbs_qp_get_qpn(struct doca_verbs_qp* qp);

doca_error_t doca_verbs_ah_attr_create(struct ibv_context* context,
                                       struct doca_verbs_ah_attr** verbs_ah);
doca_error_t doca_verbs_ah_attr_destroy(struct doca_verbs_ah_attr* verbs_ah);
doca_error_t doca_verbs_ah_attr_set_gid(struct doca_verbs_ah_attr* verbs_ah,
                                        struct doca_verbs_gid gid);
doca_error_t doca_verbs_ah_attr_set_addr_type(
  struct doca_verbs_ah_attr* verbs_ah, enum doca_verbs_addr_type addr_type);
doca_error_t doca_verbs_ah_attr_set_dlid(struct doca_verbs_ah_attr* verbs_ah,
                                         uint32_t dlid);
doca_error_t doca_verbs_ah_attr_set_sl(struct doca_verbs_ah_attr* verbs_ah,
                                       uint8_t sl);
doca_error_t doca_verbs_ah_attr_set_sgid_index(
  struct doca_verbs_ah_attr* verbs_ah, uint8_t sgid_index);
doca_error_t doca_verbs_ah_attr_set_hop_limit(
  struct doca_verbs_ah_attr* verbs_ah, uint8_t hop_limit);
doca_error_t doca_verbs_ah_attr_set_traffic_class(
  struct doca_verbs_ah_attr* verbs_ah, uint8_t traffic_class);

#ifdef __cplusplus
}
#endif

#endif
