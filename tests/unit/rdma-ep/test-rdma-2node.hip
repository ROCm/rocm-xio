/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * 2-Node RDMA client-server test.
 *
 * Uses TCP over management network for QP info exchange, then
 * GPU-initiated RDMA WRITE over Thor 2 NICs for data transfer.
 *
 * Usage:
 *   Server: ./test-rdma-2node --server [--device bnxt_re0] [--gid-index 3]
 *   Client: ./test-rdma-2node --client --server-host <hostname> [--device bnxt_re0] [--gid-index 3]
 *
 * Requires: BNXT NIC (Thor 2), GDA_BNXT=ON build, two nodes with RDMA fabric.
 */

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <unistd.h>

#include <hip/hip_runtime.h>

#include "gda-backend.hpp"
#include "queue-pair.hpp"
#include "vendor-ops.hpp"

#if !defined(GDA_BNXT)
int main() {
  printf("SKIPPED: GDA_BNXT not enabled.\n");
  return 0;
}
#else

using namespace rdma_ep;

static constexpr uint16_t TCP_PORT = 18515;
static constexpr uint32_t WRITE_SIZE = 4096;
static constexpr uint8_t DATA_PATTERN = 0xA5;
static constexpr int PINGPONG_ITERS = 100;
static constexpr uint32_t PINGPONG_SIZE = 8;

// --- Wire protocol for TCP exchange ---

struct ExchangeMsg {
  uint32_t qpn;
  uint32_t rkey;
  uint64_t remote_addr;
  uint8_t gid[16];
} __attribute__((packed));

// --- TCP helpers ---

static int tcp_send_all(int fd, const void *buf, size_t len) {
  const uint8_t *p = static_cast<const uint8_t *>(buf);
  while (len > 0) {
    ssize_t n = send(fd, p, len, 0);
    if (n <= 0) return -1;
    p += n;
    len -= n;
  }
  return 0;
}

static int tcp_recv_all(int fd, void *buf, size_t len) {
  uint8_t *p = static_cast<uint8_t *>(buf);
  while (len > 0) {
    ssize_t n = recv(fd, p, len, 0);
    if (n <= 0) return -1;
    p += n;
    len -= n;
  }
  return 0;
}

static int tcp_server_accept() {
  int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
  if (listen_fd < 0) { perror("socket"); return -1; }

  int opt = 1;
  setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

  struct sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = INADDR_ANY;
  addr.sin_port = htons(TCP_PORT);

  if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
    perror("bind"); close(listen_fd); return -1;
  }
  if (listen(listen_fd, 1) < 0) {
    perror("listen"); close(listen_fd); return -1;
  }

  printf("TCP: Listening on port %u...\n", TCP_PORT);
  int conn_fd = accept(listen_fd, nullptr, nullptr);
  close(listen_fd);
  if (conn_fd < 0) { perror("accept"); return -1; }
  printf("TCP: Client connected.\n");
  return conn_fd;
}

static int tcp_client_connect(const char *hostname) {
  struct addrinfo hints{}, *res;
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;

  char port_str[8];
  snprintf(port_str, sizeof(port_str), "%u", TCP_PORT);

  int err = getaddrinfo(hostname, port_str, &hints, &res);
  if (err != 0) {
    fprintf(stderr, "getaddrinfo(%s): %s\n", hostname, gai_strerror(err));
    return -1;
  }

  int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
  if (fd < 0) { perror("socket"); freeaddrinfo(res); return -1; }

  printf("TCP: Connecting to %s:%u...\n", hostname, TCP_PORT);
  if (connect(fd, res->ai_addr, res->ai_addrlen) < 0) {
    perror("connect"); close(fd); freeaddrinfo(res); return -1;
  }
  freeaddrinfo(res);
  printf("TCP: Connected.\n");
  return fd;
}

static int exchange_info(int tcp_fd, const ExchangeMsg &local,
                         ExchangeMsg *remote) {
  if (tcp_send_all(tcp_fd, &local, sizeof(local)) != 0) return -1;
  if (tcp_recv_all(tcp_fd, remote, sizeof(*remote)) != 0) return -1;
  return 0;
}

static int tcp_sync(int tcp_fd) {
  uint8_t byte = 1;
  if (tcp_send_all(tcp_fd, &byte, 1) != 0) return -1;
  if (tcp_recv_all(tcp_fd, &byte, 1) != 0) return -1;
  return 0;
}

// --- GPU kernels ---

