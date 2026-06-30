# rocm-xio NVMe-KV Reproduction (Ceph + SPDK + QEMU fork)

A single self-contained container image that reproduces the rocm-xio NVMe
**Key-Value** result: a GPU-driven NVMe KV store/retrieve round-trip whose
backing store is Ceph RADOS, served to the guest through SPDK's `kvdev_rados`
namespace over a `vfio-user` socket.

The whole host-side stack (Ceph, SPDK `nvmf_tgt`, the QEMU launcher) and the
guest VM run **inside the container**; you reach the guest over SSH.

```
                          [ container ]
 guest /dev/nvme0 (KV)                                Ceph
   |   KV store/retrieve                              (RADOS)
   v                                                    ^
 QEMU vfio-user-pci client  --- vfio-user socket --->  SPDK nvmf_tgt
   |   (qemu fork)                                      + kvdev_rados
   |  GPU rings the NVMe doorbells via pci-mmio-bridge
   |  KV value lands in VRAM via P2PDMA (vram-dev/BAR)
   v
 GPU + real NVMe, passed through to the guest via VFIO
```

The image builds SPDK (`mmgaggle/spdk@rados-nkv`) and the QEMU fork
(carrying `pci-mmio-bridge` + client-side `vfio-user-pci`) from source, and uses
packaged Ceph.

`entrypoint.sh` dispatches one **stage** per `docker run`:

| Stage | Devices needed | What it does |
|---|---|---|
| `selftest` | `--privileged` + `/data` | KV store/retrieve/delete round-trip through Ceph+SPDK; no VM, no GPU |
| `build-vm` | `/dev/kvm` | builds the guest qcow (rocm-xio @ nvme-kv + kmod), cached |
| `serve` | `/dev/kvm` + GPU + NVMe via VFIO | boots the guest with KV NVMe + GPU passthrough, blocks |
| `gpu-e2e` | (talks to a running `serve`) | runs the rocm-xio ctest suite in the guest |
| `gpu-e2e-wavefront` | (talks to a running `serve`) | optional: batched/wavefront multi-key KV store+retrieve (incl. VRAM) + RADOS verify |
| `cleanup` | none | kills only the pids this container started |
| `shell` | none | drops to a shell with Ceph already up (debugging) |

To confirm only the KV data path without any hardware, run **selftest** and stop.

---

## 0. Quick start

Condensed commands to build and start the container. Replace every
`<...>` placeholder with your host's values. Explained in detail in
sections 1-11.

**Host prep (one-time):**

```bash
sudo modprobe vfio-pci
sudo driverctl set-override <your GPU VGA BDF> vfio-pci
sudo driverctl set-override <your GPU audio BDF> vfio-pci
sudo driverctl set-override <your NVMe BDF> vfio-pci

# Find each device's /dev/vfio/<N> group node
for bdf in <your GPU VGA BDF> <your GPU audio BDF> <your NVMe BDF>; do
  echo "$bdf -> $(basename "$(readlink -f /sys/bus/pci/devices/$bdf/iommu_group)")"
done

export DATA_DIR="$HOME/.local/share/rocm-xio-kv"
mkdir -p "$DATA_DIR"
```

**1. Build the image:**

```bash
docker build -t rocm-xio-kv-ceph:dev docker/rocm-xio-kv-ceph
```

**2. Selftest — device-free KV round-trip:**

```bash
docker run --rm -it --privileged -v "$DATA_DIR":/data \
  rocm-xio-kv-ceph:dev selftest
```

Pass = `kv_rados_vfio_user: PASS` (log at `$DATA_DIR/log/selftest.log`).

**3. Build the guest qcow:**

```bash
docker run --rm -it \
  --device /dev/kvm --group-add kvm \
  -v "$DATA_DIR":/data -v "$HOME/.ssh":/root/.ssh:ro \
  -e GPU_ARCH=<your GPU arch> \
  -e NVME_BDF=<your NVMe BDF> \
  rocm-xio-kv-ceph:dev build-vm
```

**4. Serve — boot the VM with GPU + NVMe passthrough (blocks; leave running):**

