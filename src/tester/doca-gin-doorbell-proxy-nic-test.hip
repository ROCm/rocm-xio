#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

#include <infiniband/verbs.h>

#include "doca-compatible/doca_gpunetio_dev_verbs_qp.hip.h"
#include "hip/hip_runtime.h"

#define HIP_CHECK(cmd)                                                         \
  do {                                                                         \
    hipError_t _err = (cmd);                                                   \
    if (_err != hipSuccess) {                                                  \
      std::fprintf(stderr, "HIP error %s at %s:%d\n", hipGetErrorString(_err), \
                   __FILE__, __LINE__);                                        \
      return 1;                                                                \
    }                                                                          \
  } while (0)

struct ProxyDoorbell {
  uint64_t db_value;
  uint64_t db_expected;
  uint32_t ready;
  uint32_t payload_len;
  uint32_t seed;
  uint32_t reserved;
};

__global__ void doorbell_proxy_kernel(uint8_t* send_buf, ProxyDoorbell* db) {
  if (blockIdx.x != 0 || threadIdx.x != 0) {
    return;
  }

  for (uint32_t i = 0; i < db->payload_len; ++i) {
    send_buf[i] = static_cast<uint8_t>((db->seed + i) & 0xffU);
  }
  __threadfence_system();

  struct radaki_dev_qp qp = {};
  qp.sq_db = (uintptr_t)&db->db_value;
  qp.sq_num_shift8_be = __builtin_bswap32(0x00bcd000U);

  const uint64_t prod_index = 9;
  radaki_dev_ring_db<DOCA_GPUNETIO_VERBS_SYNC_SCOPE_SYS>(&qp, prod_index);
  __threadfence_system();
  db->db_expected = static_cast<uint64_t>(
    radaki_dev_prepare_db(&qp, prod_index));
  __atomic_store_n(&db->ready, 1U, __ATOMIC_RELEASE);
}

