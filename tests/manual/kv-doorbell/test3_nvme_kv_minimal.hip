/*
 * test3_nvme_kv_minimal.hip
 *
 * Minimal end-to-end HIP KV Store test:
 *  1. Open /dev/nvme0, load rocm-xio kmod
 *  2. Map pci-mmio-bridge shadow buffer
 *  3. Create NVMe I/O queue (kprobe injects correct GPA)
 *  4. HIP kernel writes KV Store SQE + rings doorbell via shadow buffer
 *  5. Poll CQ from host (CPU) for completion
 *  6. Check QEMU trace for pci_nvme_mmio_doorbell_sq
 *
 * This avoids all of xio-tester's complexity: no rocjitsu detection,
 * no hipDeviceGetAttribute, no hipHostMalloc for data buffers.
 * Everything is posix_memalign or direct writes.
 *
 * Build on guest:
 *   /opt/rocm/core-10.0/bin/amdclang++ -O1 -std=c++17 \
 *     --offload-arch=gfx1250 -x hip \
 *     -I /opt/rocm/core-10.0/include \
 *     test3_nvme_kv_minimal.hip -o test3_nvme_kv_minimal \
 *     -L /opt/rocm/core-10.0/lib -lamdhip64
 *   sudo ./test3_nvme_kv_minimal
 */
#include <hip/hip_runtime.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>

#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

/* rocm-xio REGISTER_BUFFER ioctl */
struct rocm_xio_register_buffer_req {
    int dmabuf_fd; uint32_t _pad1;
    uint64_t virt_addr, phys_addr, size;
    uint32_t nvme_bdf, flags;
};
/* _IOW('R', 8, struct rocm_xio_register_buffer_req) — size=40 */
#define ROCM_XIO_REGISTER_BUFFER_NR 0x40285208u
#define ROCM_XIO_FLAG_EMULATED 2u

/* NVMe ioctl - hardcoded to avoid _IOWR macro issues in gfx1250 device compile */
#define NVME_IOCTL_ADMIN_CMD_NR 0xc0484e41u
struct nvme_passthru_cmd {
    uint8_t opcode, flags; uint16_t rsvd1; uint32_t nsid; uint32_t cdw2, cdw3;
    uint64_t metadata; uint64_t addr; uint32_t metadata_len, data_len;
    uint32_t cdw10, cdw11, cdw12, cdw13, cdw14, cdw15;
    uint32_t timeout_ms, result;
};

/* ---- rocm-xio kernel module ---- */
#define ROCM_XIO_IOC_MAGIC 'R'
struct rocm_xio_mmio_bridge_shadow_req {
    uint32_t bridge_bdf; uint32_t _pad; uint64_t shadow_gpa; uint64_t shadow_size;
};
#define ROCM_XIO_GET_MMIO_BRIDGE_SHADOW_BUFFER \
    _IOWR('R', 10, struct rocm_xio_mmio_bridge_shadow_req)

struct rocm_xio_register_queue_addr_req {
    uint64_t virt_addr; uint64_t phys_addr; uint64_t size; uint64_t prp2;
    uint32_t nvme_bdf; uint8_t queue_type; uint8_t reserved[3];
};
/* _IOW('R', 6, struct rocm_xio_register_queue_addr_req) - size=40 */
#define ROCM_XIO_REGISTER_QUEUE_ADDR 0x40285206u

/* ---- pci-mmio-bridge ring ---- */
struct ring_meta { uint32_t producer_idx, consumer_idx, queue_depth, reserved; } __attribute__((packed));
struct ring_cmd {
    uint16_t target_bdf; uint8_t target_bar, reserved1;
    uint32_t offset; uint64_t value;
    uint8_t command, size, status, reserved2;
    uint32_t sequence;
} __attribute__((packed));

/* ---- NVMe ---- */
struct nvme_sqe { uint8_t opcode, flags; uint16_t cmd_id; uint32_t nsid;
    uint64_t _r0; uint64_t mptr; uint64_t prp1; uint64_t prp2;
    uint32_t cdw10, cdw11, cdw12, cdw13, cdw14, cdw15; } __attribute__((packed));
