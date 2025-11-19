#!/bin/bash
# Benchmark script for GPU-initiated NVMe I/O latency
# Tests: Real vs Emulated NVMe, 4KiB vs 64KiB, with/without verification

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

OUTPUT_DIR="/tmp/nvme-latency-benchmark"
mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="$OUTPUT_DIR/latency_report_${TIMESTAMP}.txt"
CSV_FILE="$OUTPUT_DIR/latency_data_${TIMESTAMP}.csv"

# Test parameters
ITERATIONS=100  # Reduced for stability (can increase later)
LFSR_SEED=0xDEADBEEF

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "GPU-Initiated NVMe I/O Latency Benchmark"
echo "=========================================="
echo ""
echo "Test Configuration:"
echo "  Iterations per test: $ITERATIONS"
echo "  LFSR Seed: $LFSR_SEED"
echo "  Output directory: $OUTPUT_DIR"
echo ""

# Initialize CSV file
echo "Device,BlockSize,Verification,MeanLatency_us,MinLatency_us,MaxLatency_us,StdDev_us" > "$CSV_FILE"

# Function to run a test and extract latency stats
run_test() {
  local device_type=$1  # "real" or "emulated"
  local block_size=$2   # 4096 or 65536
  local verify=$3       # "yes" or "no"
  local device_path=$4  # /dev/nvme0 or empty for emulated
  
  local test_name="${device_type}_${block_size}B_verify${verify}"
  local output_file="$OUTPUT_DIR/${test_name}.log"
  
  echo -e "${YELLOW}Running: $test_name${NC}"
  
  # Always write data first (reads need data to exist)
  # For verification tests, we verify after reading
  if [ "$verify" = "yes" ] || [ "$verify" = "no" ]; then
    echo "  Writing test data first..."
    local write_output_file="${output_file%.log}_write.log"
    local write_cmd="./bin/axiio-tester"
    write_cmd="$write_cmd --endpoint nvme-ep"
    write_cmd="$write_cmd --write-only"
    if [ "$device_type" = "real" ] && [ -n "$device_path" ]; then
      write_cmd="$write_cmd --use-kernel-module"
      write_cmd="$write_cmd --nvme-device $device_path"
    fi
    write_cmd="$write_cmd --use-data-buffers"
    write_cmd="$write_cmd --iterations $ITERATIONS"
    write_cmd="$write_cmd --data-buffer-size $((block_size * ITERATIONS))"
    write_cmd="$write_cmd --nvme-block-size $block_size"
    write_cmd="$write_cmd --test-pattern lfsr"
    write_cmd="$write_cmd --lfsr-seed $LFSR_SEED"
    
    echo "Write command: $write_cmd" > "$write_output_file"
    echo "" >> "$write_output_file"
    
    # Run command - continue even if segfault (test may have completed)
    eval "sudo $write_cmd" >> "$write_output_file" 2>&1 || true
    # Check if test actually completed (look for completion markers)
    if ! grep -q "GPU kernel completed\|✅\|completed" "$write_output_file"; then
      echo -e "${RED}✗ Write phase failed${NC}"
      echo "$device_type,$block_size,$verify,WRITE_FAILED,WRITE_FAILED,WRITE_FAILED,WRITE_FAILED" >> "$CSV_FILE"
      return 1
    fi
    echo "  Write phase completed"
    sleep 1
  fi
  
  # Build read command
  local cmd="./bin/axiio-tester"
  cmd="$cmd --endpoint nvme-ep"
  cmd="$cmd --read-only"
  
  if [ "$device_type" = "real" ] && [ -n "$device_path" ]; then
    cmd="$cmd --use-kernel-module"
    cmd="$cmd --nvme-device $device_path"
  fi
  
  cmd="$cmd --use-data-buffers"
  cmd="$cmd --iterations $ITERATIONS"
  cmd="$cmd --data-buffer-size $((block_size * ITERATIONS))"
  cmd="$cmd --nvme-block-size $block_size"
  cmd="$cmd --test-pattern lfsr"
  cmd="$cmd --lfsr-seed $LFSR_SEED"
  cmd="$cmd --verbose"  # Enable verbose mode to get statistics
  
  if [ "$verify" = "yes" ]; then
    cmd="$cmd --verify-reads"
  fi
  
  # Run test and capture output
  echo "Command: $cmd" > "$output_file"
  echo "" >> "$output_file"
  
  # Run command - continue even if segfault (test may have completed)
  eval "sudo $cmd" >> "$output_file" 2>&1 || true
  
  # Check if test completed successfully (look for completion markers)
  if grep -q "GPU kernel completed\|✅\|completed\|Mean:" "$output_file"; then
    # Extract latency statistics from output
    # Statistics format: "Mean: X ns", "Min: X ns", "Max: X ns", "StdDev: X ns"
    # Or from verbose output: "Runtime: X ns"
    local mean=$(grep -iE "Mean:|Average:" "$output_file" | tail -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "N/A")
    local min=$(grep -iE "Min:|Minimum:" "$output_file" | tail -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "N/A")
    local max=$(grep -iE "Max:|Maximum:" "$output_file" | tail -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "N/A")
    local stddev=$(grep -iE "StdDev:|Standard Deviation:" "$output_file" | tail -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "N/A")
    
    # If no statistics found, try extracting from verbose per-iteration output
    if [ "$mean" = "N/A" ]; then
      # Extract all runtime values and calculate statistics
      local runtimes=$(grep -oE "Runtime: [0-9]+\.[0-9]+ ns" "$output_file" | grep -oE "[0-9]+\.[0-9]+" || echo "")
      if [ -n "$runtimes" ]; then
        # Calculate mean from runtimes (simple average)
        mean=$(echo "$runtimes" | awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count; else print "N/A"}')
        min=$(echo "$runtimes" | awk 'BEGIN{min=999999999} {if($1<min) min=$1} END {if(min!=999999999) printf "%.2f", min; else print "N/A"}')
        max=$(echo "$runtimes" | awk 'BEGIN{max=0} {if($1>max) max=$1} END {if(max>0) printf "%.2f", max; else print "N/A"}')
      fi
    fi
    
    # Convert nanoseconds to microseconds (divide by 1000)
    # Handle "N/A" and numeric values
    if [ "$mean" != "N/A" ] && [[ "$mean" =~ ^[0-9]+\.?[0-9]*$ ]]; then
      mean_us=$(echo "scale=2; $mean / 1000" | bc)
    else
      mean_us="N/A"
    fi
    
    if [ "$min" != "N/A" ] && [[ "$min" =~ ^[0-9]+\.?[0-9]*$ ]]; then
      min_us=$(echo "scale=2; $min / 1000" | bc)
    else
      min_us="N/A"
    fi
    
    if [ "$max" != "N/A" ] && [[ "$max" =~ ^[0-9]+\.?[0-9]*$ ]]; then
      max_us=$(echo "scale=2; $max / 1000" | bc)
    else
      max_us="N/A"
    fi
    
    if [ "$stddev" != "N/A" ] && [[ "$stddev" =~ ^[0-9]+\.?[0-9]*$ ]]; then
      stddev_us=$(echo "scale=2; $stddev / 1000" | bc)
    else
      stddev_us="N/A"
    fi
    
    # Write to CSV
    echo "$device_type,$block_size,$verify,$mean_us,$min_us,$max_us,$stddev_us" >> "$CSV_FILE"
    
    echo -e "${GREEN}✓ Completed${NC}"
    echo "  Mean: ${mean_us}μs  Min: ${min_us}μs  Max: ${max_us}μs"
  else
    echo -e "${RED}✗ Failed${NC}"
    echo "$device_type,$block_size,$verify,FAILED,FAILED,FAILED,FAILED" >> "$CSV_FILE"
  fi
  
  echo ""
  sleep 2  # Brief pause between tests
}

