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

## Cursor Cloud specific instructions

The Cloud Agent VM has no AMD GPU, NVMe SSD, or RDMA NIC hardware.
All work is limited to compilation, unit/integration tests, linting,
and documentation builds.

The Cursor Cloud VM startup script (managed by the Cursor platform,
not stored in this repo) installs the latest release of ROCm from
`repo.radeon.com` along with the build and lint dependencies listed
below. Check the CI workflows (`.github/workflows/`) for the
container image tag currently in use and keep the installed ROCm
release in sync when that tag changes.

### Available scope

**Configure and build:**

```bash
cmake -DROCM_PATH=/opt/rocm -DBUILD_TESTING=ON -S . -B build
cmake --build build -j
```

**Unit tests:**

```bash
ctest -L unit --test-dir build
```

**All no-hardware tests** (mirrors `ctest-no-hardware.yml`):

```bash
HSA_FORCE_FINE_GRAIN_PCIE=1 \
  ctest --test-dir build \
    --label-exclude 'hardware|system' \
    --resource-spec-file "$PWD/build/ctest-resources.json" \
    --parallel "$(nproc)" \
    --output-on-failure
```

**Clang-format lint** (mirrors `build-check.yml`):

```bash
git ls-files '*.cpp' '*.h' '*.hpp' '*.c' '*.cc' '*.hip' \
  | grep -v 'src/include/external/' \
  | xargs clang-format-18 --style=file --dry-run --Werror
```

**ShellCheck** (mirrors `scripts-check.yml`):

```bash
find scripts -name '*.sh' \
  -exec shellcheck --severity=warning --exclude=SC2086 {} +
```

**Spell check and RST lint** (mirrors `spell-check.yml` and
`docs-check.yml`):

```bash
source .venv/bin/activate
pyspelling -c .spellcheck.yml
codespell
doc8 docs/ --max-line-length 80 \
  --ignore-path docs/sphinx/requirements.txt
```

**Sphinx docs build** (mirrors `docs-check.yml`):

```bash
source .venv/bin/activate
cmake -S . -B build-docs \
  -DXIO_DOCS_ONLY=ON -DXIO_BUILD_DOCS=ON
cmake --build build-docs --target sphinx-html
```

**Kernel module build:**

```bash
make -C kernel/rocm-xio
```

**xio-tester emulation demo:**

```bash
./build/xio-tester test-ep --emulate -n 32 --threads 2 -v
```

### Gotchas

- The system CXX compiler is clang-18 (not the ROCm `amdclang++`).
  The `libstdc++-14-dev` and clang-18 runtime dev packages must be
  installed for test and tester linking to succeed. The VM startup
  script handles this.
- `nvme-ep-generated.h` in `src/include/` is auto-generated and
  excluded from version control. Lint checks must exclude it or use
  `git ls-files` to enumerate sources.
- The Python venv at `.venv/` is used only for Sphinx docs and lint
  tools (codespell, pyspelling, doc8). Activate it before running
  those tools: `source .venv/bin/activate`.
- Without a GPU, `rocminfo` returns no devices; CMake defaults
  `XIODetectGPUs` to 1 GPU for CTest resource specs.
- Tests labeled `hardware` or `system` require real AMD GPU or NIC
  hardware and will fail in the Cloud Agent VM. Always pass
  `--label-exclude 'hardware|system'` to `ctest`.
- The VM kernel differs from the installed headers package. The VM
  startup script creates a link from
  `/lib/modules/$(uname -r)/build` to the installed headers so
  `make` in `kernel/rocm-xio` works. Debug type generation is
  skipped at build time; this is harmless for compilation checks.
