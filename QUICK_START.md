# rocm-axiio Quick Start Guide

## Installation (First Time Only)

```bash
# Install ROCm
wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | gpg --dearmor | sudo tee /etc/apt/keyrings/rocm.gpg > /dev/null
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/6.2 jammy main" | sudo tee /etc/apt/sources.list.d/rocm.list
sudo apt update && sudo apt install rocm-hip-sdk rocminfo libcli11-dev

# Set environment variable (add to ~/.bashrc for persistence)
export HSA_FORCE_FINE_GRAIN_PCIE=1
```

## Build

```bash
cd /home/stebates/Projects/rocm-axiio
make clean
make all
```

## Common Commands

### Find Your NVMe Device
```bash
ls -l /dev/nvme*
sudo nvme list
```

### Test with Emulation (No Hardware)
```bash
./bin/axiio-tester -n 100 --verbose
```

### Test with Real NVMe (Automatic Setup)
```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 -n 100 --verbose
```

### CPU-Only Mode (No GPU Atomics Required)
```bash
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 100 --verbose
```

### GPU-Direct with Kernel Module
```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --use-kernel-module -n 100 --verbose
```

### Performance Benchmark
```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 -n 10000 --histogram
```

### Data Integrity Test
```bash
export HSA_FORCE_FINE_GRAIN_PCIE=1
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --use-data-buffers --test-pattern random -n 1000
```

## Essential Arguments

| Argument | Purpose | Example |
|----------|---------|---------|
| `--nvme-device` | NVMe device path | `/dev/nvme0` |
| `-n, --iterations` | Number of I/O ops | `100` |
| `--verbose` | Detailed output | flag |
| `--cpu-only` | CPU mode (no GPU) | flag |
| `--use-kernel-module` | Use kernel module | flag |
| `--transfer-size` | Transfer size (bytes) | `4096` |
| `--access-pattern` | Access pattern | `random` or `sequential` |
| `--histogram` | Show performance | flag |
| `-e` | List endpoints | flag |

## Troubleshooting

### "hipcc not found"
```bash
# Install ROCm
sudo apt install rocm-hip-sdk
which hipcc
```

### "PCIe atomics not enabled"
```bash
# Use CPU-only mode
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only
```

### "GPU page faults"
```bash
# Set environment variable
export HSA_FORCE_FINE_GRAIN_PCIE=1
# Add to ~/.bashrc for persistence
echo 'export HSA_FORCE_FINE_GRAIN_PCIE=1' >> ~/.bashrc
```

### "Permission denied"
```bash
# Run with sudo
sudo ./bin/axiio-tester --nvme-device /dev/nvme0
```

### "Queue creation failed"
```bash
# Try different queue ID
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --nvme-queue-id 50
```

## Testing Progression

```bash
# 1. Emulated test (no hardware)
./bin/axiio-tester -n 10 --verbose

# 2. CPU-only (validates NVMe access)
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 --cpu-only -n 10 --verbose

# 3. GPU test (requires PCIe atomics)
export HSA_FORCE_FINE_GRAIN_PCIE=1
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 -n 100 --verbose

# 4. Performance test
sudo ./bin/axiio-tester --nvme-device /dev/nvme0 -n 10000 --histogram
```

## Performance Expectations

| Mode | IOPS | Latency | Notes |
|------|------|---------|-------|
| GPU-Direct (kernel module) | 1M+ | < 1 μs | Best performance |
| CPU-Hybrid | 500K+ | ~1-2 μs | Good compatibility |
| CPU-Only | 100K+ | ~5-10 μs | No GPU required |

## Additional Resources

- Full Documentation: `README.md`
- Examples in: `docs/NVME_HARDWARE_TESTING.md`
- Testing Scripts: `scripts/`
- Endpoints: `endpoints/*/`

## Quick Checks

```bash
# Verify ROCm installation
which hipcc
rocminfo | grep gfx

# Check GPU
rocminfo | grep -A 5 "Agent 2"

# List NVMe devices
sudo nvme list

# Check environment
echo $HSA_FORCE_FINE_GRAIN_PCIE

# Build status
ls -lh bin/axiio-tester lib/librocm-axiio.a
```

