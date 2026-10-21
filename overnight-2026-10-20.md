# Overnight session — 2026-10-20

## Goal

Get PR #220 (`feat/nvme-kv-ernic-rocjitsu`) green:
- Fix build errors in `nvme-ep.hip` (merge artifact — duplicate PRP block)
- Validate LBA NVMe path via `rocjitsu-nvme-vm` compose (qemu-tool run-vm + --nvme 1)
- Validate SPDK KV path via `spdk-kv-nvme-vm` compose (SPDK + rocjitsu + --pci-mmio-bridge)
- Add/expand CI workflows for both paths

User instructions:
- Use `qemu-tool compose` for VM setup
- Cover both LBA NVMe and SPDK NVMe KV
- Add more CI where possible

## State at session start

### PR #220 CI (on branch `feat/nvme-kv-ernic-rocjitsu`)
- build-check (default, gfx1010, gfx1101): **FAIL** — compile error in nvme-ep.hip ~L1898
- CTest (no hardware): **FAIL**
- Build .deb: **FAIL**
- library without libcli11-dev: **FAIL**
- test-emulate: **FAIL**
- VM tests (nvme-ep LBA, KV, rdma-ep, sdma-ep): **pending**

### Root cause of compile failure
Duplicate code block in `nvme-ep.hip` around L1856-1898 (merge artifact):
- First PRP block (L1856-1877): scoped `prpSlot`, `prpDma`, `sqeLocal`, `lbas_op`, `lba` inside `if (has_buf)` brace
- Second PRP block (L1880-1896): re-declares `prpSlot`/`prpDma` outside the if-block
- `sqeSetup(&sqeLocal, lba, lbas_op)` at L1898 references names that fell out of scope after the first block

### Compose stacks
- `rocjitsu-nvme-vm`: rocjitsu GPU + QEMU (--nvme 1) — LBA path, no SPDK
- `spdk-kv-nvme-vm`: SPDK + rocjitsu + QEMU (--vfio-userdev + --pci-mmio-bridge) — KV path
- `ernic-rdma-vm`: rocm-ernic + QEMU — RDMA path

## Work log

### [start] Read context, identified build failure root cause

### [fix] Resolved compile error in nvme-ep.hip (merge artifact)

Root cause: two PRP setup blocks back-to-back in the submit loop for the
work-ring kernel path (gpuKernelWorkRing or similar). The first block (old
pool-only path) scoped `prpSlot`, `prpDma`, `sqeLocal`, `lba`, `lbas_op`
inside `if (has_buf)`. The second block (new prefill-aware path from the
fix/fio-dockerfile merge) re-declared `prpSlot`/`prpDma` outside the if,
then referenced `base_addr`, `phys_addrs`, etc. that were out of scope.
Additionally, `sqeSetup`/`sqeWrite` were placed outside the for-loop, and
`sq_tail` had wrong indentation causing it to be outside the loop body too.

Fix: merged both PRP blocks into the prefill-aware version (supports both
pre-populated and GPU-written PRP lists), moved `sqeSetup`/`sqeWrite`/
`sq_tail` back inside the per-SQE for-loop, added the missing closing `}`.

Full build passes (no errors, only pre-existing nodiscard warnings).
CTest no-hardware suite: pending push + CI run.

### [fix] Composite action compose paths (all three VM actions)

`github.action_path` in composite action output values doesn't resolve
to a usable absolute path when the output is consumed by a caller
workflow's `working-directory`. The CI error was:

  working directory '/../../compose/rocjitsu-nvme-vm'. No such file or directory

Fix: replace `${{ github.action_path }}/../../compose/<name>` with
`${{ github.workspace }}/.github/compose/<name>` in all three actions:
- `.github/actions/rocjitsu-nvme-vm/action.yml`
- `.github/actions/spdk-kv-nvme-vm/action.yml`
- `.github/actions/ernic-rdma-vm/action.yml`

### [investigation] Local VM testing with qemu-tool compose

Brought up `rocjitsu-nvme-vm` compose stack locally. Found:

