# VFIO P2P Testing Plan

## Goal

Test if explicitly mapping the NVMe BAR into the VFIO container's IOMMU address space allows GPU P2P access inside the VM.

## Files Created

1. **`vfio_p2p_setup.c`** - C program to set up VFIO P2P mapping
   - Opens VFIO container
   - Gets both IOMMU groups
   - Maps NVMe BAR for GPU access via `VFIO_IOMMU_MAP_DMA`

2. **`in-vm-vfio-p2p-test.sh`** - Shell script to orchestrate testing
   - Checks VM environment
   - Compiles and runs vfio_p2p_setup
   - Provides next steps

## How It Works

### Current Problem

```
GPU (vfio-pci, group 47) → Tries to access NVMe doorbell
                            ↓
                    AMD-Vi IOMMU checks
                            ↓
                    No mapping for NVMe BAR
                            ↓
                    IO_PAGE_FAULT ❌
```

### After VFIO P2P Setup

```
vfio_p2p_setup runs:
  ├─ Opens VFIO container (shared by GPU and NVMe)
  ├─ Gets NVMe BAR0 via VFIO_DEVICE_GET_REGION_INFO
  ├─ mmaps NVMe BAR0
  └─ Calls VFIO_IOMMU_MAP_DMA to map BAR into IOMMU

Result:
GPU (vfio-pci, group 47) → Tries to access NVMe doorbell
                            ↓
                    AMD-Vi IOMMU checks
                            ↓
                    ✓ Mapping exists!
                            ↓
                    Translates to NVMe BAR
                            ↓
                    Access allowed ✅
```

## Running the Test

### Step 1: Start the VM

From host:
```bash
cd /home/stebates/Projects/rocm-axiio/gda-experiments
./run-gda-test-vm.sh
```

### Step 2: SSH into VM

From host:
```bash
ssh ubuntu@rocm-axiio  # or whatever the VM hostname is
```

### Step 3: Run the P2P setup

Inside VM:
```bash
cd /mnt/hostfs/gda-experiments
sudo ./in-vm-vfio-p2p-test.sh
```

This will:
1. Check environment
2. Compile `vfio_p2p_setup.c`
3. Run it to create IOMMU mapping
4. Report success or failure

### Step 4: Interpret Results

#### Success Case ✅

```
✓ Successfully mapped NVMe BAR for GPU access!

P2P Mapping Details:
  IOVA (what GPU sees): 0xdbe00000
  Size: 16384 bytes
  GPU can access doorbell at: 0xdbe01000

✓ VFIO P2P setup complete!
```

This means the IOMMU mapping was created successfully!

#### Failure Cases ❌

**"VFIO_IOMMU_MAP_DMA: Invalid argument"**
- Platform may not support P2P between these devices
- Or IOMMU groups are incompatible

**"VFIO_IOMMU_MAP_DMA: Operation not permitted"**
- Permission issue (run with sudo)

**"VFIO_IOMMU_MAP_DMA: Device or resource busy"**
- QEMU might have already mapped it
- Could actually be OK!

## The Catch

**Even if the mapping succeeds**, we still have a problem:

The NVMe is bound to `vfio-pci`, not our `nvme_gda` driver!

So we can't use `/dev/nvme_gda0` or our existing test programs.

## Options After Successful Mapping

### Option A: Write VFIO-Based Test (Complex)

Create a new test that uses VFIO APIs directly:

```c
// Open VFIO NVMe device
int nvme_fd = ioctl(group_fd, VFIO_GROUP_GET_DEVICE_FD, "0000:c2:00.0");

// Get BAR0
struct vfio_region_info region = {.index = 0};
ioctl(nvme_fd, VFIO_DEVICE_GET_REGION_INFO, &region);

// mmap it
void *bar = mmap(..., nvme_fd, region.offset);

// Create nvme_gda_queue_userspace manually
// Pass doorbell pointers to GPU
// Run GPU test
```

### Option B: Switch NVMe to nvme_gda Driver (Simpler)

Inside VM:
```bash
# Unbind from vfio-pci
echo 0000:c2:00.0 > /sys/bus/pci/drivers/vfio-pci/unbind

# Load nvme_gda driver
cd /mnt/hostfs/gda-experiments/nvme-gda/nvme_gda_driver
make && sudo insmod nvme_gda.ko

# Bind to nvme_gda
echo "1987 5016" > /sys/bus/pci/drivers/nvme_gda/new_id

# Now we have /dev/nvme_gda0!
```

But this defeats the purpose of testing pure VFIO P2P...

### Option C: Test on Host (RECOMMENDED)

Simplest and most direct:
```bash
# On host (not VM):
# - GPU on amdgpu driver
# - NVMe on nvme_gda driver
# - No VFIO
# - Should just work
```

## What We'll Learn

### If VFIO_IOMMU_MAP_DMA Succeeds

✅ **Platform supports P2P** between these devices
✅ **VFIO can enable P2P** with explicit mapping
✅ **Our approach is correct** for VM environments

### If It Fails

❌ Platform/IOMMU doesn't support this P2P configuration
❌ May need different PCIe topology
❌ May need to test on host instead

## Expected Outcome

**Most likely:** The `VFIO_IOMMU_MAP_DMA` call will **succeed**, proving that:
1. The platform supports P2P
2. VFIO can set it up
3. The missing piece was the explicit mapping

Then we need to decide:
- Write VFIO-based test (complex)
- Or just test on host (simple, recommended)

## Architecture Proof

Even if we don't run a full GPU test after this, **a successful VFIO_IOMMU_MAP_DMA proves**:

1. ✅ AMD hardware supports GPU→NVMe P2P
2. ✅ IOMMU can be configured for P2P
3. ✅ Our understanding is correct
4. ✅ rocSHMEM GDA would use same mechanism
5. ✅ Problem was just VFIO isolation, not fundamental limitation

That's valuable validation even without a full GPU doorbell test!

## Next Commands

```bash
# On host:
cd /home/stebates/Projects/rocm-axiio/gda-experiments

# Start VM
./run-gda-test-vm.sh

# In another terminal, SSH to VM:
ssh ubuntu@rocm-axiio
cd /mnt/hostfs/gda-experiments
sudo ./in-vm-vfio-p2p-test.sh
```

