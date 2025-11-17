# VFIO P2P Solutions - Same IOMMU Domain & QEMU Mapping

## Question 1: Would Same IOMMU Domain Work?

**Short Answer: YES, for real devices! With proper VFIO container setup.**

### Real NVMe + GPU in Same Container

Both devices can share a VFIO container and IOMMU address space:

```c
// Open VFIO container
int container = open("/dev/vfio/vfio", O_RDWR);

// Open both IOMMU groups
int group_gpu = open("/dev/vfio/47", O_RDWR);   // GPU
int group_nvme = open("/dev/vfio/11", O_RDWR);  // NVMe

// Add both to same container
ioctl(group_gpu, VFIO_GROUP_SET_CONTAINER, &container);
ioctl(group_nvme, VFIO_GROUP_SET_CONTAINER, &container);

// Get NVMe BAR and map it for GPU access
struct vfio_iommu_type1_dma_map dma_map = {
    .vaddr = (__u64)nvme_bar0_ptr,
    .iova = nvme_bar0_bus_addr,  // Bus address
    .size = 16384,
    .flags = VFIO_DMA_MAP_FLAG_READ | VFIO_DMA_MAP_FLAG_WRITE
};
ioctl(container, VFIO_IOMMU_MAP_DMA, &dma_map);
```

**QEMU already does this!** When you pass through multiple devices, they share a container. The missing piece is **explicitly mapping the NVMe BAR** for GPU P2P access.

## Question 2: Emulated NVMe + GPU P2P?

**Short Answer: NO with standard QEMU. Emulated devices don't have DMA/IOMMU.**

### Why Emulated Devices Don't Work

```
Real NVMe (Passthrough):
├─ Physical PCIe device
├─ Has DMA engine
├─ IOMMU can map its BARs
└─ GPU can access via P2P ✅

Emulated NVMe (QEMU):
├─ Software simulation
├─ No physical DMA
├─ BARs are in guest memory
└─ GPU can't access ❌
```

### Potential Workaround: Shared Memory Region

We could use QEMU's ivshmem (Inter-VM Shared Memory):

```bash
# Create shared memory for doorbell region
qemu-system-x86_64 \
  -machine q35,accel=kvm \
  -device vfio-pci,host=10:00.0 \               # GPU
  -device intel-iommu,intremap=on \              # Virtual IOMMU
  -drive file=nvme.img,if=none,id=nvm \
  -device nvme,drive=nvm \                       # Emulated NVMe
  -object memory-backend-file,id=doorbell_mem,mem-path=/dev/shm/nvme_db,size=4K,share=on \
  -device ivshmem-plain,memdev=doorbell_mem
```

Then:
1. QEMU NVMe emulation uses `/dev/shm/nvme_db` for doorbells
2. Map that shared memory into VFIO container for GPU
3. Both guest CPU and GPU write to same physical memory
4. QEMU polls that memory and triggers NVMe logic

**This requires QEMU patches** to make emulated NVMe use external shared memory for its doorbell page.

## Practical Solutions

### Solution 1: TEST ON HOST (Recommended!)

**Easiest way to validate our code:**

```bash
#!/bin/bash - test_on_host.sh

# On bare metal host (not in VM)

# 1. Unbind GPU from vfio-pci, bind to amdgpu
echo 0000:10:00.0 > /sys/bus/pci/drivers/vfio-pci/unbind
echo 0000:10:00.0 > /sys/bus/pci/drivers/amdgpu/bind

# 2. Load our nvme_gda driver
cd nvme-gda/nvme_gda_driver && make && sudo insmod nvme_gda.ko

# 3. Bind NVMe to nvme_gda
echo 0000:c2:00.0 > /sys/bus/pci/drivers/nvme/unbind
echo "1987 5016" > /sys/bus/pci/drivers/nvme_gda/new_id

# 4. Build and test
cd .. && mkdir -p build && cd build && cmake .. && make
sudo ./tests/test_basic_doorbell /dev/nvme_gda0
```

**This should work immediately!** No VFIO, no VM, just native drivers.

### Solution 2: VFIO P2P with Real NVMe

Create a tool to properly set up VFIO P2P in the VM:

