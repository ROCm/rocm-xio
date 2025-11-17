# VFIO Scenarios Clarified

## The Confusion

I mixed up two different scenarios. Let me clarify:

## Scenario 1: Real NVMe + GPU (Both Passthrough)

### Where VFIO Setup Happens: **HOST**

```
Host (running QEMU):
├─ Opens /dev/vfio/vfio (container)
├─ Adds GPU IOMMU group 47
├─ Adds NVMe IOMMU group 11
├─ Calls VFIO_IOMMU_MAP_DMA for guest RAM
└─ Passes devices to guest

Guest VM:
├─ Sees GPU at 0000:10:00.0
├─ Sees NVMe at 0000:c2:00.0
├─ Uses normal drivers (amdgpu, nvme, nvme_gda, etc.)
└─ Doesn't directly control VFIO container
```

**QEMU on the host sets up the VFIO container, not code running inside the VM!**

### What Needs to Happen

For GPU→NVMe P2P with both devices passed through:

**Option A: QEMU Does It**
- QEMU needs to map NVMe's BAR into the IOMMU
- This would require QEMU patches or configuration
- Currently QEMU only maps guest RAM, not device BARs for P2P

**Option B: Host-side Tool**
- Run a tool ON THE HOST (not in VM)
- That tool opens QEMU's VFIO container
- Adds the P2P mapping
- But finding QEMU's container is tricky...

**Option C: Test on Host (No VM)**
- Both devices use native drivers on host
- No VFIO isolation
- Should just work

## Scenario 2: Emulated NVMe + GPU Passthrough

### Where VFIO Applies: **Only GPU**

```
Host (running QEMU):
├─ GPU: VFIO passthrough (real device)
│   ├─ Opens /dev/vfio/vfio
│   └─ Adds GPU IOMMU group 47
│
└─ NVMe: Emulated by QEMU (not VFIO)
    ├─ Software simulation
    ├─ BAR lives in guest memory
    └─ No IOMMU involvement

Guest VM:
├─ GPU at 0000:10:00.0 (real, via VFIO)
└─ NVMe at 0000:c2:00.0 (emulated, QEMU)
```

**Emulated devices don't use VFIO at all!**

### The Problem

```
GPU (physical) → Tries to access emulated NVMe BAR
                        ↓
                  BAR is in guest memory space
                        ↓
                  GPU can't access guest memory
                        ↓
                  Not a VFIO issue, architectural problem ❌
```

## The Correct Approach for Each Scenario

### For Real NVMe + GPU (Both Passthrough)

#### Method 1: QEMU Configuration (Needs Research)

Check if QEMU has options for P2P:
```bash
qemu-system-x86_64 \
  -device vfio-pci,host=10:00.0 \
  -device vfio-pci,host=c2:00.0 \
  -machine iommu_platform=on \
  # Some P2P flag? (probably doesn't exist)
```

#### Method 2: Host-side VFIO Tool

Create a tool that runs ON THE HOST to modify QEMU's VFIO container:

```c
// Run on HOST, not in VM
// Need to find QEMU's container FD somehow...
// This is complex because QEMU owns the container
```

**Problem:** Hard to inject into QEMU's existing container.

#### Method 3: Custom QEMU Build

Patch QEMU to automatically map device BARs for P2P:

```c
// In QEMU's vfio code
static void vfio_setup_p2p_mappings(VFIOGroup *group) {
    // For each device in container
    // Map its BARs for P2P access
    vfio_dma_map(container, bar_addr, bar_size);
}
```

#### Method 4: Test on Host (EASIEST!)

```bash
# On bare metal host:
# GPU → amdgpu driver
# NVMe → nvme_gda driver
# No VFIO, no VM
# Should work immediately ✅
```

### For Emulated NVMe + GPU

This is fundamentally different - not a VFIO issue:

#### The Real Solution: Shared Memory

```bash
# Host: Create shared memory for doorbell page
dd if=/dev/zero of=/dev/shm/nvme_doorbells bs=4096 count=1

qemu-system-x86_64 \
  -device vfio-pci,host=10:00.0 \
  -object memory-backend-file,id=shmem,mem-path=/dev/shm/nvme_doorbells,size=4K,share=on \
  -device ivshmem-plain,memdev=shmem
```

Then:
1. QEMU NVMe emulation reads from `/dev/shm/nvme_doorbells`
2. Host-side tool maps that into VFIO container for GPU
3. GPU writes to it
4. QEMU polls it and triggers NVMe logic

**Requires QEMU patches** to make emulated NVMe use external shared memory.

## My Error

The `vfio_p2p_setup.c` tool I created would need to run **ON THE HOST**, not in the VM!

And even then, it can't easily access QEMU's VFIO container because QEMU already owns it.

## What Actually Works

### For Testing Our Implementation

**Run on bare metal host** (no VM, no VFIO):

```bash
#!/bin/bash
# On host machine directly

# 1. Load amdgpu for GPU
sudo modprobe amdgpu

# 2. Load nvme_gda driver
cd nvme-gda/nvme_gda_driver
make && sudo insmod nvme_gda.ko

# 3. Bind NVMe to nvme_gda
echo 0000:c2:00.0 > /sys/bus/pci/drivers/nvme/unbind
echo "1987 5016" > /sys/bus/pci/drivers/nvme_gda/new_id

# 4. Test
cd ../build
./tests/test_basic_doorbell /dev/nvme_gda0
```

**This should work!** No VFIO complexity, just native drivers with AMD's P2P support.

### For Testing VFIO P2P (Advanced)

This requires either:
1. **QEMU patches** to set up P2P mappings
2. **Host-side tool** that somehow injects into QEMU's container
3. **Different VFIO setup** (libvirt? different QEMU config?)

All of these are complex research projects.

## Recommendation

**Test on host first!**

This will:
- ✅ Prove our code is correct
- ✅ Show AMD P2P works
- ✅ Validate the whole implementation
- ✅ Be much simpler

Then if VM testing is really needed:
- Research QEMU P2P support
- Or accept that it won't work in current VM setup
- Or contribute QEMU patches

## The Bottom Line

You're right - the VFIO container setup happens **on the host by QEMU**, not inside the VM.

The tool I wrote would need to:
1. Run on the HOST
2. Somehow access QEMU's VFIO container
3. Add P2P mappings

This is much more complex than I suggested.

**Simplest solution: Test on host without VM!**

