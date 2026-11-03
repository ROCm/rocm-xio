/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * CPU-side ibverbs RDMA loopback for rocjitsu emulated GPU.
 * This file includes infiniband/verbs.h before any ibv-core.hpp to avoid
 * type redefinition conflicts with the standalone type definitions.
 */

/* Include real verbs.h first, before ibv-core.hpp standalone types. */
extern "C" {
#include <infiniband/verbs.h>
}
#define INFINIBAND_VERBS_H /* prevent ibv-core.hpp from redefining types */

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "gda-backend.hpp"
#include "ibv-wrapper.hpp"
#include "xio.h"

namespace xio {
namespace rdma_ep {

int Backend::cpu_loopback_smoke_test(int iterations, int transfer_size) {
  if (!qp_ || !cq_ || !pd_)
    return -1;

  // CPU-side RDMA WRITE loopback: src -> dst via ibv_post_send.
  // Doorbells go through the kernel ionic driver → QEMU → rocm-ernic.
  // No GPU involved — safe on rocjitsu emulated GPU.
  size_t buf_size = (size_t)transfer_size * 2;
  void* buf = nullptr;
  if (posix_memalign(&buf, 4096, buf_size) != 0 || !buf) {
    fprintf(stderr, "rdma_ep: cpu_loopback: posix_memalign failed\n");
    return -1;
  }
  memset(buf, 0, buf_size);

  int access = IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE |
               IBV_ACCESS_REMOTE_READ;
  struct ibv_mr* mr = ibv.reg_mr_host(pd_, buf, buf_size, access);
  if (!mr) {
    fprintf(stderr, "rdma_ep: cpu_loopback: ibv_reg_mr failed\n");
    free(buf);
    return -1;
  }

  uint8_t* src = static_cast<uint8_t*>(buf);
  uint8_t* dst = src + transfer_size;
  int failures = 0;

  for (int iter = 0; iter < iterations; iter++) {
    memset(src, (uint8_t)(0xA5 ^ iter), transfer_size);
    memset(dst, 0x00, transfer_size);

    struct ibv_sge sge {};
    sge.addr = reinterpret_cast<uint64_t>(src);
    sge.length = (uint32_t)transfer_size;
    sge.lkey = mr->lkey;

    struct ibv_send_wr wr {};
    wr.wr_id = (uint64_t)iter;
    wr.sg_list = &sge;
    wr.num_sge = 1;
    wr.opcode = IBV_WR_RDMA_WRITE;
    wr.send_flags = IBV_SEND_SIGNALED;
    wr.wr.rdma.remote_addr = reinterpret_cast<uint64_t>(dst);
    wr.wr.rdma.rkey = mr->rkey;

    struct ibv_send_wr* bad_wr = nullptr;
    int ret = ibv_post_send(qp_, &wr, &bad_wr);
    if (ret != 0) {
      fprintf(stderr, "rdma_ep: cpu_loopback: ibv_post_send failed: %d\n", ret);
      failures++;
      continue;
    }

    struct ibv_wc wc {};
    int polls = 0;
    const int max_polls = 1000000;
    int ne = 0;
    while (polls < max_polls) {
      ne = ibv_poll_cq(cq_, 1, &wc);
      if (ne > 0)
        break;
      if (ne < 0) {
        fprintf(stderr, "rdma_ep: cpu_loopback: ibv_poll_cq error: %d\n", ne);
        failures++;
        break;
      }
      polls++;
    }
    if (ne == 0) {
      fprintf(stderr, "rdma_ep: cpu_loopback: CQ timeout on iter %d\n", iter);
      failures++;
      continue;
    }
    if (wc.status != IBV_WC_SUCCESS) {
      fprintf(stderr, "rdma_ep: cpu_loopback: WC error %d on iter %d\n",
              wc.status, iter);
      failures++;
      continue;
    }
    if (memcmp(src, dst, transfer_size) != 0) {
      fprintf(stderr, "rdma_ep: cpu_loopback: data mismatch on iter %d\n",
              iter);
      failures++;
    }
  }

  ibv.dereg_mr(mr);
  free(buf);

  if (failures == 0)
    fprintf(stderr, "rdma_ep: cpu_loopback: %d iteration(s) passed\n",
            iterations);
  return failures;
}

} // namespace rdma_ep
} // namespace xio
