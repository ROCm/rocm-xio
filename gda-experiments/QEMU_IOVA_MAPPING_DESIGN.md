# QEMU IOVA Mapping for GPU-to-Emulated-NVMe Direct Access

## The Problem

We want a VFIO-passed-through GPU to directly access an **emulated** NVMe device's memory regions:
- **NVMe Submission Queue Entries (SQEs)** - GPU writes commands here
- **NVMe Completion Queue Entries (CQEs)** - GPU reads completions here  
- **NVMe Doorbell Registers** - GPU writes to notify NVMe controller

Currently, this fails because:
1. GPU has its own isolated VFIO IOMMU domain
2. Emulated NVMe memory is in QEMU's address space
3. No IOVA mappings exist to bridge them

## Why This is Easier Than Physical P2P

| Physical P2P (Hard) | GPU-to-Emulated (Easier) |
|---------------------|--------------------------|
| Two separate VFIO domains | GPU in VFIO, NVMe is software |
| Hardware IOMMU restrictions | QEMU controls both sides |
| Device-to-device DMA | Device-to-host-memory DMA |
| Requires vendor support | Pure software solution |

**Key Advantage:** QEMU already knows about both:
- The GPU's VFIO container and IOMMU mappings
- The emulated NVMe's memory regions

We just need to **expose the NVMe memory to the GPU's IOVA space**!

---

## Proposed Solution: NVMe Memory Region Injection

### High-Level Design

```
┌─────────────────────────────────────────────────────────┐
│                        QEMU                             │
│                                                         │
│  ┌─────────────────┐         ┌──────────────────────┐  │
│  │ Emulated NVMe   │         │ VFIO GPU             │  │
│  │                 │         │                      │  │
│  │  SQE Buffer ────┼─────┐   │  GPU Agent           │  │
│  │  CQE Buffer ────┼──┐  │   │                      │  │
│  │  Doorbells  ────┼─┐│  │   │  IOVA Space:         │  │
│  └─────────────────┘ │││  │   │   0x00... Guest RAM  │  │
│                      │││  │   │   0xNN... NVMe SQE  ◄┼──┘
│  ┌─────────────────┐ │││  │   │   0xNN... NVMe CQE  ◄┼───┘
│  │ VFIO Container  │ │││  │   │   0xNN... Doorbell  ◄┼────┘
│  │                 │ │││  │   └──────────────────────┘
│  │ IOMMU Mappings: │ │││  │
│  │   Guest RAM ───►│ │││  │
│  │   NVMe SQE  ───►├─┘││  └── Map via vfio_dma_map()
│  │   NVMe CQE  ───►├──┘│
│  │   Doorbell  ───►├───┘
│  └─────────────────┘
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Key Steps

1. **Allocate NVMe memory as DMA-capable**
   - Use `memory_region_init_ram_device_ptr()` for NVMe queues
   - Get host virtual addresses (HVA) for SQEs, CQEs, doorbells

2. **Choose IOVA addresses for NVMe regions**
   - Reserve IOVA space outside guest RAM range
   - E.g., if guest has 16GB, use IOVAs starting at 0x5_0000_0000

3. **Map NVMe memory into GPU's IOVA space**
   - Use `vfio_dma_map()` to create IOMMU mappings
   - Map NVMe's HVA → GPU's IOVA

4. **Expose IOVA addresses to guest**
   - Add vendor-specific NVMe admin command
   - Guest queries: "What are the IOVA addresses for SQEs/CQEs/doorbells?"
   - Guest programs GPU with these IOVAs

---

## Implementation Approach

### Option 1: QEMU Device Property (Simple)

Add a property to link NVMe and GPU devices:

```bash
qemu-system-x86_64 \
  -device nvme,id=nvme0,p2p-gpu=gpu0 \
  -device vfio-pci,id=gpu0,host=10:00.0
```

**QEMU Changes:**
```c
// hw/block/nvme.c
typedef struct NvmeCtrl {
    // ... existing fields ...
    char *p2p_gpu_id;              // GPU device ID
    VFIOPCIDevice *p2p_gpu;        // Pointer to GPU
    hwaddr sqe_iova;               // IOVA for SQEs
    hwaddr cqe_iova;               // IOVA for CQEs
    hwaddr doorbell_iova;          // IOVA for doorbells
} NvmeCtrl;

// During NVMe realize:
static void nvme_realize(PCIDevice *pci_dev, Error **errp)
{
    NvmeCtrl *n = NVME(pci_dev);
    
    if (n->p2p_gpu_id) {
        // Find GPU device
        n->p2p_gpu = VFIO_PCI_BASE(object_resolve_path(n->p2p_gpu_id));
        
        // Map NVMe memory into GPU's IOVA space
        nvme_setup_p2p_mappings(n);
    }
}

