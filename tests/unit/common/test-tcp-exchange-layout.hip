/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for TCP exchange wire layout and byte helpers.
 */

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include <sys/socket.h>
#include <unistd.h>

#include "tcp-exchange.hpp"
#include "xio-test-assert.h"

int test_exchange_msg_wire_layout() {
  ASSERT_EQ(sizeof(xio::ExchangeMsg), 36u);
  ASSERT_EQ(offsetof(xio::ExchangeMsg, qpn), 0u);
  ASSERT_EQ(offsetof(xio::ExchangeMsg, rkey), 4u);
  ASSERT_EQ(offsetof(xio::ExchangeMsg, lid), 8u);
  ASSERT_EQ(offsetof(xio::ExchangeMsg, pad), 10u);
  ASSERT_EQ(offsetof(xio::ExchangeMsg, remote_addr), 12u);
  ASSERT_EQ(offsetof(xio::ExchangeMsg, gid), 20u);
  ASSERT_EQ(xio::TCP_EXCHANGE_PORT, static_cast<uint16_t>(18515));
  return 0;
}

int test_exchange_msg_field_access() {
  xio::ExchangeMsg msg = {};
  msg.qpn = 0x11223344u;
  msg.rkey = 0xaabbccddu;
  msg.lid = 0x55aau;
  msg.pad = 0;
  msg.remote_addr = 0x0102030405060708ULL;
  for (unsigned i = 0; i < sizeof(msg.gid); i++) {
    msg.gid[i] = static_cast<uint8_t>(i);
  }

  ASSERT_EQ(msg.qpn, 0x11223344u);
  ASSERT_EQ(msg.rkey, 0xaabbccddu);
  ASSERT_EQ(msg.lid, 0x55aau);
  ASSERT_EQ(msg.remote_addr, 0x0102030405060708ULL);
  ASSERT_EQ(msg.gid[15], static_cast<uint8_t>(15));
  return 0;
}

int test_tcp_send_recv_all_socketpair() {
  int fds[2] = {-1, -1};
  ASSERT_EQ(socketpair(AF_UNIX, SOCK_STREAM, 0, fds), 0);

  const uint8_t tx[] = {0, 1, 2, 3, 0xaa, 0xbb, 0xcc, 0xdd};
  uint8_t rx[sizeof(tx)] = {};

  ASSERT_EQ(xio::tcp_send_all(fds[0], tx, sizeof(tx)), 0);
  ASSERT_EQ(xio::tcp_recv_all(fds[1], rx, sizeof(rx)), 0);
  ASSERT_EQ(memcmp(tx, rx, sizeof(tx)), 0);

  close(fds[0]);
  close(fds[1]);
  return 0;
}

int test_tcp_helpers_reject_bad_fd() {
  uint8_t byte = 0;
  ASSERT_EQ(xio::tcp_send_all(-1, &byte, 1), -1);
  ASSERT_EQ(xio::tcp_recv_all(-1, &byte, 1), -1);
  return 0;
}

int main() {
  int failures = 0;
  failures += test_exchange_msg_wire_layout();
  failures += test_exchange_msg_field_access();
  failures += test_tcp_send_recv_all_socketpair();
  failures += test_tcp_helpers_reject_bad_fd();

  if (failures == 0) {
    printf("All tcp-exchange layout tests passed.\n");
    return 0;
  }
  printf("%d tcp-exchange layout test(s) failed.\n", failures);
  return 1;
}
