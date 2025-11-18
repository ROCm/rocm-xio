/*
 * Test: Write random data to first 512 LBAs, then read back at random and verify
 *
 * This test:
 * 1. Creates a queue via kernel module
 * 2. Writes random data patterns to LBAs 0-511 (512 LBAs)
 * 3. Reads back from random LBAs in range 0-511
 * 4. Verifies data matches
 */

#include <iostream>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <random>
#include <vector>
#include <hip/hip_runtime.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include "../kernel-module/nvme_axiio.h"
#include "nvme-gpu-doorbell-hsa.h"
#include "../endpoints/nvme-ep/nvme-ep.h"

// GPU kernel to write random data pattern to buffer
__global__ void write_random_pattern(uint8_t* buffer, uint64_t lba, uint32_t seed) {
    int idx = threadIdx.x + blockIdx.x * blockDim.x;
    if (idx < 512) { // 512 bytes = 1 LBA
        // Generate deterministic random data based on LBA and seed
        uint32_t rng = (uint32_t)(lba * 0x9e3779b9 + seed + idx);
        rng ^= rng >> 16;
        rng *= 0x85ebca6b;
        rng ^= rng >> 13;
        rng *= 0xc2b2ae35;
        rng ^= rng >> 16;
        buffer[idx] = (uint8_t)(rng & 0xFF);
    }
}

// GPU kernel to generate NVMe Write commands
__global__ void generate_write_commands(
    struct nvme_sqe* sq,
    volatile uint32_t* doorbell,
    uint32_t nsid,
    uint64_t start_lba,
    uint32_t num_lbas,
    uint64_t data_buffer_phys,
    uint32_t queue_size) {

    int tid = hipThreadIdx_x + hipBlockIdx_x * hipBlockDim_x;

    if (tid == 0) {
        uint32_t sq_tail = 0;

        // Generate write commands for LBAs 0-511
        for (uint32_t i = 0; i < num_lbas; i++) {
            uint64_t lba = start_lba + i;
            struct nvme_sqe* sqe = &sq[sq_tail];

            // Setup NVMe Write command (1 block = 512 bytes)
            nvme_sqe_setup_write(sqe, i, nsid, lba, 1,
                                data_buffer_phys + (i * 512), 0);

            sq_tail = (sq_tail + 1) % queue_size;
        }

        __threadfence_system();
        *doorbell = sq_tail;
        __threadfence_system();

        printf("[GPU] Generated %u write commands, doorbell=%u\n", num_lbas, sq_tail);
    }
}

// GPU kernel to generate NVMe Read commands (random LBAs)
__global__ void generate_random_read_commands(
    struct nvme_sqe* sq,
    volatile uint32_t* doorbell,
    uint32_t nsid,
    uint64_t* random_lbas,
    uint32_t num_reads,
    uint64_t data_buffer_phys,
    uint32_t queue_size) {

    int tid = hipThreadIdx_x + hipBlockIdx_x * hipBlockDim_x;

    if (tid == 0) {
        uint32_t sq_tail = 0;

        // Generate read commands for random LBAs
        for (uint32_t i = 0; i < num_reads; i++) {
            uint64_t lba = random_lbas[i];
            struct nvme_sqe* sqe = &sq[sq_tail];

            // Setup NVMe Read command (1 block = 512 bytes)
            nvme_sqe_setup_read(sqe, i, nsid, lba, 1,
                                data_buffer_phys + (i * 512), 0);

            sq_tail = (sq_tail + 1) % queue_size;
        }

        __threadfence_system();
        *doorbell = sq_tail;
        __threadfence_system();

        printf("[GPU] Generated %u read commands, doorbell=%u\n", num_reads, sq_tail);
    }
}