**Root issue: guest network not configured**
The `enp0s3` (virtio-net) interface was DOWN with no IP. QEMU's SLIRP
hostfwd accepts TCP connections but cannot forward to the guest over an
unconfigured network, so SSH banner exchange hung indefinitely.

Fix applied via guest agent:
```
ip link set enp0s3 up
ip addr add 10.0.2.15/24 dev enp0s3
ip route add default via 10.0.2.2
```

This needs to be addressed in the image or the vm-provision.sh playbook
so it's handled automatically before SSH is attempted.

After fixing network: SSH works, GPU (rocjitsu gfx1250) and /dev/nvme0n1
present in guest.

**NVMe LBA test running**: `vm-guest-test-nvme.sh` launched, pending result.

### [investigation] amdgpu PSP firmware failure with old images

With the Oct 16 QCOW2 image + Oct 20 rocjitsu image, `modprobe amdgpu
ip_block_mask=0x7f` fails:

  psp reg (0x16280) wait timed out
  Failed to wait for trust OS ready for ring creation
  amdgpu 0000:00:06.0: hw_init of IP block <psp> failed -22

Root cause: Oct 20 rocjitsu image does not fully emulate PSP ring
creation for gfx1250. amdgpu-probe also missing from image.

### [fix] Bump to Oct 21 images

Newer rocjitsu and QEMU images were published Oct 21 01:35 UTC.
Updated pins in all four VM test workflows and compose .env:

  ROCJITSU_IMAGE: ...rocjitsu:20261021.g0f1f43f-rocjitsu.84fb06b
  QEMU_IMAGE:     ...sbates-fork:20261021.g0f1f43f-qemu.aa4344e-vfu.8039244

Restart of rocjitsu-nvme-vm compose stack with new images: SSH
connects, provisioning succeeds.

### [blocker] rocjitsu PSP emulation incomplete — GFX cannot initialize

With rocjitsu.84fb06b (both Oct 20 and Oct 21 builds), loading amdgpu
fails in two distinct ways:

- `ip_block_mask=0x7f`: PSP ring creation times out in psp_v15_0_8
- `ip_block_mask=0x77` (PSP disabled): GFX/SDMA hang indefinitely
  because PSP is needed to load firmware for GFX; modprobe never returns

The KFD node 0 (CPU) appears but KFD node 1 (GPU) never registers.
rocminfo/HIP sees no devices.

**Root cause**: rocjitsu.84fb06b does not implement the PSP ring
protocol needed by psp_v15_0_8 (gfx1250 / MI455X). The GPU emulation
path for IP discovery table injection works, but firmware loading via
the PSP ring does not.

**Resolution needed**: a newer rocjitsu build with working PSP ring
emulation. The user noted "updated images coming soon" — this is the
one that will unblock GPU-initiated NVMe testing.

**What WAS confirmed working**:
- rocjitsu GPU appears on PCI bus in guest (00:06.0 AMD 0x75c1)
- QEMU emulated NVMe disk /dev/nvme0n1 present
- Guest networking (SLIRP) works after ip/resolvectl setup
- SSH access works after SLIRP network bringup
- Ansible provisioning succeeds (firmware, libnuma-dev, amdgpu-probe)
- The nvme-ep.hip compile fix passes local builds

### [fix] HIP linker OOM in VM

`cmake --build --parallel $(nproc)` with 4 vCPUs and 8 GiB RAM causes
`ld.lld` to abort (SIGABRT/core dump) during the HIP device-code link.
Each link job consumes ~3-4 GiB. Fix: cap build jobs at 2 in
`scripts/test/vm-guest-test-common.sh:build_xio_tester`.

Confirmed from CI log run 39531296378:
  `clang: error: ld.lld command failed with exit code -2 (core dumped)`
  `/opt/rocm/core-10.1/lib/llvm/bin/clang-linker-wrapper: error: 'clang' failed`

### [fix] amdgpu-probe provision task

Added "Install amdgpu-probe wrapper if absent" task to
`scripts/test/ansible/vm-rocjitsu-nvme.yml` so the gpu_bringup()
function in vm-guest-test-common.sh works regardless of QCOW2 image
version. Uses `force: false` so existing image-shipped scripts take
precedence.
