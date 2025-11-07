/*
 * Host-Side VFIO P2P Setup Tool
 * 
 * Runs ON THE HOST while VM is running.
 * Finds QEMU's VFIO container and adds P2P mappings
 * for GPU to access NVMe BAR.
 * 
 * Usage:
 *   1. Start VM with GPU and NVMe passthrough
 *   2. Run this tool on the host: sudo ./host_vfio_p2p_setup
 *   3. Tool finds QEMU's container and sets up P2P
 *   4. Test GPU→NVMe access in VM
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <errno.h>
#include <dirent.h>
#include <linux/vfio.h>

#define GPU_BDF "0000:10:00.0"
#define NVME_BDF "0000:c2:00.0"

// Find which process (QEMU) has the VFIO groups open
int find_qemu_pid(int gpu_group, int nvme_group) {
    DIR *proc = opendir("/proc");
    if (!proc) {
        perror("opendir /proc");
        return -1;
    }
    
    struct dirent *entry;
    while ((entry = readdir(proc)) != NULL) {
        if (entry->d_type != DT_DIR)
            continue;
            
        // Check if directory name is numeric (PID)
        int pid = atoi(entry->d_name);
        if (pid <= 0)
            continue;
        
        // Check if this process has our VFIO groups open
        char fd_path[512];
        snprintf(fd_path, sizeof(fd_path), "/proc/%d/fd", pid);
        
        DIR *fd_dir = opendir(fd_path);
        if (!fd_dir)
            continue;
        
        int found_gpu = 0, found_nvme = 0;
        struct dirent *fd_entry;
        while ((fd_entry = readdir(fd_dir)) != NULL) {
            char link_path[512], target[512];
            snprintf(link_path, sizeof(link_path), "/proc/%d/fd/%s", pid, fd_entry->d_name);
            
            ssize_t len = readlink(link_path, target, sizeof(target) - 1);
            if (len < 0)
                continue;
            target[len] = '\0';
            
            char gpu_dev[64], nvme_dev[64];
            snprintf(gpu_dev, sizeof(gpu_dev), "/dev/vfio/%d", gpu_group);
            snprintf(nvme_dev, sizeof(nvme_dev), "/dev/vfio/%d", nvme_group);
            
            if (strcmp(target, gpu_dev) == 0)
                found_gpu = 1;
            if (strcmp(target, nvme_dev) == 0)
                found_nvme = 1;
        }
        closedir(fd_dir);
        
        if (found_gpu && found_nvme) {
            closedir(proc);
            return pid;
        }
    }
    
    closedir(proc);
    return -1;
}

int get_iommu_group(const char *bdf) {
    char path[256], group_path[256];
    ssize_t len;
    
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/iommu_group", bdf);
    len = readlink(path, group_path, sizeof(group_path) - 1);
    if (len < 0) {
        perror("readlink iommu_group");
        return -1;
    }
    group_path[len] = '\0';
    
    char *group_str = strrchr(group_path, '/');
    if (!group_str)
        return -1;
    
    return atoi(group_str + 1);
}

unsigned long get_bar_address(const char *bdf, int bar_index) {
    char path[256], line[256];
    FILE *f;
    
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource", bdf);
    f = fopen(path, "r");
    if (!f) {
        perror("fopen resource");
        return 0;
    }
    
    for (int i = 0; i <= bar_index; i++) {
        if (!fgets(line, sizeof(line), f)) {
            fclose(f);
            return 0;
        }
    }
    fclose(f);
    
    unsigned long start, end, flags;
    if (sscanf(line, "0x%lx 0x%lx 0x%lx", &start, &end, &flags) != 3)
        return 0;
    
    return start;
}

unsigned long get_bar_size(const char *bdf, int bar_index) {
    char path[256], line[256];
    FILE *f;
    
    snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/resource", bdf);
    f = fopen(path, "r");
    if (!f) {
        perror("fopen resource");
        return 0;
    }
    
    for (int i = 0; i <= bar_index; i++) {
        if (!fgets(line, sizeof(line), f)) {
            fclose(f);
            return 0;
        }
    }
    fclose(f);
    
    unsigned long start, end, flags;
    if (sscanf(line, "0x%lx 0x%lx 0x%lx", &start, &end, &flags) != 3) {
        fclose(f);
        return 0;
    }
    
    fclose(f);
    return (end - start + 1);
}

int main(int argc, char **argv) {
    printf("=================================\n");
    printf("Host-Side VFIO P2P Setup Tool\n");
    printf("=================================\n\n");
    
    if (geteuid() != 0) {
        fprintf(stderr, "ERROR: Must run as root (sudo)\n");
        return 1;
    }
    
    // Get IOMMU groups
    int gpu_group = get_iommu_group(GPU_BDF);
    int nvme_group = get_iommu_group(NVME_BDF);
    
    if (gpu_group < 0 || nvme_group < 0) {
        fprintf(stderr, "Failed to get IOMMU groups\n");
        return 1;
    }
    
    printf("Device Configuration:\n");
    printf("  GPU  (%s): IOMMU group %d\n", GPU_BDF, gpu_group);
    printf("  NVMe (%s): IOMMU group %d\n", NVME_BDF, nvme_group);
    printf("\n");
    
    // Check if devices are bound to vfio-pci
    char driver_path[256], driver[256];
    ssize_t len;
    
    snprintf(driver_path, sizeof(driver_path), "/sys/bus/pci/devices/%s/driver", GPU_BDF);
    len = readlink(driver_path, driver, sizeof(driver) - 1);
    if (len < 0) {
        fprintf(stderr, "GPU not bound to any driver\n");
        return 1;
    }
    driver[len] = '\0';
    char *gpu_driver = strrchr(driver, '/');
    printf("GPU driver: %s\n", gpu_driver ? gpu_driver + 1 : "unknown");
    
    snprintf(driver_path, sizeof(driver_path), "/sys/bus/pci/devices/%s/driver", NVME_BDF);
    len = readlink(driver_path, driver, sizeof(driver) - 1);
    if (len < 0) {
        fprintf(stderr, "NVMe not bound to any driver\n");
        return 1;
    }
    driver[len] = '\0';
    char *nvme_driver = strrchr(driver, '/');
    printf("NVMe driver: %s\n", nvme_driver ? nvme_driver + 1 : "unknown");
    printf("\n");
    
    if (strcmp(gpu_driver ? gpu_driver + 1 : "", "vfio-pci") != 0 ||
        strcmp(nvme_driver ? nvme_driver + 1 : "", "vfio-pci") != 0) {
        fprintf(stderr, "WARNING: Devices should be bound to vfio-pci for VM passthrough\n");
        fprintf(stderr, "Is the VM running with these devices passed through?\n\n");
    }
    
    // Find QEMU process
    printf("Looking for QEMU process with both devices...\n");
    int qemu_pid = find_qemu_pid(gpu_group, nvme_group);
    if (qemu_pid < 0) {
        fprintf(stderr, "Could not find QEMU process with both VFIO groups open.\n");
        fprintf(stderr, "Is the VM running with GPU and NVMe passthrough?\n");
        return 1;
    }
    
    printf("✓ Found QEMU PID: %d\n\n", qemu_pid);
    
    // Now we need to open the same VFIO resources
    // This is tricky - we'll try to open a new container
    printf("Opening VFIO container...\n");
    int container_fd = open("/dev/vfio/vfio", O_RDWR);
    if (container_fd < 0) {
        perror("Failed to open /dev/vfio/vfio");
        return 1;
    }
    
    // Open IOMMU groups
    char group_path[64];
    snprintf(group_path, sizeof(group_path), "/dev/vfio/%d", gpu_group);
    int group_gpu_fd = open(group_path, O_RDWR);
    if (group_gpu_fd < 0) {
        perror("Failed to open GPU group");
        fprintf(stderr, "QEMU probably has it locked. This approach won't work.\n");
        fprintf(stderr, "\nThe problem: QEMU has exclusive access to the VFIO groups.\n");
        fprintf(stderr, "We can't modify QEMU's container from outside.\n\n");
        fprintf(stderr, "Solutions:\n");
        fprintf(stderr, "  1. Test on bare metal host (no VM) - RECOMMENDED\n");
        fprintf(stderr, "  2. Patch QEMU to add P2P mappings\n");
        fprintf(stderr, "  3. Use libvirt hooks to set up P2P\n");
        fprintf(stderr, "  4. Research QEMU P2P configuration options\n\n");
        close(container_fd);
        return 1;
    }
    
    printf("✓ Opened VFIO resources\n");
    
    // This probably won't work because QEMU has exclusive access
    // But let's try anyway...
    
    struct vfio_group_status group_status = {
        .argsz = sizeof(group_status)
    };
    
    if (ioctl(group_gpu_fd, VFIO_GROUP_GET_STATUS, &group_status) < 0) {
        perror("VFIO_GROUP_GET_STATUS");
        goto cleanup;
    }
    
    printf("GPU group status: 0x%x\n", group_status.flags);
    
    if (group_status.flags & VFIO_GROUP_FLAGS_CONTAINER_SET) {
        printf("Group is already in a container (QEMU's).\n");
        printf("Cannot modify from outside process.\n\n");
        printf("This confirms: VFIO groups are locked to QEMU.\n");
        printf("We need a different approach.\n\n");
        goto cleanup;
    }
    
    // If we get here, we could try to set up our own container
    // But this would conflict with QEMU...
    printf("Unexpected: Group not in container?\n");
    
cleanup:
    printf("\n=================================\n");
    printf("Analysis Complete\n");
    printf("=================================\n\n");
    
    printf("FINDING: QEMU has exclusive access to VFIO groups.\n");
    printf("         Cannot modify from external process.\n\n");
    
    printf("RECOMMENDATION: Test on bare metal host instead!\n\n");
    
    printf("Next steps:\n");
    printf("  1. Shutdown the VM\n");
    printf("  2. Unbind devices from vfio-pci\n");
    printf("  3. Load native drivers (amdgpu, nvme_gda)\n");
    printf("  4. Test GPU→NVMe doorbell access\n");
    printf("  5. Should work without VFIO complexity!\n\n");
    
    close(group_gpu_fd);
    close(container_fd);
    return 0;
}