int main(int argc, char* argv[]) {
    std::cout << "=== NVMe Write/Read/Verify Test ===" << std::endl;
    std::cout << "Writing random data to LBAs 0-511, then reading back randomly" << std::endl;
    std::cout << std::endl;

    const uint32_t NUM_LBAS = 512;
    const uint32_t NUM_RANDOM_READS = 100;
    const uint32_t BLOCK_SIZE = 512;
    const uint32_t NSID = 1;

    // Initialize HSA
    if (nvme_hsa_doorbell::init_hsa() < 0) {
        std::cerr << "Failed to initialize HSA" << std::endl;
        return 1;
    }

    // Open kernel module device
    int fd = open("/dev/nvme-axiio", O_RDWR);
    if (fd < 0) {
        std::cerr << "Failed to open /dev/nvme-axiio: " << strerror(errno) << std::endl;
        return 1;
    }

    // Create queue
    struct nvme_axiio_queue_info qinfo;
    memset(&qinfo, 0, sizeof(qinfo));
    qinfo.queue_id = 63;
    qinfo.queue_size = 1024;
    qinfo.nsid = NSID;

    std::cout << "Creating queue 63..." << std::endl;
    if (ioctl(fd, NVME_AXIIO_CREATE_QUEUE, &qinfo) < 0) {
        std::cerr << "Failed to create queue: " << strerror(errno) << std::endl;
        close(fd);
        return 1;
    }

    std::cout << "✅ Queue created successfully" << std::endl;
    std::cout << "  SQ DMA (IOVA): 0x" << std::hex << qinfo.sq_dma_addr << std::dec << std::endl;

    // Map SQE buffer
    size_t sq_size = qinfo.queue_size * 64;
    void* sq_ptr = mmap(NULL, sq_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (sq_ptr == MAP_FAILED) {
        std::cerr << "Failed to mmap SQE buffer: " << strerror(errno) << std::endl;
        close(fd);
        return 1;
    }

    // Lock SQE buffer with HSA
    void* gpu_sq_ptr = nullptr;
    hsa_status_t status = hsa_amd_memory_lock(sq_ptr, sq_size,
                                               &nvme_hsa_doorbell::gpu_agent, 1,
                                               &gpu_sq_ptr);
    if (status != HSA_STATUS_SUCCESS) {
        std::cerr << "Failed to lock SQE buffer: " << status << std::endl;
        munmap(sq_ptr, sq_size);
        close(fd);
        return 1;
    }

    // Map doorbell
    size_t page_size = getpagesize();
    void* doorbell_ptr = mmap(NULL, page_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 2 * page_size);
    if (doorbell_ptr == MAP_FAILED) {
        std::cerr << "Failed to mmap doorbell: " << strerror(errno) << std::endl;
        hsa_amd_memory_unlock(sq_ptr);
        munmap(sq_ptr, sq_size);
        close(fd);
        return 1;
    }

    uint32_t sq_offset = qinfo.sq_doorbell_offset & (page_size - 1);
    volatile uint32_t* cpu_doorbell = (volatile uint32_t*)((char*)doorbell_ptr + sq_offset);

    // Lock doorbell with HSA
    void* gpu_doorbell_ptr = nullptr;
    status = hsa_amd_memory_lock(doorbell_ptr, page_size,
                                 &nvme_hsa_doorbell::gpu_agent, 1,
                                 &gpu_doorbell_ptr);
    if (status != HSA_STATUS_SUCCESS) {
        std::cerr << "Failed to lock doorbell: " << status << std::endl;
        munmap(doorbell_ptr, page_size);
        hsa_amd_memory_unlock(sq_ptr);
        munmap(sq_ptr, sq_size);
        close(fd);
        return 1;
    }

    volatile uint32_t* gpu_doorbell = (volatile uint32_t*)((char*)gpu_doorbell_ptr + sq_offset);

    // Declare all variables before any goto statements
    struct nvme_axiio_dma_buffer write_buf_info = {}, read_buf_info = {};
    void* write_buf = MAP_FAILED;
    void* read_buf = MAP_FAILED;
    void* gpu_write_buf = nullptr;
    void* gpu_read_buf = nullptr;
    std::vector<uint64_t> random_lbas;
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<uint64_t> dis(0, NUM_LBAS - 1);
    uint64_t* gpu_random_lbas = nullptr;
    uint32_t mismatches = 0;
    uint32_t total_bytes_checked = 0;
    int ret = 0;

    // Allocate data buffers (round up to page size for mmap compatibility)
    size_t page_size_val = getpagesize();
    write_buf_info.size = ((NUM_LBAS * BLOCK_SIZE + page_size_val - 1) / page_size_val) * page_size_val;
    read_buf_info.size = ((NUM_RANDOM_READS * BLOCK_SIZE + page_size_val - 1) / page_size_val) * page_size_val;

    std::cout << "Allocating write buffer (" << write_buf_info.size << " bytes)..." << std::endl;
    if (ioctl(fd, NVME_AXIIO_ALLOC_DMA, &write_buf_info) < 0) {
        std::cerr << "Failed to allocate write buffer: " << strerror(errno) << std::endl;
        ret = 1;
        goto cleanup;
    }

    std::cout << "Allocating read buffer (" << read_buf_info.size << " bytes)..." << std::endl;
    if (ioctl(fd, NVME_AXIIO_ALLOC_DMA, &read_buf_info) < 0) {
        std::cerr << "Failed to allocate read buffer: " << strerror(errno) << std::endl;
        ret = 1;
        goto cleanup;
    }

    // Map data buffers (offset 4 = first DMA buffer, offset 5 = second DMA buffer)
    // Note: mmap offset is in bytes, but vm_pgoff is in page units
    // So we use 4 * PAGE_SIZE for the first buffer, 5 * PAGE_SIZE for the second
    write_buf = mmap(NULL, write_buf_info.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 4 * page_size_val);
    read_buf = mmap(NULL, read_buf_info.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 5 * page_size_val);

    if (write_buf == MAP_FAILED || read_buf == MAP_FAILED) {
        std::cerr << "Failed to mmap data buffers: " << strerror(errno) << std::endl;
        ret = 1;
        goto cleanup;
    }

    // Lock data buffers with HSA
    hsa_amd_memory_lock(write_buf, write_buf_info.size, &nvme_hsa_doorbell::gpu_agent, 1, &gpu_write_buf);
    hsa_amd_memory_lock(read_buf, read_buf_info.size, &nvme_hsa_doorbell::gpu_agent, 1, &gpu_read_buf);

    std::cout << std::endl;
    std::cout << "=== Phase 1: Writing random data to LBAs 0-511 ===" << std::endl;

    // Generate random data patterns for each LBA
    for (uint32_t i = 0; i < NUM_LBAS; i++) {
        uint32_t seed = i * 0x12345678;
        hipLaunchKernelGGL(write_random_pattern, dim3(1), dim3(512), 0, 0,
                          (uint8_t*)gpu_write_buf + (i * BLOCK_SIZE), (uint64_t)i, seed);
    }
    if (hipDeviceSynchronize() != hipSuccess) {
        std::cerr << "Failed to synchronize GPU" << std::endl;
        ret = 1;
        goto cleanup;
    }
    std::cout << "✅ Generated random data patterns" << std::endl;

    // Generate write commands
    *cpu_doorbell = 0; // Reset doorbell
    hipLaunchKernelGGL(generate_write_commands, dim3(1), dim3(1), 0, 0,
                      (struct nvme_sqe*)gpu_sq_ptr, gpu_doorbell,
                      NSID, 0ULL, NUM_LBAS, write_buf_info.dma_addr, qinfo.queue_size);
    if (hipDeviceSynchronize() != hipSuccess) {
        std::cerr << "Failed to generate write commands" << std::endl;
        ret = 1;
        goto cleanup;
    }

    std::cout << "✅ Write commands generated and doorbell rung" << std::endl;
    std::cout << "  Waiting for write completions..." << std::endl;

    // Wait for completions (simplified - in real test would poll CQ)
    sleep(2);

    std::cout << std::endl;
    std::cout << "=== Phase 2: Reading back from random LBAs ===" << std::endl;

    // Generate random LBA list (using pre-initialized RNG)
    for (uint32_t i = 0; i < NUM_RANDOM_READS; i++) {
        random_lbas.push_back(dis(gen));
    }

    // Copy random LBAs to GPU
    if (hipMalloc(&gpu_random_lbas, NUM_RANDOM_READS * sizeof(uint64_t)) != hipSuccess ||
        hipMemcpy(gpu_random_lbas, random_lbas.data(), NUM_RANDOM_READS * sizeof(uint64_t), hipMemcpyHostToDevice) != hipSuccess) {
        std::cerr << "Failed to allocate/copy random LBAs to GPU" << std::endl;
        ret = 1;
        goto cleanup;
    }

    // Generate read commands
    *cpu_doorbell = 0; // Reset doorbell
    hipLaunchKernelGGL(generate_random_read_commands, dim3(1), dim3(1), 0, 0,
                      (struct nvme_sqe*)gpu_sq_ptr, gpu_doorbell,
                      NSID, gpu_random_lbas, NUM_RANDOM_READS, read_buf_info.dma_addr, qinfo.queue_size);
    if (hipDeviceSynchronize() != hipSuccess) {
        std::cerr << "Failed to generate read commands" << std::endl;
        ret = 1;
        goto cleanup;
    }

    std::cout << "✅ Read commands generated and doorbell rung" << std::endl;
    std::cout << "  Waiting for read completions..." << std::endl;

    // Wait for completions
    sleep(2);

    std::cout << std::endl;
    std::cout << "=== Phase 3: Verifying data ===" << std::endl;

    // Verify read data matches expected LFSR sequence
    std::cout << "Verifying read data against expected LFSR sequence..." << std::endl;

    for (uint32_t i = 0; i < NUM_RANDOM_READS; i++) {
        uint64_t lba = random_lbas[i];
        uint8_t* read_lba_buf = (uint8_t*)read_buf + (i * BLOCK_SIZE);
        uint32_t seed = lba * 0x12345678;

        // Regenerate expected data for this LBA using same LFSR sequence
        for (uint32_t idx = 0; idx < BLOCK_SIZE; idx++) {
            uint32_t rng = (uint32_t)(lba * 0x9e3779b9 + seed + idx);
            rng ^= rng >> 16;
            rng *= 0x85ebca6b;
            rng ^= rng >> 13;
            rng *= 0xc2b2ae35;
            rng ^= rng >> 16;
            uint8_t expected = (uint8_t)(rng & 0xFF);

            uint8_t actual = read_lba_buf[idx];
            total_bytes_checked++;

            if (actual != expected) {
                if (mismatches < 10) { // Only print first 10 mismatches
                    std::cerr << "  ❌ Mismatch at LBA " << lba << ", byte " << idx
                              << ": expected 0x" << std::hex << (int)expected
                              << ", got 0x" << (int)actual << std::dec << std::endl;
                }
                mismatches++;
            }
        }
    }

    if (mismatches == 0) {
        std::cout << "✅ All " << total_bytes_checked << " bytes verified successfully!" << std::endl;
        std::cout << "  Verified " << NUM_RANDOM_READS << " random LBAs" << std::endl;
    } else {
        std::cerr << "❌ Verification failed: " << mismatches << " mismatches out of "
                  << total_bytes_checked << " bytes checked" << std::endl;
        ret = 1;
    }

cleanup:
    if (gpu_random_lbas != nullptr) {
        hipFree(gpu_random_lbas);
    }
    if (read_buf != MAP_FAILED) {
        if (gpu_read_buf != nullptr) {
            hsa_amd_memory_unlock(read_buf);
        }
        munmap(read_buf, read_buf_info.size);
    }
    if (write_buf != MAP_FAILED) {
        if (gpu_write_buf != nullptr) {
            hsa_amd_memory_unlock(write_buf);
        }
        munmap(write_buf, write_buf_info.size);
    }
    if (doorbell_ptr != MAP_FAILED) {
        hsa_amd_memory_unlock(doorbell_ptr);
        munmap(doorbell_ptr, page_size);
    }
    if (sq_ptr != MAP_FAILED) {
        hsa_amd_memory_unlock(sq_ptr);
        munmap(sq_ptr, sq_size);
    }
    close(fd);

    std::cout << std::endl;
    std::cout << "=== Test Complete ===" << std::endl;
    std::cout << "Check QEMU logs for NVMe command processing" << std::endl;

    return ret;
}