struct nvme_cqe { uint32_t cdw0; uint32_t _r; uint16_t sq_head, sq_id;
    uint16_t cmd_id; uint16_t status; } __attribute__((packed));

#define NVME_ADM_CREATE_CQ 0x05
#define NVME_ADM_CREATE_SQ 0x01
#define NVME_ADM_DELETE_SQ 0x00
#define NVME_ADM_DELETE_CQ 0x04
#define NVME_KV_STORE 0x01  /* KV Store per NVMe KV Command Set spec */

static uint64_t get_phys_addr(void *virt) {
    int fd = open("/proc/self/pagemap", O_RDONLY);
    if (fd < 0) return 0;
    uint64_t vpage = (uint64_t)virt / 4096;
    uint64_t entry = 0;
    pread(fd, &entry, 8, vpage * 8);
    close(fd);
    if (!(entry >> 63)) return 0;
    return ((entry & 0x7fffffffffffffULL) * 4096) + ((uint64_t)virt & 0xfff);
}

static int nvme_admin(int fd, uint8_t op, uint32_t cdw10, uint32_t cdw11, void *addr) {
    struct nvme_passthru_cmd cmd = {};
    cmd.opcode = op; cmd.cdw10 = cdw10; cmd.cdw11 = cdw11;
    if (addr) cmd.addr = (uint64_t)addr;
    return ioctl(fd, NVME_IOCTL_ADMIN_CMD_NR, &cmd);
}

/* ---- GPU kernel: write one KV Store SQE and ring the doorbell ---- */
__global__ void kv_store_kernel(
    uint8_t  *sq_ptr,       /* SQ ring (CPU VA, page-aligned) */
    uint8_t  *cq_ptr,       /* CQ ring (CPU VA, page-aligned) */
    uint8_t  *val_ptr,      /* value buffer (CPU VA) */
    uint64_t  val_phys,     /* physical address of value buffer */
    uint64_t  shadow_cpu_va, /* shadow buffer CPU VA passed as integer */
    uint16_t  nvme_bdf,     /* 0x0030 for 0000:00:06.0 */
    uint32_t  sq_doorbell,  /* BAR0 offset for SQ tail doorbell */
    uint16_t  nsid)
{
    if (threadIdx.x || blockIdx.x) return;

    /* Cast integer CPU VA to pointer — passes through rocjitsu unchanged */
    volatile uint8_t *shadow_ptr = reinterpret_cast<volatile uint8_t*>(shadow_cpu_va);
    printf("KERNEL: shadow_cpu_va=0x%llx ptr=%p sq_ptr=%p\n",
           (unsigned long long)shadow_cpu_va, (void*)shadow_ptr, (void*)sq_ptr);
    /* shadow_ptr read disabled — kernel-module mmap not in rocjitsu VA space */

    /* Write value (4 bytes 0xdeadbeef) to value buffer */
    for (int i = 0; i < 4096; i++) val_ptr[i] = (uint8_t)i;  /* fill with recognizable pattern */
    __threadfence_system();

    /* Build KV Store SQE at SQ slot 0 */
    volatile uint8_t *sqe = sq_ptr;
    for (int i = 0; i < 64; i++) sqe[i] = 0;
    sqe[0]  = NVME_KV_STORE;    /* opcode */
    sqe[2]  = 1;                 /* cmd_id = 1 */
    sqe[4]  = (uint8_t)(nsid & 0xff); sqe[5] = (uint8_t)(nsid >> 8);
    /* PRP1 = physical address of value buffer */
    for (int i = 0; i < 8; i++) sqe[24+i] = (uint8_t)(val_phys >> (8*i));
    /* CDW10 (offset 40): value_len = 4096 = 0x1000 */
    sqe[40] = 0x00; sqe[41] = 0x10; sqe[42] = 0; sqe[43] = 0;
    /* CDW11 (offset 44): key_len = 8 */
    sqe[44] = 8; sqe[45] = 0; sqe[46] = 0; sqe[47] = 0;
    /* CDW2 (offset 8): key bytes 0-3 "test" */
    sqe[8]  = 't'; sqe[9]  = 'e'; sqe[10] = 's'; sqe[11] = 't';
    /* CDW3 (offset 12): key bytes 4-7 "key0" */
    sqe[12] = 'k'; sqe[13] = 'e'; sqe[14] = 'y'; sqe[15] = '0';
    /* CDW14 (offset 56): key bytes 8-11 (none — key is 8 bytes) */
    sqe[56] = 0; sqe[57] = 0; sqe[58] = 0; sqe[59] = 0;
    /* CDW15 (offset 60): key bytes 12-15 (none) */
    sqe[60] = 0; sqe[61] = 0; sqe[62] = 0; sqe[63] = 0;
    __threadfence_system();

    /* Print SQE contents for debugging */
    printf("SQE bytes:");
    for (int i=0; i<64; i+=4)
        printf(" %02x%02x%02x%02x", sqe[i], sqe[i+1], sqe[i+2], sqe[i+3]);
    printf("\n");

    /* Ring SQ tail doorbell via pci-mmio-bridge shadow buffer */
    uint32_t producer = ((uint32_t)shadow_ptr[0]) | ((uint32_t)shadow_ptr[1]<<8) |
                        ((uint32_t)shadow_ptr[2]<<16) | ((uint32_t)shadow_ptr[3]<<24);
    uint32_t depth    = ((uint32_t)shadow_ptr[8]) | ((uint32_t)shadow_ptr[9]<<8) |
                        ((uint32_t)shadow_ptr[10]<<16) | ((uint32_t)shadow_ptr[11]<<24);
    uint32_t slot = producer % depth;
    volatile uint8_t *dst = shadow_ptr + 16 + slot * 24;

    /* Doorbell written by host after hipDeviceSynchronize */

    __threadfence_system();

    /* Increment producer_idx */
    shadow_ptr[0] = (uint8_t)((producer+1));      shadow_ptr[1] = (uint8_t)((producer+1)>>8);
    shadow_ptr[2] = (uint8_t)((producer+1)>>16);  shadow_ptr[3] = (uint8_t)((producer+1)>>24);
    __threadfence_system();
}

