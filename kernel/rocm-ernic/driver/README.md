# AMD ROCm ERNIC Driver (rocm_ernic)

## Overview

This is the Linux kernel driver for the AMD ROCm ERNIC (Emulated RDMA NIC),
designed for use with the libvfio-user based userspace device server
(`rocm-ernic`). The driver enables RDMA functionality in virtual machines.

## Building the Driver

```bash
# Build the module (note KDIR is optional)
make -C $KDIR M=$(pwd) modules

# Install the module (optional)
sudo make -C $KDIR M=$(pwd) modules_install
sudo depmod -a
```

## Loading the Driver

```bash
# Load the module
sudo modprobe rocm_ernic

# Check dmesg for driver messages
dmesg | grep rocm_ernic

# Expected output when device is found:
# [  xxx] rocm_ernic 0000:00:04.0: device version 17, driver version 20
# [  xxx] rocm_ernic 0000:00:04.0: DSR initialized after N polls
# [  xxx] rocm_ernic 0000:00:04.0: running in standalone mode (no netdev)
# [  xxx] rocm_ernic 0000:00:04.0: registered ibdev rocm_ernicX
```

## Testing with rocm-ernic server

1. Start the vfio-user server:
   ```bash
   cd /home/stebates/Projects/rocm-ernic
   sudo ./build/rocm-ernic --socket /tmp/vfio-user-rocm-ernic.sock
   ```

2. Launch QEMU with memory-backend-memfd:
   ```bash
   qemu-system-x86_64 \
     -machine q35,accel=kvm \
     -cpu EPYC \
     -smp cpus=2 \
     -object memory-backend-memfd,id=mem0,share=on,size=2048M \
     -machine memory-backend=mem0 \
     -nographic \
     -drive if=virtio,format=qcow2,file=vm-image.qcow2 \
     -netdev user,id=net0,hostfwd=tcp::2222-:22 \
     -device virtio-net-pci,netdev=net0 \
     -device '{"driver":"vfio-user-pci","socket":\
{"path":"/tmp/vfio-user-rocm-ernic.sock","type":"unix"}}'
   ```

3. Inside the guest, load the driver:
   ```bash
   sudo modprobe rocm_ernic
   ```

4. Verify the device is recognized:
   ```bash
   lspci | grep 1022:1488
   ibv_devices
   ```
