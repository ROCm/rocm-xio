<!-- Copyright (c) Advanced Micro Devices, Inc. All rights reserved.

SPDX-License-Identifier: MIT
-->

# Agent Notes

Before changing this codebase, read the relevant files under `docs/`. Start
with `docs/how-to/testing.rst`, then read endpoint, kernel-module, and
performance documentation as needed for the task. The test and hardware setup
rules in the docs are part of the expected development workflow, not optional
background reading.

## Prose Formatting

When editing Markdown or documentation prose, wrap lines to as close to 80
columns as possible. If the next word fits before column 80, keep it on the
current line. Code blocks, command lines, tables, and long paths or URLs are
exempt.

## Hardware Safety

Never use volatile NVMe namespace paths such as `/dev/nvme0n1` in destructive
or benchmark commands. The root filesystem may live on an NVMe namespace, so an
incorrect volatile path can corrupt the OS disk. NVMe hardware tests must target
only the spare MTR SLC SSD by stable identity:

```bash
/dev/disk/by-id/nvme-MTR_SLC_16GB_0400000E3CBC
```

For multi-queue NVMe runs, set an explicit queue id. On the current test node,
the MTR SLC controller has `queue_count=33`, so `ROCXIO_NVME_QUEUE_ID=32` is the
known-good value.

## Build Setup

Use the CMake build tree with tests enabled. When validating both Broadcom and
Pensando RDMA paths, configure both providers:

```bash
cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_TESTING=ON \
  -DGDA_BNXT=ON \
  -DGDA_IONIC=ON
cmake --build build --target all -j "$(nproc)"
```

The project builds and installs its own patched `rdma-core` tree for GDA
provider support. Rebuild it when provider flags or vendor patches change:

```bash
cmake --build build --target install-rdma-core -j "$(nproc)"
```

Use this library path for direct `xio-tester` runs:

```bash
LIB=/home/stebates/Projects/rocm-xio/build/_deps/rdma-core/install/lib
```

## udev And DKMS

Install the repo udev rules before RDMA hardware testing. The RDMA fixture
expects udev-provided names such as `rocm-bnxt0`, `rocm-rdma-bnxt0`,
`rocm-ionic0`, and `rocm-rdma-ionic0`.

```bash
sudo udev/setup-udev-rules.sh --install
sudo udevadm trigger
```

Install the repo DKMS drivers when the in-tree kernel modules do not expose the
GDA interfaces required by tests:

```bash
bash kernel/bnxt/setup-bnxt-re-dkms.sh
bash kernel/ionic/setup-ionic-eth-rdma-dkms.sh
```

After DKMS installation, reload the relevant drivers:

```bash
sudo modprobe -r bnxt_re 2>/dev/null || true
sudo modprobe bnxt_re
sudo modprobe -r ionic_rdma 2>/dev/null || true
sudo modprobe -r ionic 2>/dev/null || true
sudo modprobe ionic
sudo modprobe ionic_rdma
```

The ROCm XIO kernel module must be loaded for endpoints that register queues or
map doorbells:

```bash
cd kernel/rocm-xio
make
sudo make install
sudo modprobe rocm-xio
```

## RDMA Loopback Setup

Use the fixture script to prepare loopback mode, IP addresses, static neighbor
entries, and GID readiness. Pin the vendor while debugging one path:

```bash
sudo env VENDOR=bnxt scripts/test/setup-rdma-loopback.sh
sudo env VENDOR=ionic scripts/test/setup-rdma-loopback.sh
```

Pensando loopback requires Ionic firmware loopback mode. Verify it before
running Pensando tests:

```bash
cat /sys/class/net/rocm-ionic0/device/loopback_mode
```

The expected value is `2`. The Ionic RDMA port may still report `DOWN` or
`Polling` in firmware loopback mode; the GDA RDMA WRITE tests are the source of
truth for this path.

## Full CTest Sweep

Run the sweep in three parts so the results are deterministic and each vendor is
tested against the intended device.

First run non-RDMA tests, including NVMe on only the MTR SLC by-id namespace:

```bash
sudo env \
  ROCXIO_NVME_DEVICE=/dev/disk/by-id/nvme-MTR_SLC_16GB_0400000E3CBC \
  NVME_DEVICE=/dev/disk/by-id/nvme-MTR_SLC_16GB_0400000E3CBC \
  ROCXIO_NVME_QUEUE_ID=32 \
  LD_LIBRARY_PATH="$LIB:/opt/rocs-ais/lib:/opt/rocm/lib:${LD_LIBRARY_PATH:-}" \
  HSA_FORCE_FINE_GRAIN_PCIE=1 \
  ctest --test-dir build -LE 'rdma|fixture' \
    --resource-spec-file "$PWD/build/ctest-resources.json" \
    --output-on-failure
```

Then run the Broadcom RDMA sweep:

```bash
sudo env \
  VENDOR=bnxt \
  PROVIDER=bnxt \
  ROCXIO_RDMA_DEVICE=rocm-rdma-bnxt0 \
  LD_LIBRARY_PATH="$LIB:$LIB/libibverbs:/opt/rocs-ais/lib:/opt/rocm/lib:${LD_LIBRARY_PATH:-}" \
  HSA_FORCE_FINE_GRAIN_PCIE=1 \
  ctest --test-dir build -L rdma \
    --resource-spec-file "$PWD/build/ctest-resources.json" \
    --output-on-failure
```

Then run the Pensando Ionic RDMA sweep:

```bash
sudo env \
  VENDOR=ionic \
  PROVIDER=ionic \
  ROCXIO_RDMA_DEVICE=rocm-rdma-ionic0 \
  LD_LIBRARY_PATH="$LIB:$LIB/libibverbs:/opt/rocs-ais/lib:/opt/rocm/lib:${LD_LIBRARY_PATH:-}" \
  HSA_FORCE_FINE_GRAIN_PCIE=1 \
  ctest --test-dir build -L rdma \
    --resource-spec-file "$PWD/build/ctest-resources.json" \
    --output-on-failure
```

Expected skips are acceptable when they match the documented hardware limits:
`test-rdma-2node` skips without a two-node setup, and verbs bandwidth loopback
tests may skip when firmware loopback does not expose a normal verbs port. The
GDA `rdma-ep` loopback tests must pass for BNXT and Ionic.

## Long-Running Pensando Loopback

Stop any existing infinite run before starting another one. A useful Pensando
loopback stress command is:

```bash
sudo env \
  LD_LIBRARY_PATH="$LIB:/opt/rocm/lib:${LD_LIBRARY_PATH:-}" \
  HSA_FORCE_FINE_GRAIN_PCIE=1 \
  /home/stebates/Projects/rocm-xio/build/xio-tester rdma-ep \
    --provider ionic \
    --device rocm-rdma-ionic0 \
    --loopback \
    --iterations 0 \
    --transfer-size 4096 \
    --batch-size 4 \
    --num-queues 2 \
    --memory-mode 0 \
    --less-timing
```

Use `rdma statistic show` to observe `rocm-rdma-ionic0` traffic. For long
runs, watch GPU power management and temperatures as described in
`docs/how-to/testing.rst`.
