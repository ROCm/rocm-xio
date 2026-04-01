/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef XIO_CLI_OPTIONS_H
#define XIO_CLI_OPTIONS_H

#include <CLI/CLI.hpp>

#include "nvme-ep.h"
#include "rdma-ep.h"
#include "sdma-ep.h"
#include "test-ep.h"

void registerTestEpCliOptions(CLI::App& app, xio::test_ep::TestEpConfig* cfg);

void registerNvmeEpCliOptions(CLI::App& app, xio::nvme_ep::nvmeEpConfig* cfg);

void registerRdmaEpCliOptions(CLI::App& app, rdma_ep::RdmaEpConfig* cfg);

void registerSdmaEpCliOptions(CLI::App& app, sdma_ep::SdmaEpConfig* cfg);

void detectSdmaTestType(CLI::App& app, sdma_ep::SdmaEpConfig* cfg);

#endif // XIO_CLI_OPTIONS_H
