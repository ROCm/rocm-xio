#!/bin/bash
# Standalone valgrind wrapper script for xio-tester
# This script runs xio-tester under valgrind memcheck for manual testing
# outside the CTest framework

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SUPPRESSIONS_FILE="${PROJECT_ROOT}/scripts/test/valgrind-rocm.supp"
LOG_DIR="${PROJECT_ROOT}/build/valgrind-logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Parse arguments
VALGRIND_OPTS=(
  "--tool=memcheck"
  "--leak-check=full"
  "--show-leak-kinds=all"
  "--track-origins=yes"
  "--error-exitcode=1"
  "--quiet"
)

# Check if valgrind is available
if ! command -v valgrind &> /dev/null; then
  echo -e "${RED}Error: valgrind not found${NC}"
  echo "Install with: sudo apt-get install valgrind"
  exit 1
fi

# Check if suppression file exists
if [ ! -f "${SUPPRESSIONS_FILE}" ]; then
  echo -e "${YELLOW}Warning: Suppression file not found: ${SUPPRESSIONS_FILE}${NC}"
else
  VALGRIND_OPTS+=("--suppressions=${SUPPRESSIONS_FILE}")
fi

# Create log directory
mkdir -p "${LOG_DIR}"

# Check if executable path is provided
if [ $# -lt 1 ]; then
  echo "Usage: $0 <executable> [executable-args...]"
  echo ""
  echo "Example:"
  echo "  $0 ./build/bin/xio-tester nvme-ep --controller /dev/nvme1"
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

# Generate log file name
LOG_FILE="${LOG_DIR}/valgrind_${TIMESTAMP}.log"
SUMMARY_FILE="${LOG_DIR}/valgrind_${TIMESTAMP}_summary.txt"

echo -e "${GREEN}Running valgrind memcheck...${NC}"
echo "  Executable: ${EXECUTABLE}"
echo "  Arguments: ${EXECUTABLE_ARGS[*]}"
echo "  Log file: ${LOG_FILE}"
echo ""

# Set up environment variables if needed
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-/opt/rocm/lib:/opt/rocm/lib64}"
export HSA_FORCE_FINE_GRAIN_PCIE="${HSA_FORCE_FINE_GRAIN_PCIE:-1}"

# Run valgrind
if valgrind "${VALGRIND_OPTS[@]}" \
  --log-file="${LOG_FILE}" \
  "${EXECUTABLE}" "${EXECUTABLE_ARGS[@]}"; then
  EXIT_CODE=0
  echo -e "${GREEN}Valgrind check passed${NC}"
else
  EXIT_CODE=$?
  echo -e "${RED}Valgrind check failed (exit code: ${EXIT_CODE})${NC}"
fi

# Extract summary
echo ""
echo "=== Valgrind Summary ===" > "${SUMMARY_FILE}"
echo "Command: ${EXECUTABLE} ${EXECUTABLE_ARGS[*]}" >> "${SUMMARY_FILE}"
echo "Log file: ${LOG_FILE}" >> "${SUMMARY_FILE}"
echo "" >> "${SUMMARY_FILE}"

# Extract leak summary from log
if grep -q "LEAK SUMMARY" "${LOG_FILE}"; then
  echo "Leak Summary:" >> "${SUMMARY_FILE}"
  grep -A 10 "LEAK SUMMARY" "${LOG_FILE}" >> "${SUMMARY_FILE}"
fi

# Extract error summary
if grep -q "ERROR SUMMARY" "${LOG_FILE}"; then
  echo "" >> "${SUMMARY_FILE}"
  echo "Error Summary:" >> "${SUMMARY_FILE}"
  grep -A 2 "ERROR SUMMARY" "${LOG_FILE}" >> "${SUMMARY_FILE}"
fi

cat "${SUMMARY_FILE}"
echo ""
echo "Full log: ${LOG_FILE}"
echo "Summary: ${SUMMARY_FILE}"

exit ${EXIT_CODE}
