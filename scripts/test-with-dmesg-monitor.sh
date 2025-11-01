#!/bin/bash
# Script to run axiio-tester while monitoring for GPU errors in dmesg

set -u

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
TESTER="${TESTER:-./bin/axiio-tester}"
TIMEOUT="${TIMEOUT:-30}"
CHECK_ENV="${CHECK_ENV:-1}"

# Function to print colored messages
print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Function to check environment
check_environment() {
    if [ "$CHECK_ENV" = "1" ]; then
        if [ -z "${HSA_FORCE_FINE_GRAIN_PCIE:-}" ]; then
            print_warning "HSA_FORCE_FINE_GRAIN_PCIE is not set"
            print_info "This may cause GPU page faults on Radeon GPUs"
            print_info "Consider running: export HSA_FORCE_FINE_GRAIN_PCIE=1"
            return 1
        else
            print_info "HSA_FORCE_FINE_GRAIN_PCIE=${HSA_FORCE_FINE_GRAIN_PCIE}"
        fi
    fi
    return 0
}

# Function to get the current dmesg line count
get_dmesg_line_count() {
    dmesg | wc -l
}

# Function to check for GPU errors in dmesg
check_gpu_errors() {
    local start_line=$1
    local new_errors=$(dmesg | tail -n +${start_line} | grep -i "amdgpu.*fault\|amdgpu.*error\|page fault" | grep -v "suppressed" || true)
    
    if [ -n "$new_errors" ]; then
        return 1
    fi
    return 0
}

# Function to display GPU errors
display_gpu_errors() {
    local start_line=$1
    print_error "GPU errors detected in dmesg:"
    echo ""
    dmesg | tail -n +${start_line} | grep -i "amdgpu.*fault\|amdgpu.*error\|page fault" | while IFS= read -r line; do
        echo "  $line"
    done
    echo ""
}

# Function to run test with timeout
run_test_with_timeout() {
    local timeout=$1
    shift
    local cmd="$@"
    
    # Run the command in background
    timeout ${timeout}s $cmd &
    local pid=$!
    
    # Wait for completion
    wait $pid 2>/dev/null
    local exit_code=$?
    
    if [ $exit_code -eq 124 ]; then
        print_error "Test timed out after ${timeout} seconds"
        kill -9 $pid 2>/dev/null || true
        return 124
    fi
    
    return $exit_code
}

# Main function
main() {
    local test_args="$@"
    local exit_code=0
    
    print_info "Starting axiio-tester with GPU error monitoring"
    print_info "Test command: $TESTER $test_args"
    print_info "Timeout: ${TIMEOUT}s"
    echo ""
    
    # Check environment
    check_environment
    env_ok=$?
    echo ""
    
    # Check if tester exists
    if [ ! -x "$TESTER" ]; then
        print_error "Tester not found or not executable: $TESTER"
        print_info "Run 'make all' to build the tester"
        exit 1
    fi
    
    # Get initial dmesg state
    local dmesg_start_line=$(get_dmesg_line_count)
    print_info "Recording dmesg baseline (line ${dmesg_start_line})"
    echo ""
    
    # Run the test
    print_info "Running test..."
    echo "----------------------------------------"
    
    if run_test_with_timeout ${TIMEOUT} ${TESTER} ${test_args}; then
        exit_code=0
    else
        exit_code=$?
        if [ $exit_code -ne 124 ]; then
            print_warning "Test exited with code: ${exit_code}"
        fi
    fi
    
    echo "----------------------------------------"
    echo ""
    
    # Check for GPU errors
    print_info "Checking for GPU errors in dmesg..."
    sleep 0.5  # Give kernel time to log any late errors
    
    if check_gpu_errors ${dmesg_start_line}; then
        print_success "No GPU errors detected!"
        
        if [ $exit_code -eq 0 ]; then
            print_success "Test completed successfully"
            return 0
        else
            print_warning "Test failed with exit code: ${exit_code}"
            return ${exit_code}
        fi
    else
        display_gpu_errors ${dmesg_start_line}
        print_error "GPU errors detected during test execution"
        
        # Provide diagnostic information
        echo ""
        print_info "Diagnostic suggestions:"
        echo "  1. Check that HSA_FORCE_FINE_GRAIN_PCIE=1 is set"
        echo "  2. Verify memory allocation uses hipHostMallocCoherent flag"
        echo "  3. Check GPU driver and ROCm version compatibility"
        echo "  4. Try running: sudo dmesg -c  # to clear old errors"
        echo "  5. Check GPU info: rocminfo"
        echo ""
        
        return 2
    fi
}

# Run main function
main "$@"
exit $?