__global__ void rdma_write_kernel(QueuePair *qp, void *dst, void *src,
                                  uint32_t length) {
  if (threadIdx.x != 0) return;
  qp->put_nbi_single(dst, src, length, true);
  qp->quiet_single();
}

// Ping-pong protocol:
// Each side has two flags in its registered buffer:
//   send_flag: local staging area for the value we RDMA WRITE to remote
//   recv_flag: written by remote RDMA WRITE, polled locally
//
// Client iteration i:
//   1. Write i+1 to send_flag
//   2. RDMA WRITE send_flag -> server's recv_flag
//   3. quiet (wait for CQE)
//   4. Poll recv_flag until it reaches i+1 (server wrote back)
//
// Server iteration i:
//   1. Poll recv_flag until it reaches i+1 (client wrote)
//   2. Write i+1 to send_flag
//   3. RDMA WRITE send_flag -> client's recv_flag
//   4. quiet

__global__ void pingpong_client_kernel(QueuePair *qp,
                                       volatile uint64_t *send_flag,
                                       volatile uint64_t *recv_flag,
                                       void *remote_recv_flag_addr,
                                       uint32_t iters,
                                       unsigned long long *elapsed) {
  if (threadIdx.x != 0) return;

  unsigned long long start = wall_clock64();

  for (uint32_t i = 0; i < iters; i++) {
    uint64_t val = i + 1;

    *send_flag = val;
    __threadfence_system();

    qp->put_nbi_single(remote_recv_flag_addr, (void *)send_flag,
                        sizeof(uint64_t), true);
    qp->quiet_single();

    while (*recv_flag != val) {
      __builtin_amdgcn_s_sleep(1);
    }
  }

  *elapsed = wall_clock64() - start;
}

__global__ void pingpong_server_kernel(QueuePair *qp,
                                       volatile uint64_t *send_flag,
                                       volatile uint64_t *recv_flag,
                                       void *remote_recv_flag_addr,
                                       uint32_t iters) {
  if (threadIdx.x != 0) return;

  for (uint32_t i = 0; i < iters; i++) {
    uint64_t expected = i + 1;

    while (*recv_flag != expected) {
      __builtin_amdgcn_s_sleep(1);
    }

    *send_flag = expected;
    __threadfence_system();

    qp->put_nbi_single(remote_recv_flag_addr, (void *)send_flag,
                        sizeof(uint64_t), true);
    qp->quiet_single();
  }
}

// --- Main ---

static void print_usage(const char *prog) {
  fprintf(stderr,
    "Usage:\n"
    "  %s --server [--device DEV] [--gid-index N]\n"
    "  %s --client --server-host HOST [--device DEV] [--gid-index N]\n",
    prog, prog);
}