static void nvme_setup_p2p_mappings(NvmeCtrl *n)
{
    VFIOContainer *container = n->p2p_gpu->vbasedev.group->container;
    
    // Choose IOVA addresses (above guest RAM)
    n->sqe_iova = 0x5_0000_0000;  // 20GB
    n->cqe_iova = 0x5_0010_0000;  // 20GB + 1MB
    n->doorbell_iova = 0x5_0020_0000;  // 20GB + 2MB
    
    // Map SQE buffer
    void *sqe_hva = memory_region_get_ram_ptr(n->sqe_region);
    size_t sqe_size = memory_region_size(n->sqe_region);
    vfio_dma_map(container, n->sqe_iova, sqe_size, sqe_hva, false);
    
    // Map CQE buffer
    void *cqe_hva = memory_region_get_ram_ptr(n->cqe_region);
    size_t cqe_size = memory_region_size(n->cqe_region);
    vfio_dma_map(container, n->cqe_iova, cqe_size, cqe_hva, false);
    
    // Map doorbell registers
    void *db_hva = memory_region_get_ram_ptr(n->doorbell_region);
    size_t db_size = memory_region_size(n->doorbell_region);
    vfio_dma_map(container, n->doorbell_iova, db_size, db_hva, false);
}
```

**Expose to Guest via Vendor-Specific Admin Command:**
```c
// New NVMe admin command: Get P2P IOVA Addresses
#define NVME_ADM_CMD_GET_P2P_IOVA 0xC0  // Vendor-specific

static void nvme_admin_get_p2p_iova(NvmeCtrl *n, NvmeRequest *req)
{
    struct {
        uint64_t sqe_iova;
        uint64_t cqe_iova;
        uint64_t doorbell_iova;
        uint32_t sqe_size;
        uint32_t cqe_size;
        uint32_t num_queues;
    } response;
    
    if (!n->p2p_gpu) {
        return nvme_invalid_cmd(req);
    }
    
    response.sqe_iova = n->sqe_iova;
    response.cqe_iova = n->cqe_iova;
    response.doorbell_iova = n->doorbell_iova;
    response.sqe_size = n->sqe_size;
    response.cqe_size = n->cqe_size;
    response.num_queues = n->num_queues;
    
    return nvme_dma_read(n, (uint8_t *)&response, sizeof(response), req);
}
```

---

### Option 2: Automatic IOVA Mapping (Advanced)

QEMU automatically detects GPU + NVMe in same VM and creates mappings.

**Advantages:**
- No user configuration needed
- Works with any VFIO device + emulated device combo

**Disadvantages:**
- More complex logic
- Harder to control/debug

---

## Guest Driver Changes

### 1. Query IOVA Addresses

```c
// Guest NVMe driver
struct nvme_p2p_iova_info {
    uint64_t sqe_iova;
    uint64_t cqe_iova;
    uint64_t doorbell_iova;
    uint32_t sqe_size;
    uint32_t cqe_size;
    uint32_t num_queues;
};

int nvme_get_p2p_iova(struct nvme_dev *dev, struct nvme_p2p_iova_info *info)
{
    struct nvme_command cmd = {
        .common = {
            .opcode = NVME_ADM_CMD_GET_P2P_IOVA,
            .nsid = 0,
        },
    };
    
    return nvme_submit_sync_cmd(dev->admin_q, &cmd, info, sizeof(*info));
}
```

### 2. Program GPU with IOVAs

```c
// GPU kernel (HIP/ROCm)
__global__ void nvme_submit_io_kernel(
    volatile nvme_sqe_t *sqe_iova,     // GPU-accessible via IOVA
    volatile uint32_t *doorbell_iova,  // GPU-accessible via IOVA
    int queue_id)
{
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    
    // Each thread submits one I/O command
    nvme_sqe_t sqe;
    sqe.opcode = NVME_CMD_READ;
    sqe.nsid = 1;
    sqe.slba = tid * 8;  // Read 8 blocks per thread
    sqe.nlb = 7;         // 8 blocks (0-based)
    sqe.prp1 = get_data_buffer_iova(tid);
    
    // Write SQE to queue (via IOVA mapping!)
    sqe_iova[tid] = sqe;
    
    __threadfence_system();  // Ensure write visible to NVMe
    
    // Ring doorbell (via IOVA mapping!)
    if (tid == 0) {
        *doorbell_iova = blockDim.x;  // Submit N commands
    }
}
```

---

## IOVA Address Space Layout

```
Guest's View (GPA):
0x0000_0000_0000  ┌─────────────────────┐
                  │   Guest RAM (16GB)  │