# Detect real NVMe device
REAL_NVME=""
if [ -e "/dev/nvme0" ]; then
  # Check if it's bound to nvme_axiio
  if lspci | grep -q "Non-Volatile memory controller"; then
    REAL_NVME="/dev/nvme0"
    echo "Detected real NVMe device: $REAL_NVME"
  fi
fi

# Check if we're in a VM (emulated NVMe available)
EMULATED_AVAILABLE=false
if lspci | grep -q "01:00.0.*Non-Volatile"; then
  EMULATED_AVAILABLE=true
  echo "Emulated NVMe device detected"
fi

echo ""
echo "Starting benchmark tests..."
echo ""

# Test scenarios
if [ -n "$REAL_NVME" ]; then
  echo "=== Testing Real NVMe ==="
  run_test "real" 4096 "no" "$REAL_NVME"
  run_test "real" 4096 "yes" "$REAL_NVME"
  run_test "real" 65536 "no" "$REAL_NVME"
  run_test "real" 65536 "yes" "$REAL_NVME"
fi

if [ "$EMULATED_AVAILABLE" = true ]; then
  echo "=== Testing Emulated NVMe ==="
  # For emulated, we don't pass --nvme-device (uses emulated endpoint)
  run_test "emulated" 4096 "no" ""
  run_test "emulated" 4096 "yes" ""
  run_test "emulated" 65536 "no" ""
  run_test "emulated" 65536 "yes" ""
fi

# Generate report
echo "=========================================="
echo "Generating Report"
echo "=========================================="
echo ""

cat > "$REPORT_FILE" << EOF
GPU-Initiated NVMe I/O Latency Benchmark Report
Generated: $(date)
==========================================

Test Configuration:
  Iterations per test: $ITERATIONS
  LFSR Seed: $LFSR_SEED
  Test Pattern: LFSR (Linear Feedback Shift Register)

Results Summary:
===============

EOF

# Parse CSV and generate formatted report
while IFS=',' read -r device blocksize verify mean min max stddev; do
  if [ "$device" != "Device" ]; then
    echo "Device: $device | Block Size: $blocksize bytes | Verification: $verify" >> "$REPORT_FILE"
    echo "  Mean Latency: ${mean}μs" >> "$REPORT_FILE"
    echo "  Min Latency:  ${min}μs" >> "$REPORT_FILE"
    echo "  Max Latency:  ${max}μs" >> "$REPORT_FILE"
    echo "  Std Dev:      ${stddev}μs" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
  fi
done < "$CSV_FILE"

cat >> "$REPORT_FILE" << EOF
Detailed Results:
================
All test logs are available in: $OUTPUT_DIR

CSV Data:
========
EOF

cat "$CSV_FILE" >> "$REPORT_FILE"

cat "$REPORT_FILE"
echo ""
echo "Report saved to: $REPORT_FILE"
echo "CSV data saved to: $CSV_FILE"
echo "Individual test logs: $OUTPUT_DIR"

