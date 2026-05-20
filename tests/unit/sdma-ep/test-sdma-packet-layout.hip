/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Unit tests for SDMA packet wire layouts and opcode constants.
 */

#include <cstddef>
#include <cstdio>

#include "sdma_pkt_struct.h"
#include "xio-test-assert.h"

int test_opcode_constants() {
  ASSERT_EQ(SDMA_OP_NOP, 0u);
  ASSERT_EQ(SDMA_OP_COPY, 1u);
  ASSERT_EQ(SDMA_OP_WRITE, 2u);
  ASSERT_EQ(SDMA_OP_FENCE, 5u);
  ASSERT_EQ(SDMA_OP_TRAP, 6u);
  ASSERT_EQ(SDMA_OP_POLL_REGMEM, 8u);
  ASSERT_EQ(SDMA_OP_ATOMIC, 10u);
  ASSERT_EQ(SDMA_OP_CONST_FILL, 11u);
  ASSERT_EQ(SDMA_OP_TIMESTAMP, 13u);
  ASSERT_EQ(SDMA_SUBOP_COPY_LINEAR, 0u);
  ASSERT_EQ(SDMA_SUBOP_COPY_LINEAR_SUB_WINDOW, 36u);
  ASSERT_EQ(SDMA_ATOMIC_ADD64, 47u);
  return 0;
}

int test_packet_sizes() {
  ASSERT_EQ(sizeof(SDMA_PKT_COPY_LINEAR), 7u * sizeof(unsigned int));
  ASSERT_EQ(sizeof(SDMA_PKT_WRITE_UNTILED), 5u * sizeof(unsigned int));
  ASSERT_EQ(sizeof(SDMA_PKT_FENCE), 4u * sizeof(unsigned int));
  ASSERT_EQ(sizeof(SDMA_PKT_CONSTANT_FILL), 5u * sizeof(unsigned int));
  ASSERT_EQ(sizeof(SDMA_PKT_TRAP), 2u * sizeof(unsigned int));
  ASSERT_EQ(sizeof(SDMA_PKT_POLL_REGMEM), 6u * sizeof(unsigned int));
  ASSERT_EQ(sizeof(SDMA_PKT_TIMESTAMP), 3u * sizeof(unsigned int));
  ASSERT_EQ(sizeof(SDMA_PKT_NOP), 2u * sizeof(unsigned int));
  ASSERT_EQ(sizeof(SDMA_PKT_ATOMIC), 8u * sizeof(unsigned int));
  ASSERT_EQ(sizeof(SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY),
            20u * sizeof(unsigned int));
  return 0;
}

int test_copy_linear_dword_offsets() {
  ASSERT_EQ(offsetof(SDMA_PKT_COPY_LINEAR, HEADER_UNION), 0u);
  ASSERT_EQ(offsetof(SDMA_PKT_COPY_LINEAR, COUNT_UNION), 4u);
  ASSERT_EQ(offsetof(SDMA_PKT_COPY_LINEAR, PARAMETER_UNION), 8u);
  ASSERT_EQ(offsetof(SDMA_PKT_COPY_LINEAR, SRC_ADDR_LO_UNION), 12u);
  ASSERT_EQ(offsetof(SDMA_PKT_COPY_LINEAR, SRC_ADDR_HI_UNION), 16u);
  ASSERT_EQ(offsetof(SDMA_PKT_COPY_LINEAR, DST_ADDR_LO_UNION), 20u);
  ASSERT_EQ(offsetof(SDMA_PKT_COPY_LINEAR, DST_ADDR_HI_UNION), 24u);
  return 0;
}

int test_copy_linear_field_access() {
  SDMA_PKT_COPY_LINEAR pkt = {};
  pkt.HEADER_UNION.op = SDMA_OP_COPY;
  pkt.HEADER_UNION.sub_op = SDMA_SUBOP_COPY_LINEAR;
  pkt.COUNT_UNION.count = 4095;
  pkt.SRC_ADDR_LO_UNION.src_addr_31_0 = 0x11223344u;
  pkt.SRC_ADDR_HI_UNION.src_addr_63_32 = 0x55667788u;
  pkt.DST_ADDR_LO_UNION.dst_addr_31_0 = 0x99aabbccu;
  pkt.DST_ADDR_HI_UNION.dst_addr_63_32 = 0xddeeff00u;

  ASSERT_EQ(pkt.HEADER_UNION.op, SDMA_OP_COPY);
  ASSERT_EQ(pkt.HEADER_UNION.sub_op, SDMA_SUBOP_COPY_LINEAR);
  ASSERT_EQ(pkt.COUNT_UNION.count, 4095u);
  ASSERT_EQ(pkt.SRC_ADDR_LO_UNION.src_addr_31_0, 0x11223344u);
  ASSERT_EQ(pkt.SRC_ADDR_HI_UNION.src_addr_63_32, 0x55667788u);
  ASSERT_EQ(pkt.DST_ADDR_LO_UNION.dst_addr_31_0, 0x99aabbccu);
  ASSERT_EQ(pkt.DST_ADDR_HI_UNION.dst_addr_63_32, 0xddeeff00u);
  return 0;
}

int test_atomic_packet_field_access() {
  SDMA_PKT_ATOMIC pkt = {};
  pkt.HEADER_UNION.op = SDMA_OP_ATOMIC;
  pkt.HEADER_UNION.operation = SDMA_ATOMIC_ADD64;
  pkt.ADDR_LO_UNION.addr_31_0 = 0x11111111u;
  pkt.ADDR_HI_UNION.addr_63_32 = 0x22222222u;
  pkt.SRC_DATA_LO_UNION.src_data_31_0 = 1u;
  pkt.SRC_DATA_HI_UNION.src_data_63_32 = 0u;

  ASSERT_EQ(pkt.HEADER_UNION.op, SDMA_OP_ATOMIC);
  ASSERT_EQ(pkt.HEADER_UNION.operation, SDMA_ATOMIC_ADD64);
  ASSERT_EQ(pkt.ADDR_LO_UNION.addr_31_0, 0x11111111u);
  ASSERT_EQ(pkt.ADDR_HI_UNION.addr_63_32, 0x22222222u);
  ASSERT_EQ(pkt.SRC_DATA_LO_UNION.src_data_31_0, 1u);
  ASSERT_EQ(pkt.SRC_DATA_HI_UNION.src_data_63_32, 0u);
  return 0;
}

int test_sub_window_copy_layout() {
  ASSERT_EQ(offsetof(SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY, HEADER_UNION), 0u);
  ASSERT_EQ(offsetof(SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY, SRC_X_UNION), 12u);
  ASSERT_EQ(offsetof(SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY, DST_ADDR_LO_UNION),
            36u);
  ASSERT_EQ(offsetof(SDMA_PKT_LINEAR_LARGE_SUB_WINDOW_COPY, RECT_Z_UNION), 76u);
  return 0;
}

int main() {
  int failures = 0;
  failures += test_opcode_constants();
  failures += test_packet_sizes();
  failures += test_copy_linear_dword_offsets();
  failures += test_copy_linear_field_access();
  failures += test_atomic_packet_field_access();
  failures += test_sub_window_copy_layout();

  if (failures == 0) {
    printf("All sdma packet layout tests passed.\n");
    return 0;
  }
  printf("%d sdma packet layout test(s) failed.\n", failures);
  return 1;
}
