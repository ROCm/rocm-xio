/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <CLI/CLI.hpp>
#include <thread>
#include <time.h>
#include <hip/hip_runtime.h>

#include "axiio.h"

__global__ void accelKernel(unsigned sqeIterations,
                            sqeType *sqeAddr,
                            cqeType *cqeAddr)
{
  testEndpoint(sqeIterations,
               sqeAddr,
               cqeAddr);
}

static void accelFunction(sqeType *sqeAddr, cqeType *cqeAddr) {

  std::cout << "Hello from accelFunction!" << std::endl;

  accelKernel<<<1, 1, 0, 0>>> (1, sqeAddr, cqeAddr);

  std::cout << "Hello from accelFunction!" << std::endl;
}

static void epFunction(sqeType *sqeAddr, cqeType *cqeAddr) {
  std::cout << "Hello from epFunction!" << std::endl;

}

static int run() {

  sqeType *sqEntry;
  cqeType *cqEntry;
  unsigned int flags = 0;
  HIP_CHECK(hipHostMalloc(&sqEntry, sizeof(sqeType), flags));
  HIP_CHECK(hipHostMalloc(&cqEntry, sizeof(cqeType), flags));

  std::thread accelThread(accelFunction, sqEntry, cqEntry);
  std::thread epThread(epFunction, sqEntry, cqEntry);

  accelThread.join();
  epThread.join();

  HIP_CHECK(hipFreeHost(sqEntry));
  HIP_CHECK(hipFreeHost(cqEntry));

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
