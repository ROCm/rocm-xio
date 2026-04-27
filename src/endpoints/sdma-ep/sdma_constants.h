#pragma once

#include <cstdint>

namespace sdma_ep {

// SDMA queue size in bytes (8 MiB)
constexpr uint64_t SDMA_QUEUE_SIZE = 8 * 1024 * 1024;

// SDMA operation codes
constexpr unsigned int SDMA_OP_NOP = 0;

} // namespace sdma_ep