```bash
docker run --rm -it --name kv-serve --privileged \
  --device /dev/kvm --device /dev/vfio/vfio \
  --device /dev/vfio/<your GPU VGA group N> \
  --device /dev/vfio/<your GPU audio group N> \
  --device /dev/vfio/<your NVMe group N> \
  --group-add kvm --cap-add IPC_LOCK \
  -p 2223:2223 \
  -v "$DATA_DIR":/data -v "$HOME/.ssh":/root/.ssh:ro \
  -e GPU_BDFS=<your GPU VGA BDF>,<your GPU audio BDF> \
  -e NVME_BDF=<your NVMe BDF> \
  -e ROCXIO_NVME_DEVICE=<your NVMe by-id path> \
  -e GPU_ARCH=<your GPU arch> \
  rocm-xio-kv-ceph:dev serve
```

**5. Run the test suite (new terminal, same container):**

```bash
docker exec -it kv-serve /opt/kv/entrypoint.sh gpu-e2e
```

Log: `$DATA_DIR/log/gpu-e2e.log`.

**Teardown:**

```bash
docker exec -it kv-serve /opt/kv/entrypoint.sh cleanup
# then Ctrl-C the serve terminal
```

---

## 1. What you must set for YOUR host

The GPU E2E passes through real devices, so these have **no defaults** — the
container fails loudly until you set them (`selftest` needs none of them):

| Variable | Meaning |
|---|---|
| `GPU_BDFS` | GPU VGA + audio function BDFs, comma-separated (e.g. `0000:0c:00.0,0000:0c:00.1`) |
| `NVME_BDF` | spare NVMe BDF to pass through — **never your root disk** |
| `ROCXIO_NVME_DEVICE` | the guest by-id path of that NVMe (`/dev/disk/by-id/nvme-<model>_<serial>`) |

Other host-shaped knobs with sane defaults: `VRAM_DEV_INDEX` (1-based index into
`PCI_HOSTDEV`, which is built as `NVME_BDF,GPU_BDFS`, so `2` = GPU VGA function;
order-sensitive, required for the device-mem tests), `SSH_PORT`, `VCPUS`,
`VMEM`. All tunables are documented in `.env.example`.

---

## 2. Prerequisites (HOST)

- Docker, with your user in the `docker` and `kvm` groups.
- `/dev/kvm` present.
- For the GPU E2E: an AMD GPU and a spare NVMe SSD, both bound to `vfio-pci`
  **before** you run the container. The container never rebinds host drivers.

### Bind the GPU and NVMe to vfio-pci

Use your own BDFs.

```bash
sudo modprobe vfio-pci
sudo driverctl set-override 0000:0c:00.0 vfio-pci   # GPU VGA function
sudo driverctl set-override 0000:0c:00.1 vfio-pci   # GPU audio function
sudo driverctl set-override 0000:04:00.0 vfio-pci   # spare NVMe
```

### Find each device's /dev/vfio/<N> group number

The container needs each device's VFIO group node passed in explicitly:

```bash
for bdf in 0000:0c:00.0 0000:0c:00.1 0000:04:00.0; do
  echo "$bdf -> $(basename "$(readlink -f /sys/bus/pci/devices/$bdf/iommu_group)")"
done
```

Each printed number `N` is a `/dev/vfio/N` node you pass on `docker run`.

### Host data directory

A single host dir is bind-mounted to `/data` in every stage (cached guest image,
logs, Ceph state, runtime sockets):

```bash
export DATA_DIR="$HOME/.local/share/rocm-xio-kv"
mkdir -p "$DATA_DIR"
```

---

## 3. Build the image

```bash
docker build -t rocm-xio-kv-ceph:dev docker/rocm-xio-kv-ceph
```

This compiles SPDK and the QEMU fork from source plus pulls packaged Ceph
(~4–30 min). Override a source pin with `--build-arg` (see the `ARG` lines in the
`Dockerfile`).

> **The default QEMU C fork is Stephen Bates' upstream
> `sbates130272/qemu@dev/stephen/pci-mmio-bridge-submit`.
>
> ```bash
> docker build -t rocm-xio-kv-ceph:dev \
>   docker/rocm-xio-kv-ceph
> ```

---

## 4. Selftest — device-free KV round-trip

The fastest proof of the KV data path. Brings up Ceph + SPDK + `kvdev_rados`
inside the container and does a real store / retrieve / delete. Needs
`--privileged` (SPDK/DPDK EAL) and `/data`.

```bash
docker run --rm -it --privileged \
  -v "$DATA_DIR":/data \
  rocm-xio-kv-ceph:dev selftest
```

A pass ends with `kv_rados_vfio_user: PASS`. Transcript:
`$DATA_DIR/log/selftest.log`.

---