0x0004_0000_0000  ├─────────────────────┤
                  │   (hole)            │
0x0005_0000_0000  │   (reserved)        │  ← NVMe IOVA region starts here
                  └─────────────────────┘

GPU's View (IOVA):
0x0000_0000_0000  ┌─────────────────────┐
                  │   Guest RAM         │  ← Normal DMA
0x0004_0000_0000  ├─────────────────────┤
                  │   (unmapped)        │
0x0005_0000_0000  ├─────────────────────┤  ← NVMe IOVA mappings
                  │   NVMe SQE Buffer   │    (created by QEMU)
0x0005_0010_0000  ├─────────────────────┤
                  │   NVMe CQE Buffer   │
0x0005_0020_0000  ├─────────────────────┤
                  │   NVMe Doorbells    │
0x0005_0030_0000  └─────────────────────┘
```

---

## Detailed Implementation Plan

### Phase 1: Basic Infrastructure

**File: `hw/block/nvme.h`**
```c
typedef struct NvmeP2PMapping {
    bool enabled;
    VFIOPCIDevice *gpu;
    hwaddr sqe_iova;
    hwaddr cqe_iova;
    hwaddr doorbell_iova;
} NvmeP2PMapping;
```

**File: `hw/block/nvme.c`**
```c
// Add property
static Property nvme_props[] = {
    // ... existing properties ...
    DEFINE_PROP_STRING("p2p-gpu", NvmeCtrl, p2p.gpu_id),
    DEFINE_PROP_END_OF_LIST(),
};

// Setup during realize
static void nvme_realize(PCIDevice *pci_dev, Error **errp)
{
    NvmeCtrl *n = NVME(pci_dev);
    
    // ... existing initialization ...
    
    if (n->p2p.gpu_id) {
        if (!nvme_setup_p2p(n, errp)) {
            return;
        }
    }
}
```

### Phase 2: IOVA Mapping Creation

**File: `hw/block/nvme-p2p.c` (new)**
```c
#include "hw/vfio/pci.h"

bool nvme_setup_p2p(NvmeCtrl *n, Error **errp)
{
    DeviceState *dev;
    VFIOPCIDevice *vfio_dev;
    VFIOContainer *container;
    
    // 1. Find GPU device
    dev = object_resolve_path_component(
        object_get_objects_root(), n->p2p.gpu_id);
    if (!dev || !object_dynamic_cast(OBJECT(dev), TYPE_VFIO_PCI_BASE)) {
        error_setg(errp, "P2P GPU device '%s' not found or not VFIO",
                   n->p2p.gpu_id);
        return false;
    }
    
    vfio_dev = VFIO_PCI_BASE(dev);
    n->p2p.gpu = vfio_dev;
    
    // 2. Get VFIO container
    if (!vfio_dev->vbasedev.group || !vfio_dev->vbasedev.group->container) {
        error_setg(errp, "GPU VFIO container not available");
        return false;
    }
    container = vfio_dev->vbasedev.group->container;
    
    // 3. Choose IOVA addresses
    // Start at 64GB to avoid conflicts with guest RAM
    n->p2p.sqe_iova = 0x10_0000_0000ULL;
    n->p2p.cqe_iova = n->p2p.sqe_iova + n->sqe_buffer_size;
    n->p2p.doorbell_iova = n->p2p.cqe_iova + n->cqe_buffer_size;
    
    // 4. Map NVMe memory regions
    if (!nvme_map_region_to_iova(n, container, n->sqe_region,
                                  n->p2p.sqe_iova, errp)) {
        return false;
    }
    
    if (!nvme_map_region_to_iova(n, container, n->cqe_region,
                                  n->p2p.cqe_iova, errp)) {
        goto unmap_sqe;
    }
    
    if (!nvme_map_region_to_iova(n, container, n->doorbell_region,
                                  n->p2p.doorbell_iova, errp)) {
        goto unmap_cqe;
    }
    
    n->p2p.enabled = true;
    return true;
    
unmap_cqe:
    nvme_unmap_region_from_iova(n, container, n->cqe_region, n->p2p.cqe_iova);
unmap_sqe:
    nvme_unmap_region_from_iova(n, container, n->sqe_region, n->p2p.sqe_iova);
    return false;
}

