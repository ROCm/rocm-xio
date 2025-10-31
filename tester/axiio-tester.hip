/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <CLI/CLI.hpp>
#include <thread>
#include <time.h>
#include <hip/hip_runtime.h>

#include "axiio.h"

__global__ void emulateEndpointKernel(axiioEndPoint *endPoint,
  unsigned sqeIterations,sqeType *sqeAddr, cqeType *cqeAddr)
{
  endPoint->emulateEndpoint(sqeIterations, sqeAddr, cqeAddr);
}

__global__ void driveEndpointKernel(axiioEndPoint *endPoint,
  unsigned sqeIterations, sqeType *sqeAddr, cqeType *cqeAddr,
  unsigned long long int *start_time, unsigned long long int *end_time)
{
  endPoint->driveEndpoint(sqeIterations, sqeAddr, cqeAddr, start_time,
    end_time);
}

static void driveFunction(axiioEndPoint *endPoint, hipStream_t stream,
  unsigned sqeIterations, sqeType *sqeAddr, cqeType *cqeAddr,
  unsigned long long int *start_time, unsigned long long int *end_time) {

  driveEndpointKernel<<<1, 1, 0, 0>>> (endPoint, sqeIterations, sqeAddr,
    cqeAddr, start_time, end_time);

}

static void emulateFunction(axiioEndPoint *endPoint, hipStream_t stream,
  unsigned sqeIterations, sqeType *sqeAddr, cqeType *cqeAddr) {

  //emulateEndpointKernel<<<1, 1, 0, stream>>>(endPoint, sqeIterations, sqeAddr,
  //  cqeAddr);
  endPoint->emulateEndpoint(sqeIterations, sqeAddr, cqeAddr);

}

static int run(unsigned iters) {

  sqeType *sqEntry;
  cqeType *cqEntry;
  unsigned long long int *start_time, *hstart_time;
  unsigned long long int *end_time, *hend_time;
  unsigned int flags = 0;

  axiioEndPoint endPoint;

  hipStream_t stream1, stream2;
  HIP_CHECK(hipStreamCreate(&stream1));
  HIP_CHECK(hipStreamCreate(&stream2));

  HIP_CHECK(hipHostMalloc(&sqEntry, sizeof(sqeType), flags));
  HIP_CHECK(hipHostMalloc(&cqEntry, sizeof(cqeType), flags));
  // allocate device timers
  HIP_CHECK(hipMalloc(&start_time, iters * sizeof(unsigned long long int)));
  HIP_CHECK(hipMalloc(&end_time, iters * sizeof(unsigned long long int)));

  std::thread driveThread(driveFunction, &endPoint, stream1, iters,
    sqEntry, cqEntry, start_time, end_time);
  std::thread emulateThread(emulateFunction, &endPoint, stream2, iters,
    sqEntry, cqEntry);

  driveThread.join();
  emulateThread.join();
  HIP_CHECK(hipDeviceSynchronize());

  hstart_time = (unsigned long long int *)malloc(iters * sizeof(unsigned long long int));
  hend_time = (unsigned long long int *)malloc(iters * sizeof(unsigned long long int));

  HIP_CHECK(hipMemcpy(hstart_time, start_time, iters * sizeof(unsigned long long int), hipMemcpyDeviceToHost));
  HIP_CHECK(hipMemcpy(hend_time, end_time, iters * sizeof(unsigned long long int), hipMemcpyDeviceToHost));

  for (unsigned i = 0; i < iters; i++) {
    std::cout << std::dec << "Iteration " << i << 
    ": Start time: " << hstart_time[i]
              << ", End time: " << hend_time[i] << ", Duration: " 
              << hend_time[i]-hstart_time[i] << std::endl;
  }

  free(hstart_time);
  free(hend_time);
  HIP_CHECK(hipFree(start_time));
  HIP_CHECK(hipFree(end_time));
  HIP_CHECK(hipHostFree(sqEntry));
  HIP_CHECK(hipHostFree(cqEntry));

  return 0;
}

int main(int argc, char **argv) {

  CLI::App app{"axiio-tester: A test harness for rocm-axiio."};
  argv = app.ensure_utf8(argv);

  unsigned nIterations;
  app.add_option("-n, --iterations", nIterations,
                 "Number of iterations to run the test.")
      ->default_val(128)
      ->check(CLI::PositiveNumber);
  CLI11_PARSE(app, argc, argv);

  /*
  * Get information on all the GPUs in the system and the specific GPU(s) 
  * chosen to run tests on.
  */


  run(nIterations);

  return EXIT_SUCCESS;
}
