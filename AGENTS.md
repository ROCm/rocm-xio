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

## VM Testing With An Emulated GPU

`scripts/test/run-vm-nvme.sh` brings up a QEMU guest with a rocjitsu-emulated
gfx1250 attached over vfio-user and an emulated NVMe controller, provisions it,
builds rocm-xio inside it, and runs the `nvme-ep` ctest labels. This is the only
way to exercise the NVMe endpoint without real hardware, and it is what
`.github/workflows/test-vm-nvme.yml` runs in CI.

There is no GPU on the login node, so the script has to run on a storage node
under Slurm:

```bash
srun -M cluster -p storage -w ctr-smc-strg-cx68-3 \
  --cpus-per-task=20 --mem=64G -t 120 \
  scripts/test/run-vm-nvme.sh
```

Useful options while debugging: `--no-test` stops after provisioning and the
source copy, `--keep` leaves the stack up, `--skip-gpu` gives a build-only
smoke run, `--vcpus`/`--vmem` dial the guest down to the CI shape (4 vCPU,
8192 MiB) when reproducing a CI failure, and `--trace` selects QEMU trace
events.

### Tracing the emulated devices

The trace is the only view of what the emulated NVMe controller and the
pci-mmio-bridge actually saw, and it is usually the fastest way to tell a lost
doorbell from a kernel that never issued one:

```bash
srun ... scripts/test/run-vm-nvme.sh --trace all
```

`--trace` takes `doorbell` (the default, two events), `all` (every `pci_nvme*`
event), or any literal event name or glob. The `pci_mmio_bridge_*` events are
always enabled because `qemu-tool --pci-mmio-bridge` turns them on by itself.
Output is collected to `<workdir>/qemu-trace.log` alongside the other
diagnostics, and the script prints an event histogram and a count of
I/O-queue doorbells at the end of the run.

Read the histogram before anything else, and read it by queue id. The guest's
own nvme driver rings doorbells constantly on its per-CPU I/O queues, so a
large `doorbell_sq` count proves nothing by itself. What matters is whether
there is a doorbell on the queue the tester is driving, which it prints at
startup ("Using queue ID 8"):

```bash
grep -c 'doorbell_sq sqid 8' <workdir>/qemu-trace.log
```

For the bridge, the three startup events `pci_mmio_bridge_init`, `_realize`
and `_reset` always appear and mean nothing beyond the device existing. Only
`pci_mmio_bridge_poll_processed` and `pci_mmio_bridge_write` show it doing
work. Nothing past the startup three means the GPU's stores never reached the
shadow window at all; a `_write_failed`, `_device_not_found` or `_invalid_bar`
means they reached it and could not be replayed.

### How the bridge actually works

`pci-mmio-bridge` is a device-to-device MMIO proxy (QEMU vendor `0x1b36`,
device `0x0015`), not a topological PCI parent. The emulated NVMe controller
sits at `00:02.0` on the root bus and the bridge at `00:08.0`. It does not
snoop the NVMe BAR: QEMU instantiates it with
`shadow-gpa=0x80000000,shadow-size=8192,poll-interval-ns=1000000`, so it polls
an 8 KiB window of guest RAM every millisecond and replays what it finds there
as MMIO. Enabling it also forces `ioeventfd=off,dbcs=off` on the NVMe device.

On the rocm-xio side, `/dev/rocm-xio` reads the shadow GPA out of the bridge's
PCI config space, `mmap`s it, and `hipHostRegister`s it so `__device__` code can
write command descriptors into it. The kernel module is therefore mandatory for
this path — without it the tester fails with "Failed to map PCI MMIO bridge
shadow buffer", and without the bridge it fails to create an I/O queue at all.

### VM Gotchas

- **Slurm kills the containers when the job ends.** Docker compose stacks do
  not survive `srun` exit on these nodes, so `--keep` plus a fixed `--ssh-port`
  does not let a later allocation ssh into the guest. Interactive debugging has
  to happen inside a single `srun`. A container that vanished with
  `Exited (137)` shortly after its allocation ended was reaped this way, not
  OOM-killed.
- **`/tmp` is not shared between the login node and the compute node.** A
  script to be run under `srun` must live under `/home/AMD/<user>/`, and
  diagnostics written to the node's `/tmp` need a second `srun` on the same
  node to read them.
- **`--nvme-trace-file` is a no-op.** This QEMU is not built with the simple
  trace backend, so `-trace file=` is accepted, silently does nothing, and the
  file never appears — which reads exactly like tracing being off. The events
  go to the qemu container's stderr instead.
- The guest installs ROCm from the therock stream, whose layout is
  `/opt/rocm/<component>-<version>` (for example `/opt/rocm/core-10.0`) rather
  than a versioned root with a `/opt/rocm` symlink. Nothing puts
  `${ROCM_PATH}/bin` on `PATH`, so CMake reports "Failed to find ROCm root
  directory" no matter what `-DROCM_PATH` says until you export it yourself.
- The `nvme-ep` ctests pin `USE_PCI_MMIO_BRIDGE=0` in their `ENVIRONMENT`
  property for hardware runs. ctest's `ENVIRONMENT` adds to the inherited
  environment rather than replacing it, so an exported `USE_PCI_MMIO_BRIDGE=1`
  cannot win — a differently named variable can, which is why
  `XIO_FORCE_PCI_MMIO_BRIDGE=1` exists and why `vm-guest-test.sh` sets it.
- Every image is pinned to a dated tag in the compose file and the workflow.
  Do not use `:latest`: a silent retag upstream turns a green run red with no
  diff to point at.

### Known-bad state

Device-touching `nvme-ep` tests currently hang under the VM rather than fail.
A backtrace of a hung `xio-tester` shows the host parked in
`hipDeviceSynchronize()` from `xio::syncHipKernel()` at
`src/common/xio-common.hip:168`: the GPU kernel launches and never completes,
so host-side queue setup, the shadow-buffer mapping and buffer allocation have
all succeeded by that point. Given a 600 second budget it makes no progress at
all, so it is stuck rather than merely slow under emulation. No doorbell on the
tester's queue ever reaches QEMU and the bridge logs nothing past its three
startup events, with or without `--pci-mmio-bridge`. Because
`hipDeviceSynchronize()` has no timeout,
ctest reports these as timeouts rather than failures — a wall of consecutive
timeouts with zero failures is this bug, not a flaky runner. Note also that the
default `-m 0` reports `Doorbell: host`, so a run left at the default may not
be exercising the GPU doorbell path at all.

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