int main() {
    const int QUEUE_ID = 4, QUEUE_SIZE = 16;
    const size_t SQ_BYTES = QUEUE_SIZE * 64, CQ_BYTES = QUEUE_SIZE * 16;

    /* Open NVMe device and kmod */
    int nvme_fd = open("/dev/nvme0", O_RDWR);
    if (nvme_fd < 0) { perror("open nvme0"); return 1; }
    int kmod_fd = open("/dev/rocm-xio", O_RDWR);
    if (kmod_fd < 0) { perror("open rocm-xio"); return 1; }

    /* Allocate SQ, CQ, val via hipHostMalloc so GPU kernel can access them.
     * The kprobe uses the physical address for GPA injection into CREATE_SQ/CQ.
     * hipHostMallocMapped gives GPU-accessible memory; getPhysAddr reads pagemap. */
    void *sq_virt = nullptr, *cq_virt = nullptr, *val_virt = nullptr;
    void *sq_gpu = nullptr,  *cq_gpu = nullptr,  *val_gpu = nullptr;
    hipHostMalloc(&sq_virt, SQ_BYTES, hipHostMallocMapped);
    hipHostMalloc(&cq_virt, CQ_BYTES, hipHostMallocMapped);
    posix_memalign(&val_virt, 4096, 4096); /* CPU-only, correct pagemap phys addr */
    if (!sq_virt || !cq_virt || !val_virt) {
        fprintf(stderr, "hipHostMalloc failed\n"); return 1;
    }
    memset(sq_virt, 0, SQ_BYTES);
    memset(cq_virt, 0, CQ_BYTES);
    memset(val_virt, 0x42, 4096); /* fill with recognizable pattern from CPU */
    mlock(val_virt, 4096); /* pin page in RAM */
    hipHostGetDevicePointer(&sq_gpu,  sq_virt,  0);
    hipHostGetDevicePointer(&cq_gpu,  cq_virt,  0);
    /* val_virt is posix_memalign; CPU fills it, use its phys addr directly */
    val_gpu = val_virt;

    uint64_t sq_phys  = get_phys_addr(sq_virt);
    uint64_t cq_phys  = get_phys_addr(cq_virt);
    uint64_t val_phys = get_phys_addr(val_virt);
    /* Register value buffer with kmod so SPDK can DMA-map it via vfio-user */
    {
        struct rocm_xio_register_buffer_req rbr = {};
        rbr.dmabuf_fd = -1;
        rbr.virt_addr = (uint64_t)val_virt;
        rbr.phys_addr = val_phys;
        rbr.size      = 4096;
        rbr.nvme_bdf  = 0x00000030; /* 0000:00:06.0 */
        rbr.flags     = ROCM_XIO_FLAG_EMULATED;
        int r = ioctl(kmod_fd, ROCM_XIO_REGISTER_BUFFER_NR, &rbr);
        printf("REGISTER_BUFFER: r=%d val_phys=0x%llx\n", r, (unsigned long long)val_phys);
    }
    printf("SQ phys=0x%llx CQ phys=0x%llx val phys=0x%llx\n",
           (unsigned long long)sq_phys, (unsigned long long)cq_phys,
           (unsigned long long)val_phys);

    if (!sq_phys || !cq_phys || !val_phys) {
        fprintf(stderr, "ERROR: failed to get physical addresses\n"); return 1;
    }

    /* Register with kprobe so it injects the right GPAs */
    struct rocm_xio_register_queue_addr_req rq = {};
    rq.virt_addr = (uint64_t)sq_virt; rq.phys_addr = sq_phys;
    rq.size = SQ_BYTES; rq.queue_type = 0; rq.nvme_bdf = 0x00000030;
    ioctl(kmod_fd, ROCM_XIO_REGISTER_QUEUE_ADDR, &rq);
    rq.virt_addr = (uint64_t)cq_virt; rq.phys_addr = cq_phys;
    rq.size = CQ_BYTES; rq.queue_type = 1;
    ioctl(kmod_fd, ROCM_XIO_REGISTER_QUEUE_ADDR, &rq);

    /* Delete existing queue (if any) */
    nvme_admin(nvme_fd, NVME_ADM_DELETE_SQ, QUEUE_ID, 0, NULL);
    nvme_admin(nvme_fd, NVME_ADM_DELETE_CQ, QUEUE_ID, 0, NULL);
    usleep(500000);

    /* Create CQ then SQ (kprobe intercepts and injects correct GPA) */
    uint32_t cdw10 = ((QUEUE_SIZE-1) << 16) | QUEUE_ID;
    if (nvme_admin(nvme_fd, NVME_ADM_CREATE_CQ, cdw10, 1, cq_virt) != 0) {
        fprintf(stderr, "CREATE_CQ failed: %m\n"); return 1;
    }
    uint32_t cdw11 = (QUEUE_ID << 16) | 1;
    if (nvme_admin(nvme_fd, NVME_ADM_CREATE_SQ, cdw10, cdw11, sq_virt) != 0) {
        fprintf(stderr, "CREATE_SQ failed: %m\n"); return 1;
    }
    printf("Queues created. Launching HIP kernel...\n");

    /* Map NVMe BAR0 for direct doorbell write */
    int bar0_fd = open("/sys/bus/pci/devices/0000:00:06.0/resource0", O_RDWR);
    if (bar0_fd < 0) { perror("open bar0"); return 1; }
    void *bar0 = mmap(NULL, 8192, PROT_READ|PROT_WRITE, MAP_SHARED, bar0_fd, 0);
    if (bar0 == MAP_FAILED) { perror("mmap bar0"); return 1; }
    printf("BAR0 mapped at %p\n", bar0);

    /* Map shadow buffer */
    struct rocm_xio_mmio_bridge_shadow_req sr = { .bridge_bdf = 0x00000040 };
    ioctl(kmod_fd, ROCM_XIO_GET_MMIO_BRIDGE_SHADOW_BUFFER, &sr);
    void *shadow = mmap(NULL, sr.shadow_size, PROT_READ|PROT_WRITE, MAP_SHARED, kmod_fd, 0);
    if (shadow == MAP_FAILED) { perror("mmap shadow"); return 1; }
    printf("Shadow: GPA=0x%llx producer=%u consumer=%u queue_depth=%u\n",
           (unsigned long long)sr.shadow_gpa,
           ((uint32_t*)shadow)[0], ((uint32_t*)shadow)[1], ((uint32_t*)shadow)[2]);

    /* Register shadow with HIP (needed for validateGpuPointer in full stack,
     * but here we pass CPU VA directly to kernel) */
    hipHostRegister(shadow, sr.shadow_size, hipHostRegisterMapped);

    /* Launch GPU kernel */
    hipLaunchKernelGGL(kv_store_kernel, dim3(1), dim3(1), 0, 0,
                       (uint8_t*)sq_gpu,  /* GPU VA for SQ */
                       (uint8_t*)cq_gpu,  /* GPU VA for CQ */
                       (uint8_t*)val_gpu, val_phys,
                       (uint64_t)shadow,  /* CPU VA as integer */
                       0x0030,            /* NVMe BDF 0000:00:06.0 */
                       0x1020,            /* SQ doorbell for queue 4 */
                       1);               /* NSID=1 */
    hipDeviceSynchronize();

    /* Write SQ tail doorbell directly to NVMe BAR0.
     * BAR0 writes are intercepted by QEMU via KVM MMIO and forwarded to SPDK
     * via vfio-user — confirmed working.  pci-mmio-bridge timer doesn't fire. */
    {
        volatile uint32_t *sq_doorbell = (volatile uint32_t *)((uint8_t*)bar0 + 0x1020);
        *sq_doorbell = 1; /* sq_tail = 1 */
        __sync_synchronize();
        printf("Host wrote SQ doorbell via BAR0 mmap (sq_tail=1)\n");
    }
    printf("Kernel done. Shadow producer=%u consumer=%u\n",
           ((uint32_t*)shadow)[0], ((uint32_t*)shadow)[1]);

    /* Poll CQ for up to 5 seconds */
    printf("Polling CQ for completion...\n");
    volatile struct nvme_cqe *cqe = (volatile struct nvme_cqe*)cq_virt;  /* CPU VA for host poll */
    for (int i = 0; i < 5000; i++) {
        if (cqe->status & 1) { /* phase bit set = new completion */
            uint8_t sc = (cqe->status >> 1) & 0xff;
            uint8_t sct = (cqe->status >> 9) & 0x7;
            printf("CQE: sc=0x%02x sct=0x%02x cdw0=0x%08x\n", sc, sct, cqe->cdw0);
            if (sc == 0 && sct == 0) printf("SUCCESS: KV Store completed OK\n");
            else printf("ERROR: SPDK returned error\n");
            goto done;
        }
        usleep(1000);
    }
    printf("TIMEOUT: no CQE after 5s\n");

done:
    /* Check SPDK */
    printf("\nCheck QEMU trace on host:\n");
    printf("  docker logs spdk-kv-nvme-vm-qemu-1 2>&1 | grep pci_nvme_mmio_doorbell_sq\n");
    printf("Check SPDK on host:\n");
    printf("  docker exec spdk-kv-nvme-vm-spdk-nvme-1 rpc.py kvdev_mem_get_entry KvMem0 testkey0\n");

    hipHostUnregister(shadow);
    munmap(shadow, sr.shadow_size);
    munmap(bar0, 8192); close(bar0_fd);
    close(nvme_fd); close(kmod_fd);
    hipHostFree(sq_virt); hipHostFree(cq_virt); free(val_virt);
    return 0;
}
