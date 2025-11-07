/*
 * VFIO P2P Setup Tool
 *
 * Maps NVMe BAR into VFIO container's IOMMU address space
 * so GPU can perform P2P access to NVMe doorbells.
 *
 * Run this INSIDE the VM before running GPU doorbell tests.
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <dirent.h>
#include <fcntl.h>
#include <linux/vfio.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define GPU_BDF "0000:10:00.0"
#define NVME_BDF "0000:c2:00.0"

// Helper to find IOMMU group for a device
int get_iommu_group(const char* bdf) {
  char path[256];
  char group_path[256];
  ssize_t len;

  snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/iommu_group", bdf);

  len = readlink(path, group_path, sizeof(group_path) - 1);
  if (len < 0) {
    perror("readlink iommu_group");
    return -1;
  }
  group_path[len] = '\0';

  // Extract group number from path like "../../../../kernel/iommu_groups/47"
  char* group_str = strrchr(group_path, '/');
  if (!group_str) {
    fprintf(stderr, "Failed to parse group path: %s\n", group_path);
    return -1;
  }

  return atoi(group_str + 1);
}

// Get the BAR0 physical address from sysfs
unsigned long get_bar_address(const char* bdf, int bar_index) {
  char path[256];
  char line[256];
  FILE* f;

  snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource", bdf);
  f = fopen(path, "r");
  if (!f) {
    perror("fopen resource");
    return 0;
  }

  // Read the requested BAR line
  for (int i = 0; i <= bar_index; i++) {
    if (!fgets(line, sizeof(line), f)) {
      fclose(f);
      return 0;
    }
  }
  fclose(f);

  unsigned long start, end, flags;
  if (sscanf(line, "0x%lx 0x%lx 0x%lx", &start, &end, &flags) != 3) {
    fprintf(stderr, "Failed to parse resource line: %s", line);
    return 0;
  }

  return start;
}

int main(int argc, char** argv) {
  int container_fd = -1;
  int group_gpu_fd = -1;
  int group_nvme_fd = -1;
  int gpu_device_fd = -1;
  int nvme_device_fd = -1;
  int ret = -1;

  printf("VFIO P2P Setup Tool\n");
  printf("===================\n\n");

  // Get IOMMU groups
  int gpu_group = get_iommu_group(GPU_BDF);
  int nvme_group = get_iommu_group(NVME_BDF);

  if (gpu_group < 0 || nvme_group < 0) {
    fprintf(stderr, "Failed to get IOMMU groups\n");
    goto cleanup;
  }

  printf("GPU  (%s): IOMMU group %d\n", GPU_BDF, gpu_group);
  printf("NVMe (%s): IOMMU group %d\n", NVME_BDF, nvme_group);

  if (gpu_group == nvme_group) {
    printf(
      "✓ Both devices in same IOMMU group - P2P should work automatically!\n");
  } else {
    printf("⚠ Devices in different IOMMU groups - need explicit mapping\n");
  }
  printf("\n");

  // Open VFIO container (QEMU creates this)
  container_fd = open("/dev/vfio/vfio", O_RDWR);
  if (container_fd < 0) {
    perror("Failed to open /dev/vfio/vfio");
    fprintf(stderr, "Make sure VFIO is enabled and you have permissions\n");
    goto cleanup;
  }

  // Check VFIO API version
  int vfio_version = ioctl(container_fd, VFIO_GET_API_VERSION);
  printf("VFIO API version: %d\n", vfio_version);
  if (vfio_version != VFIO_API_VERSION) {
    fprintf(stderr, "Unknown VFIO API version\n");
    goto cleanup;
  }

  // Open GPU's IOMMU group
  char group_path[64];
  snprintf(group_path, sizeof(group_path), "/dev/vfio/%d", gpu_group);
  group_gpu_fd = open(group_path, O_RDWR);
  if (group_gpu_fd < 0) {
    perror("Failed to open GPU IOMMU group");
    fprintf(stderr, "Path: %s\n", group_path);
    goto cleanup;
  }

  // Check if group is viable
  struct vfio_group_status group_status = {.argsz = sizeof(group_status)};
  if (ioctl(group_gpu_fd, VFIO_GROUP_GET_STATUS, &group_status) < 0) {
    perror("VFIO_GROUP_GET_STATUS (GPU)");
    goto cleanup;
  }

  if (!(group_status.flags & VFIO_GROUP_FLAGS_VIABLE)) {
    fprintf(stderr, "GPU group is not viable\n");
    goto cleanup;
  }

  printf("✓ GPU group is viable\n");

  // Open NVMe's IOMMU group
  snprintf(group_path, sizeof(group_path), "/dev/vfio/%d", nvme_group);
  group_nvme_fd = open(group_path, O_RDWR);
  if (group_nvme_fd < 0) {
    perror("Failed to open NVMe IOMMU group");
    fprintf(stderr, "Path: %s\n", group_path);
    goto cleanup;
  }

  if (ioctl(group_nvme_fd, VFIO_GROUP_GET_STATUS, &group_status) < 0) {
    perror("VFIO_GROUP_GET_STATUS (NVMe)");
    goto cleanup;
  }

  if (!(group_status.flags & VFIO_GROUP_FLAGS_VIABLE)) {
    fprintf(stderr, "NVMe group is not viable\n");
    goto cleanup;
  }

  printf("✓ NVMe group is viable\n");

  // Check if groups are already in a container
  if (!(group_status.flags & VFIO_GROUP_FLAGS_CONTAINER_SET)) {
    printf("Groups not in container yet, setting up...\n");

    // Set container for GPU group
    if (ioctl(group_gpu_fd, VFIO_GROUP_SET_CONTAINER, &container_fd) < 0) {
      perror("VFIO_GROUP_SET_CONTAINER (GPU)");
      goto cleanup;
    }

    // Set container for NVMe group
    if (ioctl(group_nvme_fd, VFIO_GROUP_SET_CONTAINER, &container_fd) < 0) {
      perror("VFIO_GROUP_SET_CONTAINER (NVMe)");
      goto cleanup;
    }

    // Set IOMMU type
    if (ioctl(container_fd, VFIO_SET_IOMMU, VFIO_TYPE1_IOMMU) < 0) {
      perror("VFIO_SET_IOMMU");
      goto cleanup;
    }

    printf("✓ Set up VFIO container with both groups\n");
  } else {
    printf("✓ Groups already in container (QEMU setup)\n");
  }

  // Get NVMe device
  nvme_device_fd = ioctl(group_nvme_fd, VFIO_GROUP_GET_DEVICE_FD, NVME_BDF);
  if (nvme_device_fd < 0) {
    perror("VFIO_GROUP_GET_DEVICE_FD (NVMe)");
    goto cleanup;
  }

  // Get NVMe device info
  struct vfio_device_info device_info = {.argsz = sizeof(device_info)};
  if (ioctl(nvme_device_fd, VFIO_DEVICE_GET_INFO, &device_info) < 0) {
    perror("VFIO_DEVICE_GET_INFO");
    goto cleanup;
  }

  printf("\nNVMe Device Info:\n");
  printf("  Regions: %d\n", device_info.num_regions);
  printf("  IRQs: %d\n", device_info.num_irqs);

  // Get BAR0 info
  struct vfio_region_info region_info = {
    .argsz = sizeof(region_info),
    .index = 0 // BAR0
  };
  if (ioctl(nvme_device_fd, VFIO_DEVICE_GET_REGION_INFO, &region_info) < 0) {
    perror("VFIO_DEVICE_GET_REGION_INFO");
    goto cleanup;
  }

  printf("\nNVMe BAR0:\n");
  printf("  Size: %lld bytes\n", region_info.size);
  printf("  Offset: 0x%llx\n", region_info.offset);
  printf("  Flags: 0x%x\n", region_info.flags);

  // Get BAR0 physical address
  unsigned long bar_phys_addr = get_bar_address(NVME_BDF, 0);
  if (bar_phys_addr == 0) {
    fprintf(stderr, "Failed to get BAR physical address\n");
    goto cleanup;
  }

  printf("  Physical address: 0x%lx\n", bar_phys_addr);

  // mmap the BAR
  void* bar_ptr = mmap(NULL, region_info.size, PROT_READ | PROT_WRITE,
                       MAP_SHARED, nvme_device_fd, region_info.offset);
  if (bar_ptr == MAP_FAILED) {
    perror("mmap BAR0");
    goto cleanup;
  }

  printf("  Host virtual address: %p\n", bar_ptr);

  // Now map this into the IOMMU address space for GPU access
  printf("\nMapping BAR for GPU P2P access...\n");

  struct vfio_iommu_type1_dma_map dma_map = {
    .argsz = sizeof(dma_map),
    .flags = VFIO_DMA_MAP_FLAG_READ | VFIO_DMA_MAP_FLAG_WRITE,
    .vaddr = (__u64)bar_ptr,
    .iova = bar_phys_addr, // Use physical address as IOVA
    .size = region_info.size};

  if (ioctl(container_fd, VFIO_IOMMU_MAP_DMA, &dma_map) < 0) {
    // This might fail if already mapped
    if (errno == EEXIST) {
      printf("⚠ Mapping already exists (that's OK)\n");
    } else {
      perror("VFIO_IOMMU_MAP_DMA");
      fprintf(stderr, "  IOVA: 0x%llx\n", dma_map.iova);
      fprintf(stderr, "  Size: %lld\n", dma_map.size);
      fprintf(stderr, "  This might fail if QEMU already mapped it,\n");
      fprintf(stderr, "  or if P2P is not supported on this platform.\n");
      goto cleanup;
    }
  } else {
    printf("✓ Successfully mapped NVMe BAR for GPU access!\n");
  }

  printf("\nP2P Mapping Details:\n");
  printf("  IOVA (what GPU sees): 0x%llx\n", dma_map.iova);
  printf("  Size: %lld bytes (0x%llx)\n", dma_map.size, dma_map.size);
  printf("  Doorbell offset: 0x1000\n");
  printf("  GPU can access doorbell at: 0x%llx\n", dma_map.iova + 0x1000);

  printf("\n✓ VFIO P2P setup complete!\n");
  printf("\nYou can now run GPU tests that access NVMe doorbells.\n");
  printf("The GPU will be able to write to IOVA 0x%llx\n",
         dma_map.iova + 0x1000);

  ret = 0;

cleanup:
  // Note: We intentionally don't close FDs or unmap
  // because we want the mappings to persist for the GPU test

  if (ret != 0) {
    printf("\n✗ VFIO P2P setup failed!\n");
  }

  return ret;
}
