# BNXT DV Loopback Test -- Working Steps

## Prerequisites

- ROCm 7.0+ with HIP SDK
- AMD MI300X GPU (or compatible)
- Broadcom Thor 2 NIC
- `cmake >= 3.21`, `libcli11-dev`, `libdrm-dev`
- `dkms`, kernel headers for running kernel

## 1. Build the DKMS kernel module

```bash
sudo kernel/bnxt/setup-bnxt-dv-dkms.sh
```

Verify it loaded:

```bash
modinfo bnxt_re | grep filename
# expect: /lib/modules/.../updates/dkms/bnxt_re.ko.zst
```

If the stock module is still loaded, reload:

```bash
sudo modprobe -r bnxt_re && sudo modprobe bnxt_re
```

## 2. CMake configure

```bash
cmake -B build -S . \
  -DGDA_BNXT=ON \
  -DBNXT_DV_BUILD_KMOD=ON \
  -DBUILD_TESTING=ON
```

This fetches and patches the `rdma-core` DV fork
automatically via `scripts/build/build-bnxt-dv-rdma-core.sh`.

## 3. Build

```bash
cmake --build build -j$(nproc)
```

The patched `libbnxt_re.so` is installed into
`build/_deps/bnxt-dv/rdma-core-install/lib/`.

## 4. Configure the NIC interface

The loopback test needs an IPv4 address on the NIC
for RoCE GID resolution, plus a static neighbor entry
pointing to its own MAC (loopback has no real peer).

Find the NIC netdev and MAC:

```bash
rdma link show
# e.g. link rocep195s0f0/1 ... netdev enp195s0f0np0
ip link show enp195s0f0np0 | grep ether
# e.g. 8c:84:74:74:00:70
```

Pick an unused subnet and assign:

```bash
sudo ip addr add 198.18.0.1/24 dev enp195s0f0np0
sudo ip neigh replace 198.18.0.1 \
  lladdr 8c:84:74:74:00:70 nud permanent \
  dev enp195s0f0np0
```

Verify a RoCE v2 IPv4-mapped GID appears:

```bash
ibv_devinfo -v | grep 'GID\['
# expect: ::ffff:198.18.0.1, RoCE v2
```

## 5. Run the loopback test

```bash
sudo LD_LIBRARY_PATH=$(pwd)/build/_deps/bnxt-dv/\
rdma-core-install/lib \
  ./build/tests/unit/rdma-ep/test-rdma-bnxt-loopback
```

Expected output:

```
PASSED: All 256 bytes LFSR-verified via
        RDMA WRITE loopback.
```

## Quick re-run checklist

After reboot or module reload, re-do step 4 (the IP
and neighbor entry are not persistent).
