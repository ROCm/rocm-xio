#!/bin/bash
# AddressSanitizer wrapper script for xio-tester
# This script runs xio-tester with AddressSanitizer enabled
# Note: The executable must be built with ENABLE_ASAN=ON

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${PROJECT_ROOT}/build/asan-logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Check if executable path is provided
if [ $# -lt 1 ]; then
  echo "Usage: $0 <executable> [executable-args...]"
  echo ""
  echo "Example:"
  echo "  $0 ./build/bin/xio-tester nvme-ep --controller /dev/nvme1"
  echo ""
  echo "Note: Executable must be built with:"
  echo "  cmake -DENABLE_ASAN=ON .. && cmake --build ."
  exit 1
fi

EXECUTABLE="$1"
shift
EXECUTABLE_ARGS=("$@")

# Check if executable exists
if [ ! -f "${EXECUTABLE}" ] && [ ! -x "${EXECUTABLE}" ]; then
  echo -e "${RED}Error: Executable not found or not executable: ${EXECUTABLE}${NC}"
  exit 1
fi

# Create log directory
mkdir -p "${LOG_DIR}"

# Generate log file name
LOG_FILE="${LOG_DIR}/asan_${TIMESTAMP}.log"

echo -e "${GREEN}Running with AddressSanitizer...${NC}"
echo "  Executable: ${EXECUTABLE}"
echo "  Arguments: ${EXECUTABLE_ARGS[*]}"
echo "  Log file: ${LOG_FILE}"
echo ""

# Set up ASAN options
export ASAN_OPTIONS="
  detect_leaks=1
  leak_check_at_exit=1
  print_stats=1
  print_summary=1
  abort_on_error=1
  symbolize=1
  check_initialization_order=1
  strict_init_order=1
  detect_stack_use_after_return=1
  detect_invalid_pointer_pairs=1
"

# Set up environment variables if needed
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-/opt/rocm/lib:/opt/rocm/lib64}"
export HSA_FORCE_FINE_GRAIN_PCIE="${HSA_FORCE_FINE_GRAIN_PCIE:-1}"

# Run executable with ASan
if "${EXECUTABLE}" "${EXECUTABLE_ARGS[@]}" 2>&1 | tee "${LOG_FILE}"; then
  EXIT_CODE=0
  echo -e "${GREEN}AddressSanitizer check passed${NC}"
else
  EXIT_CODE=$?
  echo -e "${RED}AddressSanitizer check failed (exit code: ${EXIT_CODE})${NC}"
fi

echo ""
echo "Full log: ${LOG_FILE}"

# Check if there are any ASan errors in the log
if grep -q "ERROR: AddressSanitizer" "${LOG_FILE}"; then
  echo -e "${RED}AddressSanitizer errors detected!${NC}"
  echo "Check the log file for details: ${LOG_FILE}"
  exit 1
fi

exit ${EXIT_CODE}
