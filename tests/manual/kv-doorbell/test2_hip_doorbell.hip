/*
 * test2_hip_doorbell.hip
 *
 * HIP kernel test: GPU kernel writes one pci-mmio-bridge doorbell command
 * using byte-by-byte volatile stores into the shadow buffer CPU VA.
 * Confirms whether the gfx1250 GPU kernel (running as CPU on rocjitsu)
 * can write to a CPU-mmap'd region and have QEMU pick it up.
 *
 * Build (on the guest):
 *   /opt/rocm/core-10.0/bin/amdclang++ -O1 -std=c++17 \
 *     --offload-arch=gfx1250 -x hip \
 *     test2_hip_doorbell.hip -o test2_hip_doorbell \
 *     -I /opt/rocm/core-10.0/include \
 *     $(pkg-config --libs hip 2>/dev/null || echo "-L/opt/rocm/core-10.0/lib -lamdhip64")
 *   sudo ./test2_hip_doorbell
 *
 * Expected QEMU trace (docker logs spdk-kv-nvme-vm-qemu-1 2>&1 | grep pci_):
 *   pci_mmio_bridge_poll_processed processed 1 commands
 *   pci_nvme_mmio_doorbell_sq nsid=... new_tail=1
 */
#include <hip/hip_runtime.h>
#include <cstdint>
#include <cstdio>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define ROCM_XIO_IOC_MAGIC 'R'
struct rocm_xio_mmio_bridge_shadow_req {
    uint32_t bridge_bdf; uint32_t _pad; uint64_t shadow_gpa; uint64_t shadow_size;
};
#define ROCM_XIO_GET_MMIO_BRIDGE_SHADOW_BUFFER \
    _IOWR(ROCM_XIO_IOC_MAGIC, 10, struct rocm_xio_mmio_bridge_shadow_req)

struct ring_meta { uint32_t producer_idx, consumer_idx, queue_depth, reserved; } __attribute__((packed));

/* GPU kernel: writes one doorbell command via byte stores to shadow buffer.
 * shadow_cpu_va: CPU mmap VA of the shadow buffer (passed as raw pointer).
 * cmd_slot_offset: byte offset from shadow_cpu_va to the target slot.
 * target_bdf, offset, value: NVMe doorbell parameters.
 */
__global__ void write_doorbell(
    uint8_t* shadow_cpu_va, uint32_t cmd_slot_offset,
    uint16_t target_bdf, uint32_t bar_offset, uint32_t sq_tail)
{
    if (threadIdx.x != 0 || blockIdx.x != 0) return;

    volatile uint8_t* dst = shadow_cpu_va + cmd_slot_offset;
    uint64_t value = sq_tail;

    /* pci_mmio_bridge_command layout (packed, 24 bytes):
     *  0: target_bdf u16   2: target_bar u8   3: reserved1 u8
     *  4: offset u32   8: value u64
     * 16: command u8  17: size u8  18: status u8  19: reserved2 u8
     * 20: sequence u32
     */
    dst[0]  = (uint8_t)(target_bdf & 0xff);
    dst[1]  = (uint8_t)(target_bdf >> 8);
    dst[2]  = 0; /* BAR 0 */
    dst[3]  = 0;
    dst[4]  = (uint8_t)(bar_offset & 0xff);
    dst[5]  = (uint8_t)((bar_offset >> 8)  & 0xff);
    dst[6]  = (uint8_t)((bar_offset >> 16) & 0xff);
    dst[7]  = (uint8_t)((bar_offset >> 24) & 0xff);
    dst[8]  = (uint8_t)(value & 0xff);
    dst[9]  = (uint8_t)((value >> 8)  & 0xff);
    dst[10] = (uint8_t)((value >> 16) & 0xff);
    dst[11] = (uint8_t)((value >> 24) & 0xff);
    dst[12] = (uint8_t)((value >> 32) & 0xff);
    dst[13] = (uint8_t)((value >> 40) & 0xff);
    dst[14] = (uint8_t)((value >> 48) & 0xff);
    dst[15] = (uint8_t)((value >> 56) & 0xff);
    dst[16] = 1; /* CMD_WRITE */
    dst[17] = 4; /* size=4 bytes */
    dst[18] = 1; /* STATUS_PENDING */
    dst[19] = 0;
    dst[20] = 0; /* sequence=0 */
    dst[21] = 0;
    dst[22] = 0;
    dst[23] = 0;
    __threadfence_system();
}

int main() {
    /* Map shadow buffer */
    int fd = open("/dev/rocm-xio", O_RDWR);
    if (fd < 0) { perror("open"); return 1; }

    struct rocm_xio_mmio_bridge_shadow_req req = { .bridge_bdf = 0x00000040 };
    if (ioctl(fd, ROCM_XIO_GET_MMIO_BRIDGE_SHADOW_BUFFER, &req) < 0) {
        perror("ioctl"); return 1;
    }
    void *shadow = mmap(NULL, req.shadow_size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0);
    if (shadow == MAP_FAILED) { perror("mmap"); return 1; }

    struct ring_meta *meta = (struct ring_meta *)shadow;
    printf("Shadow: GPA=0x%llx producer=%u consumer=%u queue_depth=%u\n",
           (unsigned long long)req.shadow_gpa,
           meta->producer_idx, meta->consumer_idx, meta->queue_depth);

    if (meta->queue_depth == 0) { fprintf(stderr, "queue_depth=0\n"); return 1; }

    uint32_t slot = meta->producer_idx % meta->queue_depth;
    uint32_t cmd_offset = 16 /* ring_meta */ + slot * 24 /* ring_cmd */;

    /* Register shadow buffer with HIP so the GPU kernel can access it */
    void *gpu_ptr = nullptr;
    hipHostRegister(shadow, req.shadow_size, hipHostRegisterMapped);
    hipHostGetDevicePointer(&gpu_ptr, shadow, 0);
    printf("shadow CPU VA=%p  GPU VA=%p  (same=%s)\n",
           shadow, gpu_ptr, shadow == gpu_ptr ? "yes" : "no");

    /* On rocjitsu GPU VA != CPU VA; pass the CPU VA directly since the
     * GPU kernel runs as CPU code and can dereference CPU pointers. */
    uint8_t *write_target = (uint8_t *)shadow; /* CPU VA */

    printf("Launching HIP kernel to write doorbell to slot %u...\n", slot);
    hipLaunchKernelGGL(write_doorbell, dim3(1), dim3(1), 0, 0,
                       write_target, cmd_offset,
                       0x0030,   /* NVMe BDF 0000:00:06.0 */
                       0x1020,   /* SQ doorbell for queue 4 */
                       1);       /* sq_tail = 1 */
    hipDeviceSynchronize();

    /* Increment producer so QEMU picks up the command */
    meta->producer_idx = meta->producer_idx + 1;
    __sync_synchronize();
    printf("producer_idx now %u\n", meta->producer_idx);

    sleep(2);
    printf("consumer_idx after 2s: %u\n", meta->consumer_idx);

    /* Read back what the kernel wrote to verify */
    uint8_t *slot_bytes = (uint8_t *)shadow + cmd_offset;
    printf("Slot bytes[16..19] (command,size,status,res): %u %u %u %u\n",
           slot_bytes[16], slot_bytes[17], slot_bytes[18], slot_bytes[19]);
    printf("command=%u (expected 1=CMD_WRITE)\n", slot_bytes[16]);

    hipHostUnregister(shadow);
    munmap(shadow, req.shadow_size);
    close(fd);
    return 0;
}