```c
// vfio_p2p_setup.c - Run inside VM before test
#include <stdio.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/vfio.h>

int setup_vfio_p2p(void) {
    // Get the existing container (QEMU creates it)
    int container = open("/dev/vfio/vfio", O_RDWR);
    
    // Open IOMMU groups
    int group_gpu = open("/dev/vfio/47", O_RDWR);
    int group_nvme = open("/dev/vfio/11", O_RDWR);
    
    // They should already be in same container (QEMU does this)
    // But let's verify
    struct vfio_group_status group_status = {.argsz = sizeof(group_status)};
    ioctl(group_gpu, VFIO_GROUP_GET_STATUS, &group_status);
    
    if (!(group_status.flags & VFIO_GROUP_FLAGS_CONTAINER_SET)) {
        printf("Groups not in container!\n");
        return -1;
    }
    
    // Get NVMe device
    int nvme_fd = ioctl(group_nvme, VFIO_GROUP_GET_DEVICE_FD, "0000:c2:00.0");
    
    // Get BAR0 info
    struct vfio_region_info region = {
        .argsz = sizeof(region),
        .index = 0  // BAR0
    };
    ioctl(nvme_fd, VFIO_DEVICE_GET_REGION_INFO, &region);
    
    // mmap the BAR
    void *bar = mmap(NULL, region.size, PROT_READ | PROT_WRITE,
                     MAP_SHARED, nvme_fd, region.offset);
    
    // Now map it into IOMMU for GPU access
    // Use the NVMe's actual bus address
    unsigned long nvme_bus_addr = 0xdbe00000;  // From lspci
    
    struct vfio_iommu_type1_dma_map dma_map = {
        .argsz = sizeof(dma_map),
        .flags = VFIO_DMA_MAP_FLAG_READ | VFIO_DMA_MAP_FLAG_WRITE,
        .vaddr = (__u64)bar,
        .iova = nvme_bus_addr,
        .size = region.size
    };
    
    if (ioctl(container, VFIO_IOMMU_MAP_DMA, &dma_map) < 0) {
        perror("VFIO_IOMMU_MAP_DMA failed");
        return -1;
    }
    
    printf("✓ Mapped NVMe BAR for GPU P2P access!\n");
    printf("  IOVA: 0x%lx, Size: %lld bytes\n", dma_map.iova, dma_map.size);
    
    return 0;
}
```

Run this **before** our GPU test in the VM!

### Solution 3: QEMU Shared Memory (For Emulated NVMe)

**Requires QEMU patch**, but here's the concept:

```bash
# Host: Create shared memory
truncate -s 4K /dev/shm/nvme_doorbells

# Launch QEMU with special config
qemu-system-x86_64 \
  -machine q35,accel=kvm,kernel-irqchip=split \
  -device intel-iommu,intremap=on,device-iotlb=on \
  -device vfio-pci,host=10:00.0 \
  -object memory-backend-file,id=nvme_db,mem-path=/dev/shm/nvme_doorbells,size=4K,share=on \
  -device nvme,drive=nvm,doorbell-memdev=nvme_db \  # <-- REQUIRES PATCH!
  -drive file=nvme.img,if=none,id=nvm
```

Then in guest, map that shared memory for GPU access via VFIO APIs.

## Comparison of Approaches

| Approach | Real NVMe | Emulated NVMe | Difficulty | Validates Code |
|----------|-----------|---------------|------------|----------------|
| **Host Test** | ✅ | N/A | ⭐ Easy | ✅ YES |
| **VFIO P2P Setup** | ✅ | ❌ | ⭐⭐ Medium | ✅ YES |
| **Shared Memory** | N/A | ✅ (patched) | ⭐⭐⭐⭐ Hard | ⚠️ Partial |
| **Current (broken)** | ❌ | ❌ | ⭐ Easy | ❌ NO |

## Recommended Action Plan

### Phase 1: Validate on Host ⭐ **DO THIS FIRST!**

```bash
# Takes 15 minutes
# Proves our implementation is correct
# No VFIO complications
./test_on_host.sh
```

**Expected:** ✅ Works perfectly!

### Phase 2: VFIO P2P with Real NVMe

```bash
# In VM:
# 1. Compile vfio_p2p_setup.c
# 2. Run it to map NVMe BAR for GPU
# 3. Run our test
./vfio_p2p_setup && ./test_basic_doorbell
```

**Expected:** ✅ Works with explicit mapping!

### Phase 3: Document Findings

If Phase 1 works:
- ✅ Our code is correct
- ✅ Matches rocSHMEM pattern  
- ✅ AMD P2P works
- ✅ Just need proper IOMMU setup

If Phase 2 works:
- ✅ VFIO P2P is possible
- ✅ Requires explicit DMA mapping
- ✅ Can work in VMs with proper setup

### Phase 4: Emulated NVMe (Optional)

Only if we really need it:
- Patch QEMU NVMe emulation
- Use shared memory for doorbells
- Research project level effort

## Bottom Line

**Q: Same IOMMU domain would work?**
**A: YES, for real devices!** QEMU already puts them in the same container. We just need to explicitly map the NVMe BAR using VFIO_IOMMU_MAP_DMA.

**Q: GPU to emulated NVMe?**
**A: NO, not with standard QEMU.** Emulated devices don't have DMA/IOMMU. Would require QEMU patches to use shared memory.

**Best path forward:** Test on host first to validate code, then tackle VFIO P2P setup if VM testing is required.
