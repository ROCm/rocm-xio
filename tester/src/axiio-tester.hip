/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <CLI/CLI.hpp>
#include <thread>
#include <hip/hip_runtime.h>

static void accelFunction() {
  std::cout << "Hello from accelFunction!" << std::endl;
}

static void epFunction() {
  std::cout << "Hello from epFunction!" << std::endl;
}

static int run() {

  std::thread accelThread(accelFunction);
  std::thread epThread(epFunction);

  accelThread.join();
  epThread.join();

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
