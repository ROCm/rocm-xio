/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <CLI/CLI.hpp>
#include <thread>
#include <time.h>
#include <hip/hip_runtime.h>

#include "axiio.h"

typedef struct {
  unsigned nIterations;
  bool printDeviceInfo;
} cmdLineArgs;

typedef struct {
  unsigned long long int *startTime;
  unsigned long long int *endTime;
} testStats;

typedef struct {
  cmdLineArgs args;
  testStats stats;
} testConfig;

__global__ void emulateEndpointKernel(axiioEndPoint *endPoint,
  unsigned sqeIterations,sqeType *sqeAddr, cqeType *cqeAddr)
{
  endPoint->emulateEndpoint(sqeIterations, sqeAddr, cqeAddr);
}

__global__ void driveEndpointKernel(axiioEndPoint *endPoint,
  unsigned sqeIterations, sqeType *sqeAddr, cqeType *cqeAddr,
  unsigned long long int *startTime, unsigned long long int *endTime)
{
  endPoint->driveEndpoint(sqeIterations, sqeAddr, cqeAddr, startTime,
    endTime);
}

static void driveFunction(axiioEndPoint *endPoint, hipStream_t stream,
  unsigned sqeIterations, sqeType *sqeAddr, cqeType *cqeAddr,
  unsigned long long int *startTime, unsigned long long int *endTime) {

  driveEndpointKernel<<<1, 1, 0, 0>>> (endPoint, sqeIterations, sqeAddr,
    cqeAddr, startTime, endTime);

}

static void emulateFunction(axiioEndPoint *endPoint, hipStream_t stream,
  unsigned sqeIterations, sqeType *sqeAddr, cqeType *cqeAddr) {

  //emulateEndpointKernel<<<1, 1, 0, stream>>>(endPoint, sqeIterations, sqeAddr,
  //  cqeAddr);
  endPoint->emulateEndpoint(sqeIterations, sqeAddr, cqeAddr);

}

static int run(testConfig *config) {

  sqeType *sqEntry;
  cqeType *cqEntry;
  unsigned long long int *d_startTime;
  unsigned long long int *d_endTime;
  unsigned int flags = 0;

  axiioEndPoint endPoint;

  hipStream_t stream1, stream2;
  HIP_CHECK(hipStreamCreate(&stream1));
  HIP_CHECK(hipStreamCreate(&stream2));

  HIP_CHECK(hipHostMalloc(&sqEntry, sizeof(sqeType), flags));
  HIP_CHECK(hipHostMalloc(&cqEntry, sizeof(cqeType), flags));
  // allocate device timers
  HIP_CHECK(hipMalloc(&d_startTime, config->args.nIterations * sizeof(unsigned long long int)));
  HIP_CHECK(hipMalloc(&d_endTime, config->args.nIterations * sizeof(unsigned long long int)));

  std::thread driveThread(driveFunction, &endPoint, stream1, config->args.nIterations,
    sqEntry, cqEntry, d_startTime, d_endTime);
  std::thread emulateThread(emulateFunction, &endPoint, stream2, config->args.nIterations,
    sqEntry, cqEntry);

  driveThread.join();
  emulateThread.join();
  HIP_CHECK(hipDeviceSynchronize());

  HIP_CHECK(hipMemcpy(config->stats.startTime, d_startTime, config->args.nIterations * sizeof(unsigned long long int), hipMemcpyDeviceToHost));
  HIP_CHECK(hipMemcpy(config->stats.endTime, d_endTime, config->args.nIterations * sizeof(unsigned long long int), hipMemcpyDeviceToHost));

  HIP_CHECK(hipFree(d_startTime));
  HIP_CHECK(hipFree(d_endTime));
  HIP_CHECK(hipHostFree(sqEntry));
  HIP_CHECK(hipHostFree(cqEntry));

  return 0;
}

int main(int argc, char **argv) {

  CLI::App app{"axiio-tester: A test harness for rocm-axiio."};
  argv = app.ensure_utf8(argv);

  testConfig config;

  app.add_option("-n, --iterations", config.args.nIterations,
                 "Number of iterations to run the test.")
      ->default_val(128)
      ->check(CLI::PositiveNumber);

  app.add_flag("-i, --info", config.args.printDeviceInfo,
               "Print information about GPUs in the system.")
      ->default_val(false);

  CLI11_PARSE(app, argc, argv);

  /*
  * Get information on all the GPUs in the system and the specific GPU(s)
  * chosen to run tests on.
  */

  if (config.args.printDeviceInfo) {
    axxioPrintDeviceInfo();
  }

  // Allocate host memory for timing arrays
  config.stats.startTime = (unsigned long long int *)malloc(config.args.nIterations * sizeof(unsigned long long int));
  config.stats.endTime = (unsigned long long int *)malloc(config.args.nIterations * sizeof(unsigned long long int));

  run(&config);

  // Get wall clock frequency for nanosecond calculation
  int wallClkRate;
  HIP_CHECK(hipDeviceGetAttribute(&wallClkRate,
    hipDeviceAttributeWallClockRate, 0));

  std::cout << "Results:" << std::endl;
  for (unsigned i = 0; i < config.args.nIterations; i++) {
    unsigned long long int duration = config.stats.endTime[i] - config.stats.startTime[i];
    double duration_ns = (double)duration * 1000000.0 / (double)wallClkRate;
    std::cout << std::dec << "  Iteration " << i <<
    ": Start time: " << config.stats.startTime[i]
              << ", End time: " << config.stats.endTime[i] << ", Duration: "
              << duration << ", Runtime: " << duration_ns << " ns" << std::endl;
  }

  free(config.stats.startTime);
  free(config.stats.endTime);

  return EXIT_SUCCESS;
}
