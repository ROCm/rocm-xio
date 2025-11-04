# README.md Update Summary

## Overview
Updated README.md with comprehensive documentation for building and running rocm-axiio with GPU against real NVMe SSDs.

**Total Lines**: 862 (added ~450 lines of documentation)

## Major Additions

### 1. Quick Reference Section (NEW)
- 3-step build and run guide
- Key command line arguments table
- Common use cases at a glance

### 2. Table of Contents (NEW)
- Complete navigation structure
- Links to all major sections

### 3. Enhanced Prerequisites
- **ROCm Installation Guide** (NEW)
  - Repository setup commands
  - Installation steps for Ubuntu/Debian
  - Verification commands
- System requirements expanded with GPU and NVMe requirements

### 4. Updated Building Section
- Clarified that ALL endpoints are built automatically
- Added build configuration options
- GPU_DIRECT_DOORBELL mode selection
- Parallel build instructions

### 5. Updated Endpoint Selection
- Clarified runtime endpoint selection (not build-time)
- Examples of using different endpoints
- Auto-selection when using --nvme-device

### 6. New Comprehensive Section: "Running with GPU Against Real NVMe SSD" (400+ lines)

#### 6.1 Quick Start
- Simplest command to run with real NVMe

#### 6.2 Three Methods for GPU-NVMe I/O
- **Method 1**: Kernel Module Integration (Recommended)
  - Features, benefits, example commands
- **Method 2**: Direct Device Access (Lightweight)
  - Use case, features, example commands
- **Method 3**: CPU-Only Mode (No GPU Atomics)
  - When to use, features, example commands

#### 6.3 Command Line Arguments Reference
Comprehensive tables for:
- Essential Arguments
- Hardware Control
- I/O Parameters
- Queue Configuration
- Data Buffer Options
- Output Control

#### 6.4 Complete Usage Examples
- Example 1: Basic Functionality Test
- Example 2: Performance Testing with Histogram
- Example 3: Data Integrity Testing
- Example 4: Sequential I/O Benchmark
- Example 5: Testing with Kernel Module (GPU-Direct)

#### 6.5 Identifying Your NVMe Device
- Commands to list NVMe devices
- How to get device information
- Namespace discovery

#### 6.6 Testing Progression (Recommended Order)
- 5-step testing guide from emulated to real hardware
- Progressive complexity for validation

#### 6.7 GPU Doorbell Modes
- GPU-Direct Mode (GPU_DIRECT_DOORBELL=1) explanation
- CPU-Hybrid Mode (GPU_DIRECT_DOORBELL=0) explanation
- Build commands for each mode

#### 6.8 Important Notes
- 5 critical reminders about permissions, environment, etc.

#### 6.9 Troubleshooting GPU-NVMe Issues
- "PCIe atomics not enabled" - Solutions
- "Failed to map doorbell" - Solutions
- "Queue creation failed" - Solutions
- "GPU page faults" - Solutions

#### 6.10 Performance Expectations
- Performance table with IOPS and latency for each mode
- Configuration comparison

## Key Command Examples Added

### Basic Usage
```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 -n 100 --verbose
```

### Kernel Module
```bash
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --use-kernel-module --nvme-queue-id 63
```

### CPU-Only Mode
```bash
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only
```

### Performance Testing
```bash
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 -n 10000 --histogram
```

### Data Integrity
```bash
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --use-data-buffers --test-pattern random
```

## What Users Can Now Do

1. **Quickly get started** with the 3-step Quick Reference
2. **Understand all available options** via comprehensive argument tables
3. **Choose the right method** for their hardware/requirements
4. **Follow working examples** for common use cases
5. **Troubleshoot issues** with specific solutions
6. **Build correctly** with ROCm installation guide
7. **Navigate easily** with table of contents
8. **Benchmark performance** with example commands

## Files Modified
- `/home/stebates/Projects/rocm-axiio/README.md` (862 lines total, ~450 new lines)

## Next Steps for Users

1. Install ROCm following the new guide
2. Build with `make all`
3. Follow the "Testing Progression" to validate setup
4. Use the Quick Reference for daily operations
5. Refer to Troubleshooting section when issues arise

## Documentation Quality
- ✅ Complete command line reference
- ✅ Multiple working examples
- ✅ Troubleshooting guide
- ✅ Performance expectations
- ✅ Build instructions
- ✅ Quick reference for fast access
- ✅ Table of contents for navigation