static bool nvme_map_region_to_iova(NvmeCtrl *n, VFIOContainer *container,
                                     MemoryRegion *mr, hwaddr iova,
                                     Error **errp)
{
    void *hva;
    size_t size;
    int ret;
    
    // Get host virtual address
    hva = memory_region_get_ram_ptr(mr);
    size = memory_region_size(mr);
    
    // Create VFIO DMA mapping
    struct vfio_iommu_type1_dma_map map = {
        .argsz = sizeof(map),
        .flags = VFIO_DMA_MAP_FLAG_READ | VFIO_DMA_MAP_FLAG_WRITE,
        .vaddr = (uint64_t)(uintptr_t)hva,
        .iova = iova,
        .size = size,
    };
    
    ret = ioctl(container->fd, VFIO_IOMMU_MAP_DMA, &map);
    if (ret) {
        error_setg_errno(errp, errno, "Failed to map NVMe region to IOVA");
        return false;
    }
    
    return true;
}
```

### Phase 3: Vendor-Specific Admin Command

**File: `hw/block/nvme-admin.c`**
```c
#define NVME_ADM_CMD_GET_P2P_IOVA 0xC0

static uint16_t nvme_admin_cmd(NvmeCtrl *n, NvmeRequest *req)
{
    switch (req->cmd.opcode) {
    // ... existing cases ...
    case NVME_ADM_CMD_GET_P2P_IOVA:
        return nvme_get_p2p_iova(n, req);
    }
}

static uint16_t nvme_get_p2p_iova(NvmeCtrl *n, NvmeRequest *req)
{
    struct {
        uint64_t sqe_iova;
        uint64_t cqe_iova;
        uint64_t doorbell_iova;
        uint32_t sqe_size;
        uint32_t cqe_size;
    } __attribute__((packed)) response;
    
    if (!n->p2p.enabled) {
        return NVME_INVALID_OPCODE | NVME_DNR;
    }
    
    response.sqe_iova = n->p2p.sqe_iova;
    response.cqe_iova = n->p2p.cqe_iova;
    response.doorbell_iova = n->p2p.doorbell_iova;
    response.sqe_size = n->sqe_buffer_size;
    response.cqe_size = n->cqe_buffer_size;
    
    return nvme_dma_read(n, (uint8_t *)&response,
                         sizeof(response), req);
}
```

---

## Testing Plan

### 1. Verify IOVA Mappings Created
```bash
# Check QEMU creates mappings
qemu-system-x86_64 \
  -device nvme,id=nvme0,p2p-gpu=gpu0 \
  -device vfio-pci,id=gpu0,host=10:00.0 \
  -monitor stdio

# In QEMU monitor:
info mtree  # Show memory regions
info iova   # Show IOVA mappings (if we add this)
```

### 2. Guest Queries IOVA Addresses
```c
// Inside VM
struct nvme_p2p_iova_info info;
nvme_get_p2p_iova(nvme_dev, &info);
printf("SQE IOVA: 0x%lx\n", info.sqe_iova);
printf("CQE IOVA: 0x%lx\n", info.cqe_iova);
printf("Doorbell IOVA: 0x%lx\n", info.doorbell_iova);
```

### 3. GPU Writes to NVMe via IOVA
```c
// GPU kernel writes SQE
hipLaunchKernelGGL(test_nvme_write, 1, 1, 0, 0, sqe_iova, test_data);
hipDeviceSynchronize();

// Check if NVMe received it
// (should see I/O command processed)
```

---

## Advantages Over Physical P2P

1. **No Hardware Limitations**
   - Works with any GPU (AMD, NVIDIA, Intel)
   - No PCIe topology restrictions
   - No vendor-specific capabilities needed

2. **Full QEMU Control**
   - Can debug/trace all accesses
   - Can implement custom NVMe behavior
   - Can optimize for specific workloads

3. **Easier Development**
   - Test without physical NVMe
   - Iterate quickly on protocol
   - Prototype features before hardware

4. **Hybrid Approach**
   - Later, can swap emulated NVMe for real one
   - Code/protocol remains same
   - Gradual migration path

---

## Limitations & Considerations

### Performance
- Emulated NVMe slower than real hardware
- QEMU must process every doorbell write
- Good for prototyping, not peak performance

### Memory Synchronization
- GPU writes must be visible to QEMU
- May need cache flush/fence operations
- Test with different coherency modes

### IOVA Conflicts
- Must ensure NVMe IOVAs don't overlap guest RAM
- Need to query guest memory layout
- Could make IOVAs configurable

### Security
- GPU can now access NVMe internal state
- Need validation of GPU-written commands
- Consider read-only vs read-write mappings

---

## Next Steps

1. **Prototype the mapping code**
   - Start with simple fixed IOVA addresses
   - Test with basic GPU memory access

2. **Add vendor command**
   - Implement GET_P2P_IOVA admin command
   - Test from guest OS

3. **Write GPU test kernel**
   - Simple doorbell write test
   - SQE write test
   - Full I/O submission

4. **Optimize and harden**
   - Dynamic IOVA allocation
   - Error handling
   - Security validation

This approach lets us develop and test the GPU-initiated NVMe protocol without needing physical NVMe P2P support!

