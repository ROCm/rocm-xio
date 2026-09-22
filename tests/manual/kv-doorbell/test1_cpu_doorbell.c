/*
 * test1_cpu_doorbell.c
 *
 * Minimal CPU-only test: map the pci-mmio-bridge shadow buffer via
 * the rocm-xio kernel module and write one doorbell command targeting
 * the SPDK NVMe controller's SQ doorbell (BAR0+0x1020 for queue 4).
 *
 * Expected QEMU trace output:
 *   pci_mmio_bridge_poll_processed processed 1 commands
 *   pci_nvme_mmio_doorbell_sq nsid=1 new_tail=1
 *
 * Build (on the guest):
 *   gcc -O0 -o test1_cpu_doorbell test1_cpu_doorbell.c && sudo ./test1_cpu_doorbell
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

/* From rocm-xio-uapi.h */
#define ROCM_XIO_IOC_MAGIC 'R'
struct rocm_xio_mmio_bridge_shadow_req {
    uint32_t bridge_bdf;
    uint32_t _pad;
    uint64_t shadow_gpa;
    uint64_t shadow_size;
};
#define ROCM_XIO_GET_MMIO_BRIDGE_SHADOW_BUFFER \
    _IOWR(ROCM_XIO_IOC_MAGIC, 10, struct rocm_xio_mmio_bridge_shadow_req)

/* pci-mmio-bridge structs */
struct ring_meta {
    uint32_t producer_idx;
    uint32_t consumer_idx;
    uint32_t queue_depth;
    uint32_t reserved;
} __attribute__((packed));

struct ring_cmd {
    uint16_t target_bdf;
    uint8_t  target_bar;
    uint8_t  reserved1;
    uint32_t offset;
    uint64_t value;
    uint8_t  command;   /* 1 = CMD_WRITE */
    uint8_t  size;      /* bytes: 1/2/4/8 */
    uint8_t  status;    /* 1 = PENDING */
    uint8_t  reserved2;
    uint32_t sequence;
} __attribute__((packed));

int main(void) {
    /* Open the rocm-xio kernel module */
    int fd = open("/dev/rocm-xio", O_RDWR);
    if (fd < 0) { perror("open /dev/rocm-xio"); return 1; }

    /* BDF 0x00000040 = 0000:00:08.0 (pci-mmio-bridge) */
    struct rocm_xio_mmio_bridge_shadow_req req = { .bridge_bdf = 0x00000040 };
    if (ioctl(fd, ROCM_XIO_GET_MMIO_BRIDGE_SHADOW_BUFFER, &req) < 0) {
        perror("ioctl GET_MMIO_BRIDGE_SHADOW_BUFFER"); return 1;
    }
    printf("Shadow buffer: GPA=0x%llx size=%llu\n",
           (unsigned long long)req.shadow_gpa,
           (unsigned long long)req.shadow_size);

    void *shadow = mmap(NULL, req.shadow_size,
                        PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (shadow == MAP_FAILED) { perror("mmap"); return 1; }

    struct ring_meta *meta = shadow;
    printf("Ring: producer=%u consumer=%u queue_depth=%u\n",
           meta->producer_idx, meta->consumer_idx, meta->queue_depth);

    if (meta->queue_depth == 0) {
        fprintf(stderr, "ERROR: queue_depth=0, bridge not initialized\n");
        return 1;
    }

    /* Build one CMD_WRITE to NVMe BDF 0x0030 (0000:00:06.0) BAR0
     * offset 0x1020 = SQ doorbell for queue 4, value 1 (sq_tail=1). */
    uint32_t slot = meta->producer_idx % meta->queue_depth;
    struct ring_cmd *cmd_slot = (struct ring_cmd *)(
        (uint8_t *)shadow + sizeof(struct ring_meta) +
        slot * sizeof(struct ring_cmd));

    struct ring_cmd cmd = {
        .target_bdf = 0x0030,    /* 0000:00:06.0 */
        .target_bar = 0,
        .reserved1  = 0,
        .offset     = 0x1020,   /* SQ doorbell for queue 4 */
        .value      = 1,        /* sq_tail = 1 */
        .command    = 1,        /* CMD_WRITE */
        .size       = 4,        /* 32-bit write */
        .status     = 1,        /* STATUS_PENDING */
        .reserved2  = 0,
        .sequence   = slot,
    };
    memcpy((void *)cmd_slot, &cmd, sizeof(cmd));
    __sync_synchronize();

    printf("Wrote doorbell command to slot %u\n", slot);
    printf("  target_bdf=0x%04x bar=%u offset=0x%x value=%llu command=%u\n",
           cmd.target_bdf, cmd.target_bar, cmd.offset,
           (unsigned long long)cmd.value, cmd.command);

    /* Increment producer_idx so QEMU picks it up */
    meta->producer_idx = meta->producer_idx + 1;
    __sync_synchronize();

    printf("producer_idx now %u — check QEMU trace:\n", meta->producer_idx);
    printf("  docker logs spdk-kv-nvme-vm-qemu-1 2>&1 | grep pci_mmio_bridge\n");
    printf("  Expected: pci_nvme_mmio_doorbell_sq\n");

    sleep(2); /* give QEMU time to poll (poll_interval=1ms) */

    printf("consumer_idx after 2s: %u\n", meta->consumer_idx);
    munmap(shadow, req.shadow_size);
    close(fd);
    return 0;
}