int main(int argc, char **argv) {
  bool is_server = false;
  bool is_client = false;
  const char *server_host = nullptr;
  const char *device_name = nullptr;
  int gid_index = 3;

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--server") == 0) is_server = true;
    else if (strcmp(argv[i], "--client") == 0) is_client = true;
    else if (strcmp(argv[i], "--server-host") == 0 && i + 1 < argc) server_host = argv[++i];
    else if (strcmp(argv[i], "--device") == 0 && i + 1 < argc) device_name = argv[++i];
    else if (strcmp(argv[i], "--gid-index") == 0 && i + 1 < argc) gid_index = atoi(argv[++i]);
    else { print_usage(argv[0]); return 1; }
  }

  if (!is_server && !is_client) { print_usage(argv[0]); return 1; }
  if (is_client && !server_host) { fprintf(stderr, "Client needs --server-host\n"); return 1; }

  const char *role = is_server ? "SERVER" : "CLIENT";
  setbuf(stdout, NULL);
  printf("=== 2-Node RDMA Test [%s] ===\n\n", role);

  // --- Init HIP ---
  hipError_t herr = hipInit(0);
  if (herr != hipSuccess) { fprintf(stderr, "hipInit: %s\n", hipGetErrorString(herr)); return 1; }
  (void)hipSetDevice(0);

  // --- Create Backend (loopback=false, defer QP connection) ---
  BackendConfig cfg;
  cfg.provider = Provider::BNXT;
  cfg.gpu_device_id = 0;
  cfg.sq_depth = 256;
  cfg.cq_depth = 256;
  cfg.inline_threshold = 28;
  cfg.loopback = false;
  if (device_name) cfg.hca_list = device_name;

  Backend backend(cfg);
  int ret = backend.init();
  if (ret != 0) { fprintf(stderr, "Backend init failed.\n"); return 1; }
  printf("[%s] Backend initialized.\n", role);

  // --- Allocate registered region ---
  // Layout: [data (WRITE_SIZE) | send_flag (8) | recv_flag (8) | padding]
  // Uses hipHostMallocCoherent so GPU sees RDMA writes from remote NIC.
  static constexpr size_t FLAG_OFFSET_SEND = WRITE_SIZE;
  static constexpr size_t FLAG_OFFSET_RECV = WRITE_SIZE + sizeof(uint64_t);
  size_t total_reg_size = WRITE_SIZE + 4096;
  void *reg_buf = nullptr;
  herr = hipHostMalloc(&reg_buf, total_reg_size,
                       hipHostMallocMapped | hipHostMallocCoherent);
  if (herr != hipSuccess) {
    fprintf(stderr, "hipHostMalloc(coherent) failed: %s\n",
            hipGetErrorString(herr));
    return 1;
  }
  memset(reg_buf, 0, total_reg_size);

  uint8_t *data_region = static_cast<uint8_t *>(reg_buf);
  volatile uint64_t *send_flag =
    reinterpret_cast<volatile uint64_t *>(data_region + FLAG_OFFSET_SEND);
  volatile uint64_t *recv_flag =
    reinterpret_cast<volatile uint64_t *>(data_region + FLAG_OFFSET_RECV);

  if (is_client)
    memset(data_region, DATA_PATTERN, WRITE_SIZE);
  else
    memset(data_region, 0, WRITE_SIZE);

  *send_flag = 0;
  *recv_flag = 0;

  ret = backend.register_data_buffer(reg_buf, total_reg_size);
  if (ret != 0) { fprintf(stderr, "register_data_buffer failed.\n"); return 1; }
  printf("[%s] Buffer registered: lkey=0x%x, rkey=0x%x\n",
         role, backend.get_lkey(), backend.get_rkey());

  // --- TCP exchange ---
  int tcp_fd;
  if (is_server) {
    tcp_fd = tcp_server_accept();
  } else {
    tcp_fd = tcp_client_connect(server_host);
  }
  if (tcp_fd < 0) { fprintf(stderr, "TCP setup failed.\n"); return 1; }

  DestInfo local_dest = backend.get_local_dest_info();
  ExchangeMsg local_msg{};
  local_msg.qpn = local_dest.qpn;
  local_msg.rkey = backend.get_rkey();
  local_msg.remote_addr = reinterpret_cast<uint64_t>(reg_buf);
  memcpy(local_msg.gid, local_dest.gid.raw, 16);

  ExchangeMsg remote_msg{};
  ret = exchange_info(tcp_fd, local_msg, &remote_msg);
  if (ret != 0) { fprintf(stderr, "TCP exchange failed.\n"); close(tcp_fd); return 1; }

  printf("[%s] Local  QPN=%u, rkey=0x%x, addr=0x%lx\n", role,
         local_msg.qpn, local_msg.rkey, local_msg.remote_addr);
  printf("[%s] Remote QPN=%u, rkey=0x%x, addr=0x%lx\n", role,
         remote_msg.qpn, remote_msg.rkey, remote_msg.remote_addr);

  // --- Connect QP to peer ---
  DestInfo peer{};
  peer.qpn = remote_msg.qpn;
  peer.psn = 0;
  memcpy(peer.gid.raw, remote_msg.gid, 16);

  ret = backend.connect_to_peer(peer);
  if (ret != 0) { fprintf(stderr, "connect_to_peer failed.\n"); close(tcp_fd); return 1; }
  printf("[%s] QP connected to peer.\n", role);

  // Set remote rkey so RDMA WRITE WQEs use the peer's MR key
  ret = backend.set_remote_rkey(remote_msg.rkey);
  if (ret != 0) { fprintf(stderr, "set_remote_rkey failed.\n"); close(tcp_fd); return 1; }
  printf("[%s] Remote rkey set to 0x%x\n", role, remote_msg.rkey);

  QueuePair *gpu_qp = backend.get_gpu_qp();
  if (!gpu_qp) { fprintf(stderr, "No GPU QP.\n"); close(tcp_fd); return 1; }

  // Sync before test
  tcp_sync(tcp_fd);

  // ============================================================
  // Test 1: RDMA WRITE correctness
  // ============================================================
  printf("\n--- Test 1: RDMA WRITE Correctness ---\n");

  if (is_client) {
    void *remote_data_addr = reinterpret_cast<void *>(remote_msg.remote_addr);

    printf("[CLIENT] RDMA WRITE %u bytes to server...\n", WRITE_SIZE);
    hipLaunchKernelGGL(rdma_write_kernel, dim3(1), dim3(1), 0, 0,
                       gpu_qp, remote_data_addr, data_region, WRITE_SIZE);
    herr = hipDeviceSynchronize();
    if (herr != hipSuccess) {
      fprintf(stderr, "Kernel failed: %s\n", hipGetErrorString(herr));
      close(tcp_fd); return 1;
    }
    printf("[CLIENT] RDMA WRITE complete.\n");
  }

  // Sync: client tells server write is done
  tcp_sync(tcp_fd);

  if (is_server) {
    int errors = 0;
    for (uint32_t i = 0; i < WRITE_SIZE; i++) {
      if (data_region[i] != DATA_PATTERN) {
        if (errors < 5)
          fprintf(stderr, "  MISMATCH at %u: expected 0x%02x, got 0x%02x\n",
                  i, DATA_PATTERN, data_region[i]);
        errors++;
      }
    }
    if (errors == 0) {
      printf("[SERVER] PASSED: All %u bytes received correctly.\n", WRITE_SIZE);
    } else {
      fprintf(stderr, "[SERVER] FAILED: %d/%u bytes wrong.\n", errors, WRITE_SIZE);
      close(tcp_fd); return 1;
    }
  }

  tcp_sync(tcp_fd);

  // ============================================================
  // Test 2: Ping-pong latency
  // ============================================================
  printf("\n--- Test 2: Ping-Pong Latency (%d iters) ---\n", PINGPONG_ITERS);

  *send_flag = 0;
  *recv_flag = 0;

  // Remote recv_flag address: remote's buffer + FLAG_OFFSET_RECV
  void *remote_recv_flag_addr =
    reinterpret_cast<void *>(remote_msg.remote_addr + FLAG_OFFSET_RECV);

  tcp_sync(tcp_fd);

  if (is_client) {
    unsigned long long *d_elapsed = nullptr;
    (void)hipMalloc(&d_elapsed, sizeof(unsigned long long));
    unsigned long long h_elapsed = 0;
    (void)hipMemcpy(d_elapsed, &h_elapsed, sizeof(h_elapsed),
                    hipMemcpyHostToDevice);

    hipLaunchKernelGGL(pingpong_client_kernel, dim3(1), dim3(1), 0, 0,
                       gpu_qp, send_flag, recv_flag,
                       remote_recv_flag_addr, PINGPONG_ITERS, d_elapsed);
    herr = hipDeviceSynchronize();
    if (herr != hipSuccess) {
      fprintf(stderr, "Pingpong client kernel failed: %s\n",
              hipGetErrorString(herr));
      close(tcp_fd);
      return 1;
    }

    (void)hipMemcpy(&h_elapsed, d_elapsed, sizeof(h_elapsed),
                    hipMemcpyDeviceToHost);
    (void)hipFree(d_elapsed);

    int wallClkRate;
    (void)hipDeviceGetAttribute(&wallClkRate,
                                hipDeviceAttributeWallClockRate, 0);
    double freq_khz = static_cast<double>(wallClkRate);
    double total_us = (static_cast<double>(h_elapsed) / freq_khz) * 1000.0;
    double per_iter_us = total_us / PINGPONG_ITERS;

    printf("[CLIENT] %d round-trips in %.1f us = %.2f us/iter\n",
           PINGPONG_ITERS, total_us, per_iter_us);
  } else {
    hipLaunchKernelGGL(pingpong_server_kernel, dim3(1), dim3(1), 0, 0,
                       gpu_qp, send_flag, recv_flag,
                       remote_recv_flag_addr, PINGPONG_ITERS);
    herr = hipDeviceSynchronize();
    if (herr != hipSuccess) {
      fprintf(stderr, "Pingpong server kernel failed: %s\n",
              hipGetErrorString(herr));
      close(tcp_fd);
      return 1;
    }
    printf("[SERVER] Ping-pong complete.\n");
  }

  tcp_sync(tcp_fd);

  // --- Cleanup ---
  close(tcp_fd);
  (void)hipHostFree(reg_buf);
  backend.shutdown();

  printf("\n=== 2-Node RDMA Test [%s] PASSED ===\n", role);
  return 0;
}

#endif // GDA_BNXT
