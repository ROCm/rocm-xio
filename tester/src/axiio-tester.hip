/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <CLI/CLI.hpp>
#include <thread>
#include <time.h>
#include <hip/hip_runtime.h>

#include "axiio.h"

static void accelFunction(int *sq, int *cq) {
  std::cout << "Hello from accelFunction!" << std::endl;

  time_t current_time;
  int cq_local;

  current_time = time(NULL);
  *sq = (int)current_time;
  while (cq_local != *sq)
    cq_local = *cq;
  std::cout << "Hello from accelFunction!" << std::endl;
}

static void epFunction(int *sq, int *cq) {
  std::cout << "Hello from epFunction!" << std::endl;

  int sq_local = *sq;
  *cq = sq_local;
}

static int run() {

  int *sq, *cq;
  unsigned int flags = 0;
  HIP_CHECK(hipHostMalloc(&sq, sizeof(int), flags));
  HIP_CHECK(hipHostMalloc(&cq, sizeof(int), flags));

  std::thread accelThread(accelFunction, sq, cq);
  std::thread epThread(epFunction, sq, cq);

  accelThread.join();
  epThread.join();

  HIP_CHECK(hipFreeHost(sq));
  HIP_CHECK(hipFreeHost(cq));

  return 0;
}

int main(int argc, char **argv) {

  CLI::App app{"axiio-tester: A test harness for rocm-axiio."};
  argv = app.ensure_utf8(argv);

  std::string endpoint = "none";
  app.add_option("-e,--endpoint", endpoint,
                 "The endpoint to be tested.");
  CLI11_PARSE(app, argc, argv);

  run();

  return 0;
}