## 5. Build the guest image

Clones the VM tooling + Ansible provisioning repo and runs `gen-vm` with Ansible
to produce the guest qcow (checks out `mmgaggle/rocm-xio@nvme-kv`, builds the
kmod). Needs `/dev/kvm` and an SSH key (generates an ephemeral one if you don't
mount `~/.ssh`).

Heavy: downloads a ~600 MB Ubuntu cloud image and runs a full Ansible play. The
result is cached at `$DATA_DIR/images/$VM_NAME.qcow2` and skipped on re-run
unless you pass `-e FORCE=1`.

The commands below include the **fork override** for the tuned launcher
(`run-vm-modified`).

```bash
docker run --rm -it \
  --device /dev/kvm --group-add kvm \
  -v "$DATA_DIR":/data \
  -v "$HOME/.ssh":/root/.ssh:ro \
  rocm-xio-kv-ceph:dev build-vm
```

Logs: `$DATA_DIR/log/gen-vm.log`. (`build-vm` does not claim the GPU or NVMe.)

---

## 6. Full GPU E2E

> **SAFETY:** this stage claims the **real GPU and NVMe** via VFIO. Confirm no
> other VM or process is using them. The NVMe must not be a mounted device —
> `guard.sh` refuses any NVMe whose namespace backs a mount.

### 6a. Start `serve`

Runs the guards, brings up Ceph + the SPDK KV target, ensures the guest qcow
exists, then launches the VM in the foreground (it blocks). Use **your**
`/dev/vfio/<N>` numbers and BDFs.

```bash
docker run --rm -it --name kv-serve \
  --privileged \
  --device /dev/kvm \
  --device /dev/vfio/vfio \
  --device /dev/vfio/22 \
  --device /dev/vfio/27 \
  --device /dev/vfio/28 \
  --group-add kvm --cap-add IPC_LOCK \
  -p 2223:2223 \
  -v "$DATA_DIR":/data \
  -v "$HOME/.ssh":/root/.ssh:ro \
  -e GPU_BDFS=0000:0c:00.0,0000:0c:00.1 \
  -e NVME_BDF=0000:04:00.0 \
  -e ROCXIO_NVME_DEVICE=/dev/disk/by-id/nvme-<model>_<serial> \
  rocm-xio-kv-ceph:dev serve
```

> `--privileged` is used because the in-container SPDK target's DPDK EAL wants
> it. If you can start the target without it, the passthrough itself needs only
> the `--device` flags + `--cap-add IPC_LOCK`.

Leave this terminal running (QEMU is in the foreground).

### 6b. Confirm the guest is up

```bash
ssh -p 2223 -o StrictHostKeyChecking=no ubuntu@localhost
ls -l /dev/nvme0   # the SPDK kvdev_rados KV namespace
```

### 6c. Run the test suite

With `serve` still running, drive `gpu-e2e` in the **same** container. It waits
for guest SSH, preflights provisioning (`~/src/rocm-xio`, `/dev/rocm-xio`, the
kmod), then runs the rocm-xio ctest suite over SSH.

```bash
docker exec -it kv-serve /opt/kv/entrypoint.sh gpu-e2e
```

Result + full ctest output: `$DATA_DIR/log/gpu-e2e.log`.

### 6d. (optional) Wavefront / batched multi-key KV

PR #177 added a cooperative multi-key KV path (`driveEndpointKvWavefront`): the
GPU writes B KV SQEs into the SQ, rings the doorbell **once**, and polls B
completions — exercising `--keys`, `--batch-size`, the PRP-list sizing, the
op-direction validation, and the torn-CQE fix end to end.

```bash
docker exec -it kv-serve /opt/kv/entrypoint.sh gpu-e2e-wavefront
```

It runs one batched Store of the manifest keys, a batched Retrieve into host
slots (`--memory-mode 0`), a batched Retrieve into VRAM (`--memory-mode 8`,
P2PDMA), then a per-key `rados stat`. Tunables (defaults in `.env.example`):
`KV_KEYS` (space-separated manifest, default `wfk0 wfk1 wfk2 wfk3`),
`KV_VALUE_SIZE` (default `4096`), `KV_BATCH` (default = number of keys).
The stage exits non-zero if any key is missing from RADOS. Result + tester
output: `$DATA_DIR/log/gpu-e2e-wavefront.log`.

---

## 7. Inside the VM — manual run

This is what `gpu-e2e` runs for you:

