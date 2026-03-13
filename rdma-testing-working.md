# BNXT DV Loopback Test -- Working Steps

## Prerequisites

- ROCm 7.0+ with HIP SDK
- AMD GPU with ROCm support
- Broadcom Thor 2 NIC (vendor 0x14e4, part 0x1760)
- `cmake >= 3.21`, `libcli11-dev`, `libdrm-dev`
- `dkms`, kernel headers for running kernel

## 1. Build the DKMS kernel module

```bash
sudo kernel/bnxt/setup-bnxt-dv-dkms.sh
```

This downloads the stock `bnxt_re` source, extracts
a fresh copy, applies patches 0001-0007, and
builds/installs via DKMS. The source is re-extracted
and re-patched on every run (downloads are cached).
Patch 0007 extends the udata ABI so the DV userspace
can pass SQ/RQ buffer VAs and sizing through the
traditional write-based verbs path (avoiding the
ioctl-only upstream CQ/QP buffer attributes that are
not yet merged in mainline).

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
cmake -B build-dv -S . \
  -DGDA_BNXT=ON \
  -DBNXT_DV_BUILD_KMOD=ON \
  -DBUILD_TESTING=ON
```

This fetches and patches the `rdma-core` DV fork
automatically via
`scripts/build/build-bnxt-dv-rdma-core.sh`.
The script rewrites `dv.c` to use
`ibv_cmd_create_qp_ex2()` (write-based udata)
instead of `ibv_cmd_create_qp_ex3()` (ioctl buffer
attributes). The rdma-core fork is built with
`-DIOCTL_MODE=both` so that DV CQ creation (which
needs ioctl attributes) still works while QP
creation falls through to the write path.

## 3. Build

```bash
cmake --build build-dv -j$(nproc)
```

The patched `libbnxt_re.so` is installed into
`build-dv/_deps/bnxt-dv/rdma-core-install/lib/`.

## 4. Configure the NIC interface

The loopback test needs an IPv4 address on the NIC
for RoCE GID resolution, plus a static neighbor
entry pointing to its own MAC (loopback has no real
peer).

**Important**: NetworkManager may remove manually
added addresses. If you see addresses disappearing,
mark the interface as unmanaged:

```bash
sudo nmcli device set enp195s0f0np0 managed no
```

Find the NIC netdev and MAC:

```bash
rdma link show
# e.g. link rocep195s0f0/1 ... netdev enp195s0f0np0
ip link show enp195s0f0np0 | grep ether
# e.g. 8c:84:74:74:00:70
```

Assign an IP from the RFC 2544 benchmarking range
(198.18.0.0/15 -- reserved, won't conflict with
production traffic):

```bash
sudo ip addr add 198.18.0.1/24 dev enp195s0f0np0
sudo ip neigh replace 198.18.0.1 \
  lladdr 8c:84:74:74:00:70 nud permanent \
  dev enp195s0f0np0
```

Wait a few seconds for the GID table to populate,
then verify a RoCE v2 IPv4-mapped GID appears:

```bash
cat /sys/class/infiniband/rocep195s0f0/ports/1/gids/*\
  | grep -v '0000:0000:0000:0000:0000:0000:0000:0000'
# expect a line containing:
#   0000:0000:0000:0000:0000:ffff:c612:0001
# (which is ::ffff:198.18.0.1)
```

**Note**: `ibv_devinfo -v` also shows GIDs but can
take 30+ seconds on Thor 2. Reading the sysfs GID
files directly is much faster.

## 5. Run the loopback test

```bash
sudo env \
  LD_LIBRARY_PATH=$(pwd)/build-dv/_deps/bnxt-dv/\
rdma-core-install/lib:$(pwd)/build-dv/install/lib:\
/opt/rocm/lib \
  ./build-dv/tests/unit/rdma-ep/\
test-rdma-bnxt-loopback
```

Expected output:

```
rdma_ep: BNXT DV library loaded.
...
PASSED: All 256 bytes LFSR-verified via
        RDMA WRITE loopback.
```

Typical GPU kernel latency is ~16 us for the 256 B
RDMA WRITE + CQE wait.

## 6. Other tests you can run

All tests use the same `LD_LIBRARY_PATH` prefix
shown in step 5.

| Test binary          | What it tests           |
|----------------------|-------------------------|
| `test-rdma-vendors`  | Vendor ops dispatch     |
| `test-rdma-config`   | rdma-ep config parsing  |
| `test-rdma-endian`   | Endian helpers          |
| `test-rdma-bnxt-loopback` | Full DV data path  |

```bash
# Quick smoke test (no NIC needed):
./build-dv/tests/unit/rdma-ep/test-rdma-vendors
./build-dv/tests/unit/rdma-ep/test-rdma-config
./build-dv/tests/unit/rdma-ep/test-rdma-endian

# Full data path (needs NIC + IP config):
sudo env LD_LIBRARY_PATH=... \
  ./build-dv/tests/unit/rdma-ep/\
test-rdma-bnxt-loopback
```

## Quick re-run checklist

After reboot or `modprobe -r bnxt_re && modprobe
bnxt_re`:

1. Wait ~5 s for the NIC to re-initialize.
2. Re-add the IP address and neighbor entry
   (step 4). These are **not persistent** across
   module reloads.
3. Wait ~5 s for the GID table to populate.
4. Verify the `::ffff:c612:0001` GID is present.
5. Run the test.

If `modify_qp (INIT->RTR)` fails with error 110
(`ETIMEDOUT`), the GID table has not finished
populating. Wait a few more seconds and retry.

## Troubleshooting

### `ibv_cmd_create_qp_ex2() failed: 14` (EFAULT)

The DKMS module was built without the DV QP
handling code in `ib_verbs.c`. The kernel falls
back to its own buffer sizing which does not match
the DV userspace allocation, causing `ib_umem_get`
to fail pinning pages beyond the buffer. Re-run
`setup-bnxt-dv-dkms.sh` (it re-extracts and
re-patches unconditionally) and reload the module.

### `ibv_cmd_create_qp_ex2() failed: 22` (EINVAL)

The DKMS module may not have the DV QP udata
patch applied. Verify:

```bash
grep -c DV_QP_ENABLE \
  /usr/src/bnxt-re-dv-0.1/ib_verbs.c
# expect: >= 1
grep -c DV_QP_ENABLE \
  /usr/src/bnxt-re-dv-0.1/include/rdma/\
bnxt_re-abi.h
# expect: >= 1
```

If missing, re-run `setup-bnxt-dv-dkms.sh` and
reload the module.

### `Could not open libbnxt_re.so`

The `LD_LIBRARY_PATH` is missing the rdma-core
install directory. Make sure it includes:

```
build-dv/_deps/bnxt-dv/rdma-core-install/lib
```

### `DV Modify QP error: 110` (ETIMEDOUT)

Usually means the IPv4-mapped GID is missing. Check
that:

- The IP address is assigned (`ip addr show`)
- The static neighbor entry exists (`ip neigh show`)
- The GID `::ffff:c612:0001` appears in
  `/sys/class/infiniband/rocep195s0f0/ports/1/gids/`

### Segfault after QP creation failure

The test does not yet cleanly handle a NULL QP
pointer from a failed `bnxt_re_dv_create_qp()`.
Fix the root cause (above) rather than the segfault.
