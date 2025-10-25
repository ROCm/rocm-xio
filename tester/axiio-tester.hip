/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <CLI/CLI.hpp>
#include <thread>
#include <time.h>
#include <hip/hip_runtime.h>

#include "axiio.h"

__global__ void epKernel(unsigned sqeIterations,
                            sqeType *sqeAddr,
                            cqeType *cqeAddr)
{
  testEndpoint(sqeIterations,
               sqeAddr,
               cqeAddr);
}

__global__ void accelKernel(unsigned sqeIterations,
                            sqeType *sqeAddr,
                            cqeType *cqeAddr,
                            unsigned long long int *start_time,
                            unsigned long long int *end_time)
{
  driveTestEndpoint(sqeIterations,
               sqeAddr,
               cqeAddr,
               start_time, end_time);
}

static void accelFunction(unsigned sqeIterations,
  sqeType *sqeAddr, cqeType *cqeAddr,
                          unsigned long long int *start_time,
                          unsigned long long int *end_time) {

  std::cout << "Hello from accelFunction!" << std::endl;
  accelKernel<<<1, 1, 0, 0>>> (sqeIterations, sqeAddr, cqeAddr,
                                start_time, end_time);
  std::cout << "Bye from accelFunction!" << std::endl;
}

static void epFunction(unsigned sqeIterations, sqeType *sqeAddr, cqeType *cqeAddr) {
  std::cout << "Hello from epFunction!" << std::endl;
  epKernel<<<1, 1, 0, 0>>>(sqeIterations, sqeAddr, cqeAddr);
  std::cout << "Bye from epFunction!" << std::endl;
}

static int run(unsigned iters) {

  sqeType *sqEntry;
  cqeType *cqEntry;
  unsigned long long int *start_time, *hstart_time;
  unsigned long long int *end_time, *hend_time;
  unsigned int flags = 0;

  HIP_CHECK(hipHostMalloc(&sqEntry, sizeof(sqeType), flags));
  HIP_CHECK(hipHostMalloc(&cqEntry, sizeof(cqeType), flags));
  // allocate device timers
  HIP_CHECK(hipMalloc(&start_time, iters * sizeof(long long int)));
  HIP_CHECK(hipMalloc(&end_time, iters * sizeof(long long int)));

  std::thread accelThread(accelFunction, iters, sqEntry, cqEntry,
                          start_time, end_time);
  std::thread epThread(epFunction, iters, sqEntry, cqEntry);

  accelThread.join();
  epThread.join();

  //HIP_CHECK(hipDeviceSynchronize());
  hstart_time = (unsigned long long int *)malloc(iters * sizeof(long long int));
  hend_time = (unsigned long long int *)malloc(iters * sizeof(long long int));

  HIP_CHECK(hipMemcpy(hstart_time, start_time, iters * sizeof(long long int), hipMemcpyDeviceToHost));
  HIP_CHECK(hipMemcpy(hend_time, end_time, iters * sizeof(long long int), hipMemcpyDeviceToHost));

  for (unsigned i = 0; i < iters; i++) {
    std::cout << "Iteration " << i << ": Start time: " << hstart_time[i]
              << ", End time: " << hend_time[i] << std::endl;
  }

  free(hstart_time);
  free(hend_time);
  HIP_CHECK(hipFree(start_time));
  HIP_CHECK(hipFree(end_time));
  HIP_CHECK(hipFreeHost(sqEntry));
  HIP_CHECK(hipFreeHost(cqEntry));

  return 0;
}

int main(int argc, char **argv) {

  CLI::App app{"axiio-tester: A test harness for rocm-axiio."};
  argv = app.ensure_utf8(argv);

  std::string endpoint;
  unsigned nIterations;
  app.add_option("-e, --endpoint", endpoint,
                 "The endpoint to be tested.");
  app.add_option("-n, --iterations", nIterations,
                 "Number of iterations to run the test.")
      ->default_val(1000)
      ->check(CLI::PositiveNumber);
  CLI11_PARSE(app, argc, argv);

  run(nIterations);

  return 0;
}
