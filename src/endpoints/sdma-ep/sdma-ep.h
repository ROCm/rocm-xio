/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * SDMA Endpoint Umbrella Header
 *
 * This header now serves as a convenience include that
 * re-exports the device API, host runtime, and tester
 * integration layers. Downstream code that previously
 * included sdma-ep.h continues to work unchanged while
 * more focused includes can pull in the individual
 * headers directly.
 */

#pragma once

#include "sdma_device.hpp"
#include "sdma_host.hpp"
#include "sdma_tester.hpp"

