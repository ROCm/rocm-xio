# GDA Experiments - Quick Reference Card

## Project Files at a Glance

```
gda-experiments/
├── commit-gda-work.sh          # ← USE THIS to commit everything
├── VM_TESTING_GUIDE.md         # ← VM testing instructions
├── GDA_DOORBELL_ANALYSIS.md    # Deep technical analysis (46KB)
├── PROJECT_SUMMARY.md          # Complete overview
└── nvme-gda/                   # NVMe GDA implementation
    ├── nvme_gda_driver/       # Kernel module
    ├── lib/                   # Userspace + GPU libs
    ├── tests/                 # Test programs
    └── [Documentation]
```

## One-Command Workflow

### Commit Changes
```bash
cd ~/Projects/rocm-axiio/gda-experiments
./commit-gda-work.sh
```

### Build Everything
```bash
cd nvme-gda/nvme_gda_driver && make
cd .. && mkdir -p build && cd build && cmake .. && make -j4
```

### Test Sequence
```bash
# 1. Load driver (replace PCI address)
sudo insmod nvme_gda_driver/nvme_gda.ko nvme_pci_dev=0000:01:00.0

# 2. Basic test
./build/test_basic_doorbell

# 3. Full I/O test
./build/test_gpu_io /dev/nvme_gda0 1 0x100000

# 4. Cleanup
sudo rmmod nvme_gda
```

## Key Commands

### Driver Management
```bash
# Load
sudo insmod nvme_gda.ko nvme_pci_dev=0000:XX:XX.X

# Check
lsmod | grep nvme_gda
dmesg | tail -20
ls -l /dev/nvme_gda0

# Unload
sudo rmmod nvme_gda
```

### Find Your NVMe
```bash
lspci -nn | grep -i nvme
# Example: 01:00.0 Non-Volatile memory controller [0108]: Samsung ...
# Use: nvme_pci_dev=0000:01:00.0
```

### Debug Issues
```bash
# Kernel logs
dmesg | grep -E "(nvme_gda|error|GDA)"

# Device permissions
sudo chmod 666 /dev/nvme_gda0

# PCIe topology
lspci -tv | grep -E "(GPU|NVMe)"

# GPU status
rocm-smi
```

## Critical Files

### For Understanding
- `GDA_DOORBELL_ANALYSIS.md` - How it works
- `COMPARISON_WITH_MLX5.md` - MLX5 vs NVMe comparison

### For Using
- `nvme-gda/README.md` - Architecture
- `nvme-gda/QUICKSTART.md` - Build & usage
- `VM_TESTING_GUIDE.md` - Testing in VM

### For Code
- `nvme-gda/include/nvme_gda.h` - Public API
- `nvme-gda/lib/nvme_gda_device.hip` - GPU functions
- `nvme-gda/nvme_gda_driver/nvme_gda.c` - Kernel driver

## Test Expectations

### test_basic_doorbell
✓ SUCCESS: GPU successfully rang the doorbell!
```
GPU: Old doorbell value: 0, New value: 1
✓ SUCCESS: GPU successfully rang the doorbell!
```

### test_gpu_io
✓ ALL TESTS PASSED!
```
Write results: 8/8 successful
Read results: 8/8 successful
Verification: 8/8 blocks correct
✓ ALL TESTS PASSED!
```

## Safety First

⚠️ Before testing on real hardware:
```bash
# 1. Identify device
sudo nvme list

# 2. Backup data
# IMPORTANT!

# 3. Use safe LBA range
# Start at 0x100000 or higher

# 4. Test read-only first
# Modify test to skip writes initially
```

## Common Issues

**"No such device"**
→ Check PCI address: `lspci | grep -i nvme`

**"Permission denied"**
→ Fix permissions: `sudo chmod 666 /dev/nvme_gda0`

**Segfault**
→ Check PCIe topology: GPU and NVMe on same switch?

**Driver won't load**
→ Check conflicts: `lsmod | grep nvme`

## Performance Metrics

Expected improvements vs traditional path:
- **Latency**: 5-10x lower (~8-10µs vs ~50-100µs)
- **CPU**: 0% (vs 100% of a core)
- **Bandwidth**: Can saturate NVMe (~7GB/s)

## Integration Ideas

### With Emulated NVMe
```bash
# Enable tracing
echo 1 > /sys/kernel/debug/tracing/events/nvme/enable

# Run GDA test
./test_basic_doorbell

# View GPU doorbell rings in trace!
cat /sys/kernel/debug/tracing/trace
```

### With Existing Projects
```cpp
// In your GPU kernel:
#include "nvme_gda.h"

__global__ void my_kernel(nvme_gda_queue_userspace *queue) {
    // Read from NVMe
    nvme_gda_read(queue, nsid, lba, 1, buffer);
    
    // Process data
    process_data(buffer);
    
    // Write back
    nvme_gda_write(queue, nsid, lba, 1, buffer);
}
```

## Git Workflow

```bash
# 1. Commit GDA work
./commit-gda-work.sh

# 2. Review
git log -1 --stat

# 3. Push
git push origin main

# 4. Test in VM!
```

## Key Insights (from MLX5 analysis)

1. **HSA is the key**: `hsa_amd_memory_lock_to_pool()` makes MMIO GPU-accessible
2. **Wave leaders ring**: One thread per wave rings doorbell
3. **Fences matter**: Memory visibility between GPU and device
4. **PCIe P2P required**: Hardware placement critical

## What's Included

| Component | Lines | Purpose |
|-----------|-------|---------|
| Kernel Driver | 600+ | Expose NVMe to GPU |
| Userspace Lib | 400+ | Queue management |
| GPU Functions | 300+ | Doorbell operations |
| Tests | 400+ | Verification |
| Documentation | 2000+ | Understanding |

## Next Actions

1. ✓ Commit: `./commit-gda-work.sh`
2. ✓ Build: See "Build Everything" above
3. ✓ Test: Follow `VM_TESTING_GUIDE.md`
4. ⧗ Integrate: With your emulated NVMe
5. ⧗ Optimize: Queue sizes, batching
6. ⧗ Extend: Multiple devices

## Resources

- rocSHMEM: `gda-experiments/rocSHMEM/`
- NVMe Spec: Section 3 (Queues)
- ROCm Docs: HSA memory model

---

**TL;DR**: GPU directly rings NVMe doorbells for zero-copy I/O!

Commit: `./commit-gda-work.sh`
Test: See `VM_TESTING_GUIDE.md`


