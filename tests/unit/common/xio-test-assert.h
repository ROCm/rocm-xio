/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Shared test assertion macros for rocm-xio unit and system tests. Include
 * this header instead of defining per-file ASSERT_* macros.
 */

#ifndef XIO_TEST_ASSERT_H
#define XIO_TEST_ASSERT_H

#include <cstdio>
#include <cstdlib>
#include <cstring>

#define ASSERT_EQ(a, b)                                                        \
  do {                                                                         \
    if ((a) != (b)) {                                                          \
      printf("ASSERT_EQ failed: %s:%d: "                                       \
             "%s != %s\n",                                                     \
             __FILE__, __LINE__, #a, #b);                                      \
      abort();                                                                 \
    }                                                                          \
  } while (0)

#define ASSERT_NE(a, b)                                                        \
  do {                                                                         \
    if ((a) == (b)) {                                                          \
      printf("ASSERT_NE failed: %s:%d: "                                       \
             "%s == %s\n",                                                     \
             __FILE__, __LINE__, #a, #b);                                      \
      abort();                                                                 \
    }                                                                          \
  } while (0)

#define ASSERT_TRUE(x)                                                         \
  do {                                                                         \
    if (!(x)) {                                                                \
      printf("ASSERT_TRUE failed: %s:%d: "                                     \
             "%s\n",                                                           \
             __FILE__, __LINE__, #x);                                          \
      abort();                                                                 \
    }                                                                          \
  } while (0)

#define ASSERT_STREQ(a, b)                                                     \
  do {                                                                         \
    if (strcmp((a), (b)) != 0) {                                               \
      printf("ASSERT_STREQ failed: %s:%d: "                                    \
             "%s != %s\n",                                                     \
             __FILE__, __LINE__, #a, #b);                                      \
      abort();                                                                 \
    }                                                                          \
  } while (0)

#define ASSERT_GE(a, b)                                                        \
  do {                                                                         \
    if (!((a) >= (b))) {                                                       \
      printf("ASSERT_GE failed: %s:%d: "                                       \
             "%s < %s\n",                                                      \
             __FILE__, __LINE__, #a, #b);                                      \
      abort();                                                                 \
    }                                                                          \
  } while (0)

#define ASSERT_LE(a, b)                                                        \
  do {                                                                         \
    if (!((a) <= (b))) {                                                       \
      printf("ASSERT_LE failed: %s:%d: "                                       \
             "%s > %s\n",                                                      \
             __FILE__, __LINE__, #a, #b);                                      \
      abort();                                                                 \
    }                                                                          \
  } while (0)

#define ASSERT_GT(a, b)                                                        \
  do {                                                                         \
    if (!((a) > (b))) {                                                        \
      printf("ASSERT_GT failed: %s:%d: "                                       \
             "%s <= %s\n",                                                     \
             __FILE__, __LINE__, #a, #b);                                      \
      abort();                                                                 \
    }                                                                          \
  } while (0)

#endif /* XIO_TEST_ASSERT_H */
