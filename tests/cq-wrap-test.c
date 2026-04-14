/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * CPU-side RDMA WRITE loopback test to verify CQ wrap.
 * Uses standard ibverbs (not DV) to isolate NIC hardware
 * CQ behavior from GPU-side DV CQ polling.
 *
 * NOTE: Requires a NIC that supports standard ibverbs
 * loopback (QP connected to itself).  bnxt Thor 2 does
 * NOT support this -- use test-rdma-loopback with
 * --cpu-poll instead.
 *
 * Build:
 *   gcc -o cq-wrap-test tests/cq-wrap-test.c \
 *     -I build/_deps/rdma-core/install/include \
 *     -L build/_deps/rdma-core/install/lib \
 *     -libverbs
 *
 * Run:
 *   sudo LD_LIBRARY_PATH=build/_deps/rdma-core/install/lib \
 *     ./cq-wrap-test rocm-rdma-bnxt0 10000
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <infiniband/verbs.h>

static int gid_index = -1;

static int find_ipv4_gid(struct ibv_context* ctx, int port) {
  union ibv_gid gid;
  for (int i = 0; i < 16; i++) {
    if (ibv_query_gid(ctx, port, i, &gid))
      continue;
    if (gid.raw[0] == 0 && gid.raw[1] == 0 && gid.raw[10] == 0xff &&
        gid.raw[11] == 0xff)
      return i;
  }
  return 0;
}

