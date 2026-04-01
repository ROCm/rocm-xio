/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 */

/**
 * @file tcp-exchange.hpp
 * @brief TCP-based RDMA QP information exchange for 2-node tests.
 *
 * Provides a lightweight TCP out-of-band channel for exchanging
 * RDMA queue-pair metadata (QPN, rkey, GID, buffer addresses)
 * between two nodes before GPU-initiated RDMA operations begin.
 *
 * Typical usage:
 *   1. Server calls xio::tcp_server_accept() to wait for a peer.
 *   2. Client calls xio::tcp_client_connect() to reach the server.
 *   3. Both sides call xio::exchange_info() to swap ExchangeMsg.
 *   4. Both sides call xio::tcp_sync() as a barrier before each
 *      test phase.
 */

#ifndef XIO_TCP_EXCHANGE_HPP
#define XIO_TCP_EXCHANGE_HPP

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <unistd.h>

namespace xio {

/** @brief Default TCP port for the QP exchange channel. */
static constexpr uint16_t TCP_EXCHANGE_PORT = 18515;

/**
 * @brief Wire-format message exchanged over TCP between two RDMA peers.
 *
 * Contains the minimal set of fields each side needs from the other
 * to transition a QP through INIT -> RTR -> RTS and perform RDMA
 * WRITE operations to the remote memory region.
 */
struct ExchangeMsg {
  uint32_t qpn;         /**< Queue-pair number.                  */
  uint32_t rkey;        /**< Remote memory-region key.           */
  uint16_t lid;         /**< InfiniBand local identifier.        */
  uint16_t pad;         /**< Padding for natural alignment.      */
  uint64_t remote_addr; /**< Virtual address of the remote MR.   */
  uint8_t gid[16];      /**< GRH global identifier (RoCEv2).     */
} __attribute__((packed));

/**
 * @brief Send exactly @p len bytes over a connected TCP socket.
 *
 * Retries partial writes until all bytes are sent or an error
 * occurs.
 *
 * @param fd  Connected socket file descriptor.
 * @param buf Pointer to the data to send.
 * @param len Number of bytes to send.
 * @return 0 on success, -1 on error.
 */
static inline int tcp_send_all(int fd, const void* buf, size_t len) {
  const uint8_t* p = static_cast<const uint8_t*>(buf);
  while (len > 0) {
    ssize_t n = send(fd, p, len, 0);
    if (n < 0) {
      if (errno == EINTR)
        continue;
      return -1;
    }
    if (n == 0)
      return -1;
    p += n;
    len -= n;
  }
  return 0;
}

/**
 * @brief Receive exactly @p len bytes from a connected TCP socket.
 *
 * Retries partial reads until all bytes are received or an error
 * (including EOF) occurs.
 *
 * @param fd  Connected socket file descriptor.
 * @param buf Destination buffer (must be at least @p len bytes).
 * @param len Number of bytes to receive.
 * @return 0 on success, -1 on error or premature EOF.
 */
static inline int tcp_recv_all(int fd, void* buf, size_t len) {
  uint8_t* p = static_cast<uint8_t*>(buf);
  while (len > 0) {
    ssize_t n = recv(fd, p, len, 0);
    if (n < 0) {
      if (errno == EINTR)
        continue;
      return -1;
    }
    if (n == 0)
      return -1;
    p += n;
    len -= n;
  }
  return 0;
}

/**
 * @brief Listen on @p port and accept a single TCP connection.
 *
 * Binds to INADDR_ANY, listens with a backlog of 1, accepts one
 * connection, then closes the listening socket.
 *
 * @param port TCP port number (default: TCP_EXCHANGE_PORT).
 * @return Connected socket fd on success, -1 on error.
 */
static inline int tcp_server_accept(uint16_t port = TCP_EXCHANGE_PORT) {
  int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
  if (listen_fd < 0) {
    perror("socket");
    return -1;
  }

  int opt = 1;
  setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

  struct sockaddr_in addr {};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = INADDR_ANY;
  addr.sin_port = htons(port);

  if (bind(listen_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
    perror("bind");
    close(listen_fd);
    return -1;
  }
  if (listen(listen_fd, 1) < 0) {
    perror("listen");
    close(listen_fd);
    return -1;
  }

  fprintf(stderr, "TCP: Listening on port %u...\n", port);
  int conn_fd = accept(listen_fd, nullptr, nullptr);
  close(listen_fd);
  if (conn_fd < 0) {
    perror("accept");
    return -1;
  }
  fprintf(stderr, "TCP: Client connected.\n");
  return conn_fd;
}

/**
 * @brief Connect to a remote TCP server.
 *
 * Resolves @p hostname via getaddrinfo(), opens a socket, and
 * connects to @p port.
 *
 * @param hostname DNS name or dotted-decimal IP of the server.
 * @param port     TCP port number (default: TCP_EXCHANGE_PORT).
 * @return Connected socket fd on success, -1 on error.
 */
static inline int tcp_client_connect(const char* hostname,
                                     uint16_t port = TCP_EXCHANGE_PORT) {
  struct addrinfo hints {
  }, *res;
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;

  char port_str[8];
  snprintf(port_str, sizeof(port_str), "%u", port);

  int err = getaddrinfo(hostname, port_str, &hints, &res);
  if (err != 0) {
    fprintf(stderr, "getaddrinfo(%s): %s\n", hostname, gai_strerror(err));
    return -1;
  }

  int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
  if (fd < 0) {
    perror("socket");
    freeaddrinfo(res);
    return -1;
  }

  fprintf(stderr, "TCP: Connecting to %s:%u...\n", hostname, port);
  if (connect(fd, res->ai_addr, res->ai_addrlen) < 0) {
    perror("connect");
    close(fd);
    freeaddrinfo(res);
    return -1;
  }
  freeaddrinfo(res);
  fprintf(stderr, "TCP: Connected.\n");
  return fd;
}

/**
 * @brief Exchange RDMA connection info with the remote peer.
 *
 * Sends @p local and receives into @p remote using the connected
 * TCP socket @p tcp_fd.  Both sides must call this simultaneously.
 *
 * @param tcp_fd File descriptor of the connected TCP socket.
 * @param local  Local ExchangeMsg to send.
 * @param remote Pointer to receive the remote ExchangeMsg.
 * @return 0 on success, -1 on error.
 */
static inline int exchange_info(int tcp_fd, const ExchangeMsg& local,
                                ExchangeMsg* remote) {
  if (tcp_send_all(tcp_fd, &local, sizeof(local)) != 0)
    return -1;
  if (tcp_recv_all(tcp_fd, remote, sizeof(*remote)) != 0)
    return -1;
  return 0;
}

/**
 * @brief Synchronise both sides over TCP (barrier).
 *
 * Each side sends one byte and waits for one byte from the peer.
 * Used to ensure both nodes are ready before starting a test
 * phase.
 *
 * @param tcp_fd File descriptor of the connected TCP socket.
 * @return 0 on success, -1 on error.
 */
static inline int tcp_sync(int tcp_fd) {
  uint8_t byte = 1;
  if (tcp_send_all(tcp_fd, &byte, 1) != 0)
    return -1;
  if (tcp_recv_all(tcp_fd, &byte, 1) != 0)
    return -1;
  return 0;
}

} // namespace xio

#endif // XIO_TCP_EXCHANGE_HPP