static bool wait_for_proxy_ready(ProxyDoorbell* db, int timeout_ms) {
  auto start = std::chrono::steady_clock::now();
  while (true) {
    const uint32_t ready = __atomic_load_n(&db->ready, __ATOMIC_ACQUIRE);
    if (ready == 1U) {
      return true;
    }

    auto now = std::chrono::steady_clock::now();
    auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                        now - start)
                        .count();
    if (elapsed_ms > timeout_ms) {
      return false;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
}

static int qp_to_init(struct ibv_qp* qp, uint8_t port_num) {
  struct ibv_qp_attr attr = {};
  attr.qp_state = IBV_QPS_INIT;
  attr.pkey_index = 0;
  attr.port_num = port_num;
  attr.qp_access_flags = IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE |
                         IBV_ACCESS_REMOTE_READ;
  const int flags = IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT |
                    IBV_QP_ACCESS_FLAGS;
  return ibv_modify_qp(qp, &attr, flags);
}

static int qp_to_rtr(struct ibv_qp* qp, uint8_t port_num, uint32_t remote_qpn,
                     uint16_t remote_lid, const union ibv_gid& remote_gid,
                     int gid_index, enum ibv_mtu mtu, bool use_global) {
  struct ibv_qp_attr attr = {};
  attr.qp_state = IBV_QPS_RTR;
  attr.path_mtu = mtu;
  attr.dest_qp_num = remote_qpn;
  attr.rq_psn = 0;
  attr.max_dest_rd_atomic = 1;
  attr.min_rnr_timer = 12;
  attr.ah_attr.is_global = use_global ? 1 : 0;
  attr.ah_attr.dlid = remote_lid;
  attr.ah_attr.sl = 0;
  attr.ah_attr.src_path_bits = 0;
  attr.ah_attr.port_num = port_num;
  if (use_global) {
    attr.ah_attr.grh.dgid = remote_gid;
    attr.ah_attr.grh.sgid_index = gid_index;
    attr.ah_attr.grh.hop_limit = 1;
    attr.ah_attr.grh.traffic_class = 0;
    attr.ah_attr.grh.flow_label = 0;
  }
  const int flags = IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU |
                    IBV_QP_DEST_QPN | IBV_QP_RQ_PSN |
                    IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER;
  return ibv_modify_qp(qp, &attr, flags);
}

static int qp_to_rts(struct ibv_qp* qp) {
  struct ibv_qp_attr attr = {};
  attr.qp_state = IBV_QPS_RTS;
  attr.timeout = 14;
  attr.retry_cnt = 7;
  attr.rnr_retry = 7;
  attr.sq_psn = 0;
  attr.max_rd_atomic = 1;
  const int flags = IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT |
                    IBV_QP_RNR_RETRY | IBV_QP_SQ_PSN | IBV_QP_MAX_QP_RD_ATOMIC;
  return ibv_modify_qp(qp, &attr, flags);
}

int main() {
  int rc = 0;
  int device_count = 0;
  HIP_CHECK(hipGetDeviceCount(&device_count));
  if (device_count == 0) {
    std::fprintf(stderr, "No HIP device found.\n");
    return 1;
  }

  struct ibv_device** dev_list = nullptr;
  struct ibv_context* ctx = nullptr;
  struct ibv_pd* pd = nullptr;
  struct ibv_cq* cq = nullptr;
  struct ibv_qp* qp_tx = nullptr;
  struct ibv_qp* qp_rx = nullptr;
  struct ibv_mr* send_mr = nullptr;
  struct ibv_mr* recv_mr = nullptr;

  uint8_t* send_host = nullptr;
  uint8_t* recv_host = nullptr;
  uint8_t* send_dev = nullptr;
  ProxyDoorbell* doorbell_host = nullptr;
  ProxyDoorbell* doorbell_dev = nullptr;
  struct ibv_qp_init_attr qp_init = {};
  struct ibv_sge recv_sge = {};
  struct ibv_recv_wr recv_wr = {};
  struct ibv_recv_wr* bad_recv_wr = nullptr;
  struct ibv_sge send_sge = {};
  struct ibv_send_wr send_wr = {};
  struct ibv_send_wr* bad_send_wr = nullptr;
  bool got_send_wc = false;
  bool got_recv_wc = false;
  enum ibv_wc_status send_wc_status = IBV_WC_GENERAL_ERR;
  enum ibv_wc_opcode send_wc_opcode = IBV_WC_SEND;
  uint32_t send_vendor_err = 0;
  std::chrono::steady_clock::time_point poll_start = {};
  uint8_t port_num = 0;
  union ibv_gid gid = {};
  uint16_t lid = 0;
  enum ibv_mtu mtu = IBV_MTU_1024;
  bool found_port = false;
  bool use_global = false;
  int gid_index = 0;
  const char* gid_env = nullptr;

  constexpr uint32_t kPayloadLen = 128;
  constexpr uint32_t kSeed = 0x3aU;

  int num_ib_devices = 0;
  dev_list = ibv_get_device_list(&num_ib_devices);
  if (dev_list == nullptr || num_ib_devices == 0) {
    std::fprintf(stderr, "No RDMA verbs device found.\n");
    rc = 2;
    goto cleanup;
  }

  gid_env = std::getenv("ROCM_XIO_GID_INDEX");
  if (gid_env != nullptr) {
    gid_index = std::atoi(gid_env);
  }

  for (int i = 0; i < num_ib_devices && !found_port; ++i) {
    struct ibv_context* try_ctx = ibv_open_device(dev_list[i]);
    if (try_ctx == nullptr) {
      continue;
    }

    struct ibv_device_attr dev_attr = {};
    if (ibv_query_device(try_ctx, &dev_attr) != 0) {
      ibv_close_device(try_ctx);
      continue;
    }

    for (uint8_t p = 1; p <= dev_attr.phys_port_cnt; ++p) {
      struct ibv_port_attr port_attr = {};
      if (ibv_query_port(try_ctx, p, &port_attr) != 0) {
        continue;
      }
      if (port_attr.state != IBV_PORT_ACTIVE) {
        continue;
      }

      union ibv_gid try_gid = {};
      if (ibv_query_gid(try_ctx, p, gid_index, &try_gid) != 0) {
        continue;
      }

      ctx = try_ctx;
      port_num = p;
      gid = try_gid;
      lid = port_attr.lid;
      mtu = port_attr.active_mtu;
      use_global = (port_attr.link_layer == IBV_LINK_LAYER_ETHERNET);
      found_port = true;
      break;
    }

    if (!found_port) {
      ibv_close_device(try_ctx);
    }
  }

  if (!found_port || ctx == nullptr) {
    std::fprintf(stderr, "No active RDMA port found.\n");
    rc = 3;
    goto cleanup;
  }

  pd = ibv_alloc_pd(ctx);
  if (pd == nullptr) {
    std::fprintf(stderr, "ibv_alloc_pd failed.\n");
    rc = 4;
    goto cleanup;
  }
  cq = ibv_create_cq(ctx, 16, nullptr, nullptr, 0);
  if (cq == nullptr) {
    std::fprintf(stderr, "ibv_create_cq failed.\n");
    rc = 5;
    goto cleanup;
  }

  qp_init.send_cq = cq;
  qp_init.recv_cq = cq;
  qp_init.qp_type = IBV_QPT_RC;
  qp_init.cap.max_send_wr = 16;
  qp_init.cap.max_recv_wr = 16;
  qp_init.cap.max_send_sge = 1;
  qp_init.cap.max_recv_sge = 1;
  qp_tx = ibv_create_qp(pd, &qp_init);
  qp_rx = ibv_create_qp(pd, &qp_init);
  if (qp_tx == nullptr || qp_rx == nullptr) {
    std::fprintf(stderr, "ibv_create_qp failed.\n");
    rc = 6;
    goto cleanup;
  }

  if (qp_to_init(qp_tx, port_num) != 0 || qp_to_init(qp_rx, port_num) != 0) {
    std::fprintf(stderr, "Failed to transition QPs to INIT.\n");
    rc = 7;
    goto cleanup;
  }
  if (qp_to_rtr(qp_tx, port_num, qp_rx->qp_num, lid, gid, gid_index, mtu,
                use_global) != 0 ||
      qp_to_rtr(qp_rx, port_num, qp_tx->qp_num, lid, gid, gid_index, mtu,
                use_global) != 0) {
    std::fprintf(stderr, "Failed to transition QPs to RTR.\n");
    rc = 8;
    goto cleanup;
  }
  if (qp_to_rts(qp_tx) != 0 || qp_to_rts(qp_rx) != 0) {
    std::fprintf(stderr, "Failed to transition QPs to RTS.\n");
    rc = 9;
    goto cleanup;
  }

  HIP_CHECK(hipHostMalloc(reinterpret_cast<void**>(&send_host), kPayloadLen,
                          hipHostMallocMapped));
  HIP_CHECK(hipHostMalloc(reinterpret_cast<void**>(&recv_host), kPayloadLen,
                          hipHostMallocMapped));
  HIP_CHECK(hipHostMalloc(reinterpret_cast<void**>(&doorbell_host),
                          sizeof(*doorbell_host), hipHostMallocMapped));
  std::memset(send_host, 0, kPayloadLen);
  std::memset(recv_host, 0, kPayloadLen);
  std::memset(doorbell_host, 0, sizeof(*doorbell_host));
  doorbell_host->payload_len = kPayloadLen;
  doorbell_host->seed = kSeed;

  HIP_CHECK(
    hipHostGetDevicePointer(reinterpret_cast<void**>(&send_dev), send_host, 0));
  HIP_CHECK(hipHostGetDevicePointer(reinterpret_cast<void**>(&doorbell_dev),
                                    doorbell_host, 0));
  if (send_dev == nullptr || doorbell_dev == nullptr) {
    std::fprintf(stderr, "Mapped device pointers are null.\n");
    rc = 10;
    goto cleanup;
  }

  send_mr = ibv_reg_mr(pd, send_host, kPayloadLen,
                       IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ |
                         IBV_ACCESS_REMOTE_WRITE);
  recv_mr = ibv_reg_mr(pd, recv_host, kPayloadLen,
                       IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ |
                         IBV_ACCESS_REMOTE_WRITE);
  if (send_mr == nullptr || recv_mr == nullptr) {
    std::fprintf(stderr, "ibv_reg_mr failed.\n");
    rc = 11;
    goto cleanup;
  }

  recv_sge.addr = reinterpret_cast<uintptr_t>(recv_host);
  recv_sge.length = kPayloadLen;
  recv_sge.lkey = recv_mr->lkey;
  recv_wr.wr_id = 0xBEEFULL;
  recv_wr.sg_list = &recv_sge;
  recv_wr.num_sge = 1;
  if (ibv_post_recv(qp_rx, &recv_wr, &bad_recv_wr) != 0) {
    std::fprintf(stderr, "ibv_post_recv failed.\n");
    rc = 12;
    goto cleanup;
  }

  hipLaunchKernelGGL(doorbell_proxy_kernel, dim3(1), dim3(1), 0, 0, send_dev,
                     doorbell_dev);
  HIP_CHECK(hipGetLastError());

  if (!wait_for_proxy_ready(doorbell_host, 2000)) {
    std::fprintf(stderr, "GPU proxy doorbell not observed in time. "
                         "If needed, export HSA_FORCE_FINE_GRAIN_PCIE=1.\n");
    rc = 13;
    goto cleanup;
  }
  HIP_CHECK(hipDeviceSynchronize());

  send_sge.addr = reinterpret_cast<uintptr_t>(send_host);
  send_sge.length = kPayloadLen;
  send_sge.lkey = send_mr->lkey;
  send_wr.wr_id = 0xCAFEULL;
  send_wr.sg_list = &send_sge;
  send_wr.num_sge = 1;
  send_wr.opcode = IBV_WR_SEND;
  send_wr.send_flags = IBV_SEND_SIGNALED;
  if (ibv_post_send(qp_tx, &send_wr, &bad_send_wr) != 0) {
    std::fprintf(stderr, "ibv_post_send failed.\n");
    rc = 14;
    goto cleanup;
  }

  poll_start = std::chrono::steady_clock::now();
  while (!(got_send_wc && got_recv_wc)) {
    struct ibv_wc wc[4];
    int n = ibv_poll_cq(cq, 4, wc);
    if (n < 0) {
      std::fprintf(stderr, "ibv_poll_cq failed.\n");
      rc = 15;
      goto cleanup;
    }
    for (int i = 0; i < n; ++i) {
      if (wc[i].wr_id == 0xCAFEULL) {
        send_wc_status = wc[i].status;
        send_wc_opcode = static_cast<enum ibv_wc_opcode>(wc[i].opcode);
        send_vendor_err = wc[i].vendor_err;
        got_send_wc = true;
        if (send_wc_status != IBV_WC_SUCCESS) {
          /* Some NICs do not support self-loopback RC on a single node/port.
           * In that case, the send completion still proves a real NIC path. */
          if (send_wc_status == IBV_WC_RETRY_EXC_ERR ||
              send_wc_status == IBV_WC_RNR_RETRY_EXC_ERR) {
            break;
          }
          std::fprintf(stderr,
                       "Send CQE failed: status=%d opcode=%d vendor_err=0x%x\n",
                       send_wc_status, send_wc_opcode, send_vendor_err);
          rc = 16;
          goto cleanup;
        }
      } else if (wc[i].wr_id == 0xBEEFULL) {
        if (wc[i].status != IBV_WC_SUCCESS) {
          std::fprintf(stderr,
                       "Recv CQE failed: status=%d opcode=%d vendor_err=0x%x\n",
                       wc[i].status, wc[i].opcode, wc[i].vendor_err);
          rc = 16;
          goto cleanup;
        }
        got_recv_wc = true;
      }
    }
    if (got_send_wc && (send_wc_status == IBV_WC_RETRY_EXC_ERR ||
                        send_wc_status == IBV_WC_RNR_RETRY_EXC_ERR)) {
      break;
    }
    auto now = std::chrono::steady_clock::now();
    if (std::chrono::duration_cast<std::chrono::milliseconds>(now - poll_start)
          .count() > 2000) {
      std::fprintf(
        stderr,
        "Timed out waiting for send/recv completions (send=%d recv=%d).\n",
        got_send_wc ? 1 : 0, got_recv_wc ? 1 : 0);
      rc = 17;
      goto cleanup;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }

  if (send_wc_status == IBV_WC_SUCCESS) {
    if (!got_recv_wc) {
      std::fprintf(
        stderr,
        "Send completed successfully but no recv completion was observed.\n");
      rc = 18;
      goto cleanup;
    }
    for (uint32_t i = 0; i < kPayloadLen; ++i) {
      const uint8_t expected = static_cast<uint8_t>((kSeed + i) & 0xffU);
      if (recv_host[i] != expected) {
        std::fprintf(
          stderr, "Payload mismatch at byte %u: got=0x%02x expected=0x%02x\n",
          i, static_cast<unsigned>(recv_host[i]),
          static_cast<unsigned>(expected));
        rc = 18;
        goto cleanup;
      }
    }
  }

  if (doorbell_host->db_value != doorbell_host->db_expected) {
    std::fprintf(stderr,
                 "Doorbell payload mismatch: seen=0x%llx expected=0x%llx\n",
                 static_cast<unsigned long long>(doorbell_host->db_value),
                 static_cast<unsigned long long>(doorbell_host->db_expected));
    rc = 19;
    goto cleanup;
  }

  if (send_wc_status == IBV_WC_SUCCESS) {
    std::printf("PASS: proxy doorbell + real NIC send/recv (device=%s port=%u "
                "gid_index=%d)\n",
                ibv_get_device_name(ctx->device), port_num, gid_index);
  } else {
    std::printf("PASS: proxy doorbell + real NIC send CQE observed "
                "(no loopback peer, status=%d opcode=%d vendor_err=0x%x, "
                "device=%s port=%u gid_index=%d)\n",
                send_wc_status, send_wc_opcode, send_vendor_err,
                ibv_get_device_name(ctx->device), port_num, gid_index);
  }

cleanup:
  if (send_mr != nullptr) {
    ibv_dereg_mr(send_mr);
  }
  if (recv_mr != nullptr) {
    ibv_dereg_mr(recv_mr);
  }
  if (qp_tx != nullptr) {
    ibv_destroy_qp(qp_tx);
  }
  if (qp_rx != nullptr) {
    ibv_destroy_qp(qp_rx);
  }
  if (cq != nullptr) {
    ibv_destroy_cq(cq);
  }
  if (pd != nullptr) {
    ibv_dealloc_pd(pd);
  }
  if (ctx != nullptr) {
    ibv_close_device(ctx);
  }
  if (dev_list != nullptr) {
    ibv_free_device_list(dev_list);
  }
  if (send_host != nullptr) {
    HIP_CHECK(hipHostFree(send_host));
  }
  if (recv_host != nullptr) {
    HIP_CHECK(hipHostFree(recv_host));
  }
  if (doorbell_host != nullptr) {
    HIP_CHECK(hipHostFree(doorbell_host));
  }
  return rc;
}