int main(int argc, char** argv) {
  const char* dev_name = argc > 1 ? argv[1] : NULL;
  int iterations = argc > 2 ? atoi(argv[2]) : 10000;
  int cq_depth = argc > 3 ? atoi(argv[3]) : 256;
  int port = 1;
  int ret;

  if (!dev_name) {
    fprintf(stderr,
            "Usage: %s <rdma-device> "
            "[iterations] [cq-depth]\n",
            argv[0]);
    return 1;
  }

  int num_devs = 0;
  struct ibv_device** devs = ibv_get_device_list(&num_devs);
  if (!devs || num_devs == 0) {
    fprintf(stderr, "No IB devices found\n");
    return 1;
  }

  struct ibv_device* dev = NULL;
  for (int i = 0; i < num_devs; i++) {
    if (strcmp(ibv_get_device_name(devs[i]), dev_name) == 0) {
      dev = devs[i];
      break;
    }
  }
  if (!dev) {
    fprintf(stderr, "Device %s not found\n", dev_name);
    ibv_free_device_list(devs);
    return 1;
  }

  struct ibv_context* ctx = ibv_open_device(dev);
  ibv_free_device_list(devs);
  if (!ctx) {
    fprintf(stderr, "Failed to open device\n");
    return 1;
  }

  gid_index = find_ipv4_gid(ctx, port);
  printf("Using GID index %d\n", gid_index);

  struct ibv_pd* pd = ibv_alloc_pd(ctx);
  if (!pd) {
    fprintf(stderr, "Failed to alloc PD\n");
    return 1;
  }

  struct ibv_cq* cq = ibv_create_cq(ctx, cq_depth, NULL, NULL, 0);
  if (!cq) {
    fprintf(stderr,
            "Failed to create CQ "
            "(depth=%d)\n",
            cq_depth);
    return 1;
  }
  printf("CQ created: depth=%d (actual=%d)\n", cq_depth, cq->cqe);

  struct ibv_qp_init_attr qp_attr = {
    .send_cq = cq,
    .recv_cq = cq,
    .cap =
      {
        .max_send_wr = 16,
        .max_recv_wr = 1,
        .max_send_sge = 1,
        .max_recv_sge = 1,
      },
    .qp_type = IBV_QPT_RC,
    .sq_sig_all = 1,
  };

  struct ibv_qp* qp = ibv_create_qp(pd, &qp_attr);
  if (!qp) {
    fprintf(stderr, "Failed to create QP\n");
    return 1;
  }
  printf("QP created: qpn=%u\n", qp->qp_num);

  /* RESET -> INIT */
  struct ibv_qp_attr attr;
  memset(&attr, 0, sizeof(attr));
  attr.qp_state = IBV_QPS_INIT;
  attr.pkey_index = 0;
  attr.port_num = port;
  attr.qp_access_flags = IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_LOCAL_WRITE;
  ret = ibv_modify_qp(qp, &attr,
                      IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT |
                        IBV_QP_ACCESS_FLAGS);
  if (ret) {
    fprintf(stderr, "INIT failed: %d\n", ret);
    return 1;
  }

  /* INIT -> RTR (loopback to self) */
  union ibv_gid local_gid;
  ibv_query_gid(ctx, port, gid_index, &local_gid);

  memset(&attr, 0, sizeof(attr));
  attr.qp_state = IBV_QPS_RTR;
  attr.path_mtu = IBV_MTU_1024;
  attr.dest_qp_num = qp->qp_num;
  attr.rq_psn = 0;
  attr.max_dest_rd_atomic = 1;
  attr.min_rnr_timer = 12;
  attr.ah_attr.is_global = 1;
  attr.ah_attr.grh.sgid_index = gid_index;
  attr.ah_attr.grh.hop_limit = 1;
  attr.ah_attr.grh.traffic_class = 0;
  memcpy(&attr.ah_attr.grh.dgid, &local_gid, 16);
  attr.ah_attr.port_num = port;
  attr.ah_attr.sl = 1;

  ret = ibv_modify_qp(qp, &attr,
                      IBV_QP_STATE | IBV_QP_PATH_MTU | IBV_QP_DEST_QPN |
                        IBV_QP_RQ_PSN | IBV_QP_MAX_DEST_RD_ATOMIC |
                        IBV_QP_MIN_RNR_TIMER | IBV_QP_AV);
  if (ret) {
    fprintf(stderr, "RTR failed: %d\n", ret);
    return 1;
  }

  /* RTR -> RTS */
  memset(&attr, 0, sizeof(attr));
  attr.qp_state = IBV_QPS_RTS;
  attr.sq_psn = 0;
  attr.timeout = 14;
  attr.retry_cnt = 7;
  attr.rnr_retry = 7;
  attr.max_rd_atomic = 1;

  ret = ibv_modify_qp(qp, &attr,
                      IBV_QP_STATE | IBV_QP_SQ_PSN | IBV_QP_TIMEOUT |
                        IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY |
                        IBV_QP_MAX_QP_RD_ATOMIC);
  if (ret) {
    fprintf(stderr, "RTS failed: %d\n", ret);
    return 1;
  }
  printf("QP in RTS (loopback)\n");

  /* Register MR */
  size_t buf_size = 512;
  uint8_t* buf = (uint8_t*)malloc(buf_size);
  if (!buf) {
    fprintf(stderr, "malloc failed\n");
    return 1;
  }
  memset(buf, 0xA5, buf_size / 2);
  memset(buf + buf_size / 2, 0, buf_size / 2);

  struct ibv_mr* mr = ibv_reg_mr(pd, buf, buf_size,
                                 IBV_ACCESS_LOCAL_WRITE |
                                   IBV_ACCESS_REMOTE_WRITE);
  if (!mr) {
    fprintf(stderr, "Failed to reg MR\n");
    free(buf);
    return 1;
  }

  uint8_t* src = buf;
  uint8_t* dst = buf + buf_size / 2;

  printf("Running %d RDMA WRITE iterations "
         "(CQ depth=%d)...\n",
         iterations, cq->cqe);

  int failed = 0;
  for (int i = 0; i < iterations; i++) {
    struct ibv_sge sge = {
      .addr = (uintptr_t)src,
      .length = buf_size / 2,
      .lkey = mr->lkey,
    };
    struct ibv_send_wr wr = {
      .wr_id = i,
      .sg_list = &sge,
      .num_sge = 1,
      .opcode = IBV_WR_RDMA_WRITE,
      .send_flags = IBV_SEND_SIGNALED,
      .wr.rdma =
        {
          .remote_addr = (uintptr_t)dst,
          .rkey = mr->rkey,
        },
    };
    struct ibv_send_wr* bad_wr = NULL;

    ret = ibv_post_send(qp, &wr, &bad_wr);
    if (ret) {
      fprintf(stderr,
              "post_send failed at iter %d:"
              " %d\n",
              i, ret);
      failed = 1;
      break;
    }

    /* Poll CQ */
    struct ibv_wc wc;
    int polls = 0;
    while (1) {
      int ne = ibv_poll_cq(cq, 1, &wc);
      if (ne < 0) {
        fprintf(stderr, "poll_cq failed at iter %d\n", i);
        failed = 1;
        break;
      }
      if (ne > 0) {
        if (wc.status != IBV_WC_SUCCESS) {
          fprintf(stderr,
                  "WC error at iter %d:"
                  " %s (%d)\n",
                  i, ibv_wc_status_str(wc.status), wc.status);
          failed = 1;
        }
        break;
      }
      polls++;
      if (polls > 100000000) {
        fprintf(stderr, "poll timeout at iter %d\n", i);
        failed = 1;
        break;
      }
    }
    if (failed)
      break;

    if ((i + 1) % 1000 == 0)
      printf("  %d iterations OK\n", i + 1);
  }

  if (!failed)
    printf("PASSED: %d iterations completed "
           "(CQ wrapped %d times)\n",
           iterations, iterations / cq->cqe);
  else
    printf("FAILED\n");

  ibv_dereg_mr(mr);
  free(buf);
  ibv_destroy_qp(qp);
  ibv_destroy_cq(cq);
  ibv_dealloc_pd(pd);
  ibv_close_device(ctx);

  return failed ? 1 : 0;
}