```bash
cd ~/src/rocm-xio
sudo env ROCXIO_NVME_DEVICE="$ROCXIO_NVME_DEVICE" \
         NVME_DEVICE="$ROCXIO_NVME_DEVICE" \
         USE_PCI_MMIO_BRIDGE=1 \
  ctest --test-dir build -LE rdma --output-on-failure
```

`ROCXIO_NVME_DEVICE` is exported in the guest by `/etc/profile.d/rocm-xio.sh`.

---

## 8. Volume layout

Everything persistent lives under `$DATA_DIR`, bind-mounted to `/data`:

```
$DATA_DIR/
  images/        cached guest qcow + the Ubuntu cloud image
  log/           per-stage logs (ceph-up, nvmf_tgt, gen-vm, selftest, gpu-e2e)
  ceph/          Ceph data dir
  run/           runtime sockets + pidfiles (cleanup kills only these pids)
```

---

## 9. Safety

- **`guard.sh`** (before every device-touching stage): refuses an `NVME_BDF`
  whose namespace backs a mounted device, refuses an already-bound `SSH_PORT`,
  and asserts `/dev/kvm` + `/dev/vfio/*` are present (printing the exact
  `--device` flags to add if not). It is recommended that you **update
  guard.sh to reject the BDFs of your OS drive**.
- **No host driver rebinds** — you bind the GPU/NVMe to `vfio-pci` yourself.
- **Devices only via explicit `--device`.**
- **Scoped teardown** — `kill_tracked` kills only the pids in `/data/run/*.pid`.

Tear down:

```bash
docker exec -it kv-serve /opt/kv/entrypoint.sh cleanup
# then Ctrl-C the serve terminal (or: docker rm -f kv-serve)
```

---

## 10. Forks this repro depends on

**private** fork, mount an SSH key (`-v "$HOME/.ssh":/root/.ssh:ro`) and use an
The defaults point at public HTTPS forks; no credentials needed. To use a
SSH remote URL.

- **QEMU C fork** (`QEMU_FORK_REMOTE`/`QEMU_FORK_REF`, **build-time
  `--build-arg`**): the image defaults to `sbates130272/qemu@dev/stephen/
  pci-mmio-bridge-submit`.
- **VM tooling** (`QEMU_MINIMAL_*`, `RUNVM_SCRIPT`, **runtime env**): the image
  defaults to upstream `sbates130272/qemu-minimal@main`, whose `run-vm` boots a VM
  but does not reach the full GPU pass.
- **Guest provisioning** (`ANSIBLE_*`): defaults to the **general-purpose
  minimal** branch
  `john00003/batesste-ansible@users/john00003/rocm-xio-kv-docker-minimal`, which
  carries the KV guest config (rocm-xio checkout, kmod build) with
  **no host-specific values** — `guest_gpu_arch` is required (set `GPU_ARCH`).
- **Packaged Ceph, not a source build.** SPDK links the system `librados`;
  mixing in a source-built Ceph broke `nvmf_tgt`.
- **SPDK fork**: mmgaggle/spdk@rados-nkv.

---

## 11. Troubleshooting

All stages log to `$DATA_DIR/log/<stage>.log`.

| Symptom | Where to look / fix |
|---|---|
| required var error | set `GPU_BDFS` / `NVME_BDF` / `ROCXIO_NVME_DEVICE` (section 1) |
| `build-vm` fails | `gen-vm.log` — Ansible clone/collection install or the `gen-vm` run |
| Ceph never ready | `ceph-up.log` — dies loudly if mon quorum / OSD / `active+clean` PGs time out |
| `nvmf_tgt` won't start | `nvmf_tgt.log` — usually missing `--privileged` (DPDK EAL) |
| vfio device node missing | the guard prints the exact `--device /dev/vfio/<N>` flags to add |
| guest SSH never comes up | `serve` terminal (QEMU console) + `gen-vm.log` |
| guest "not provisioned" | Ansible didn't land `~/src/rocm-xio` / `/dev/rocm-xio` / kmod — rebuild with `-e FORCE=1` |
| build-vm fails: "guest_gpu_arch is required" | minimal `ANSIBLE_BRANCH` needs `GPU_ARCH` set (e.g. `-e GPU_ARCH=gfx1030`); or switch to the author overlay branch |
| all nvme tests segfault | GPU code-object mismatch — set `GPU_ARCH` to your GPU and rebuild (`-e FORCE=1`) |
