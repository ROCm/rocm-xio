# rocm-xio KV local debug setup

Written for: Stephen, morning of 2026-09-22.

## Image tags (pinned)

| Role | Image |
|------|-------|
| SPDK NVMe KV server | `sbates130272/batesste-ci-images-ubuntu-spdk-libvfio-user:20260917.g857483b-spdk.18d1d8d` |
| QEMU (sbates fork, has pci-mmio-bridge) | `sbates130272/batesste-ci-images-ubuntu-qemu-libvfio-user-sbates-fork:20260918.g7438e48-qemu.7794baa-vfu.8039244` |
| rocjitsu GPU server | `sbates130272/batesste-ci-images-ubuntu-rocm-rocjitsu:20260921.gb3399b3-rocjitsu.8e01a5a` |
| Firmware source (old, has full gfx1250 blobs) | `sbates130272/batesste-ci-images-ubuntu-rocm-rocjitsu:20260918.g7438e48-rocjitsu.20d4ce1` |
| Guest disk (qcow2 container format) | `sbates130272/batesste-ci-images-ubuntu-qcow2-gen-rocjitsu:20260918.g7438e48-vm.resolute-rocjitsu-qm.5d68689` |

## 1. Extract the guest disk (one-time)

The qcow2 image is an OCI container with the disk and SSH key in `/output/`.
Pull and extract:

```bash
QCOW2_IMAGE=docker.io/sbates130272/batesste-ci-images-ubuntu-qcow2-gen-rocjitsu:20260918.g7438e48-vm.resolute-rocjitsu-qm.5d68689
IMAGES_DIR=/var/lib/qemu-tool/images

docker pull "$QCOW2_IMAGE"
sudo mkdir -p "$IMAGES_DIR" && sudo chmod 777 "$IMAGES_DIR"

cid=$(docker create "$QCOW2_IMAGE")
docker cp "$cid:/output/." "$IMAGES_DIR"
docker rm -f "$cid"

chmod 600 "$IMAGES_DIR/id_rsa"
python3 -c 'import json; d=json.load(open("/var/lib/qemu-tool/images/vm-info.json")); print("vm_name:", d["vm_name"], "user:", d["username"])'
# -> vm_name: batesste-ci-vm  user: batesste
```

## 2. Write the compose .env

```bash
cat > ~/Projects/rocm-xio/.github/compose/spdk-kv-nvme-vm/.env << 'EOF'
SPDK_IMAGE=docker.io/sbates130272/batesste-ci-images-ubuntu-spdk-libvfio-user:20260917.g857483b-spdk.18d1d8d
NVME_NAMESPACES=kv:mem
QEMU_IMAGE=docker.io/sbates130272/batesste-ci-images-ubuntu-qemu-libvfio-user-sbates-fork:20260918.g7438e48-qemu.7794baa-vfu.8039244
ROCJITSU_IMAGE=docker.io/sbates130272/batesste-ci-images-ubuntu-rocm-rocjitsu:20260921.gb3399b3-rocjitsu.8e01a5a
ROCJITSU_CONFIG=gfx1250_mi455x.json
VM_IMAGES_DIR=/var/lib/qemu-tool/images
VM_NAME=batesste-ci-vm
VM_VCPUS=4
VM_VMEM=8192
VM_SHM_SIZE=12g
VM_SSH_PORT=2222
VM_NVME_TRACE=doorbell
EOF
```

## 3. Bring up the stack

```bash
cd ~/Projects/rocm-xio

# Down any existing stack first:
docker compose -f .github/compose/spdk-kv-nvme-vm/docker-compose.yml \
  --env-file .github/compose/spdk-kv-nvme-vm/.env down 2>/dev/null || true

# Pull fresh images:
docker pull docker.io/sbates130272/batesste-ci-images-ubuntu-rocm-rocjitsu:20260921.gb3399b3-rocjitsu.8e01a5a

# Start (waits for rocjitsu + SPDK to be healthy before starting QEMU):
docker compose -f .github/compose/spdk-kv-nvme-vm/docker-compose.yml \
  --env-file .github/compose/spdk-kv-nvme-vm/.env up --detach

# Wait for the VM to accept SSH (~60 s):
for i in $(seq 1 40); do
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
    -i /var/lib/qemu-tool/images/id_rsa -p 2222 \
    batesste@localhost "echo ready" 2>/dev/null && break
  sleep 5
done
```

## 4. Provision the guest (GPU firmware + amdgpu module)

```bash
SSH_OPTS="-o StrictHostKeyChecking=no -i /var/lib/qemu-tool/images/id_rsa -p 2222"
FIRMWARE_IMAGE=docker.io/sbates130272/batesste-ci-images-ubuntu-rocm-rocjitsu:20260918.g7438e48-rocjitsu.20d4ce1

# Extract firmware blobs (use old image — it has the full gfx1250 set):
FWDIR=$(mktemp -d)
docker run --rm -v "$FWDIR:/out" "$FIRMWARE_IMAGE" \
  python3 /usr/local/bin/vfio_guest_firmware.py --output /out

# Get ip_discovery.bin from the NEW rocjitsu (must match the running server):
docker run --rm -v "$FWDIR:/out" \
  docker.io/sbates130272/batesste-ci-images-ubuntu-rocm-rocjitsu:20260921.gb3399b3-rocjitsu.8e01a5a \
  python3 /usr/local/bin/vfio_guest_firmware.py --output /out

echo "Firmware files: $(ls $FWDIR | tr '\n' ' ')"

# Install in guest:
scp $SSH_OPTS "$FWDIR"/*.bin batesste@localhost:/tmp/
rm -rf "$FWDIR"

ssh $SSH_OPTS batesste@localhost << 'GUEST'
sudo mkdir -p /lib/firmware/amdgpu
sudo cp /tmp/gc_12_1_0*.bin /tmp/sdma_7_1_0.bin /tmp/ip_discovery.bin /lib/firmware/amdgpu/
echo 'blacklist amdgpu' | sudo tee /etc/modprobe.d/amdgpu-blacklist.conf > /dev/null
sudo modprobe -r amdgpu 2>/dev/null || true
sudo modprobe amdgpu emu_mode=1 fw_load_type=0 discovery=2 \
  ip_block_mask=0x3f vm_update_mode=3 gpu_recovery=0 vramlimit=256
sleep 3
ls /dev/kfd && echo "GPU ready"
GUEST
```

## 5. Build and load kernel module

```bash
ssh $SSH_OPTS batesste@localhost << 'GUEST'
# Sync source first if not done:
# (from host: rsync -a --exclude='.git' --exclude='build' ... batesste@localhost:~/rocm-xio/)
cd ~/rocm-xio
sudo insmod kernel/rocm-xio/rocm-xio.ko 2>/dev/null || \
  (make -C kernel/rocm-xio -s && sudo insmod kernel/rocm-xio/rocm-xio.ko)
lsmod | grep rocm_xio
GUEST
```

## 6. Build xio-tester

```bash
ssh $SSH_OPTS batesste@localhost << 'GUEST'
cd ~/rocm-xio
cmake -S . -B build \
  -DCMAKE_HIP_COMPILER=/opt/rocm/core-10.0/bin/amdclang++ \
  -DCMAKE_HIP_ARCHITECTURES=gfx1250 \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_FLAGS='-O1' -DCMAKE_CXX_FLAGS='-O1' -DCMAKE_HIP_FLAGS='-O1' \
  -DROCM_PATH=/opt/rocm/core-10.0 -Wno-dev -DBUILD_TESTING=ON 2>&1 | tail -3
cmake --build build --target xio-tester -j4 2>&1 | tail -3
GUEST
```

**Note**: The local amdclang (ROCm core-10.0 in this qcow2) crashes with SIGILL when
compiling the current `xio-common.hip` for gfx1250. If you see `Illegal instruction`,
revert `src/common/xio-common.hip` to the last working commit before testing locally.
The CI uses a different toolchain that doesn't have this bug.

## 7. Run a single KV Store test (verbose)

```bash
KV_NSID=$(docker logs spdk-kv-nvme-vm-spdk-nvme-1 2>&1 | grep "nsid map:" | awk '{print $NF}' | cut -d= -f1)
echo "KV NSID: $KV_NSID"

ssh $SSH_OPTS batesste@localhost \
  "sudo ROCM_PATH=/opt/rocm/core-10.0 ROCXIO_LOG_LEVEL=3 \
   timeout --kill-after=5 30 ~/rocm-xio/build/xio-tester nvme-ep \
   --controller /dev/nvme0 --namespace $KV_NSID \
   --kv-op store --key testkey0 \
   --write-io 1 --batch-size 1 \
   --value-size 4096 --data-buffer-size 4096 \
   --pci-mmio-bridge 2>&1"
```

## 8. Monitor the shadow buffer (run while test is executing)

```bash
ssh $SSH_OPTS batesste@localhost "sudo python3 -c \"
import struct, fcntl, mmap, os, time
IOWR = 0xc018520a
fd = os.open('/dev/rocm-xio', os.O_RDWR)
buf = bytearray(struct.pack('=IIqq', 0x40, 0, 0, 0))
fcntl.ioctl(fd, IOWR, buf)
_, _, gpa, sz = struct.unpack('=IIqq', buf)
addr = mmap.mmap(fd, sz, mmap.MAP_SHARED, mmap.PROT_READ)
for _ in range(10):
    addr.seek(0); meta = addr.read(16)
    p, c, q, _ = struct.unpack('<IIII', meta)
    # First command slot at offset 16
    addr.seek(16); raw = addr.read(24)
    cmd_byte = raw[16]  # command field offset in packed struct
    print(f't={time.time():.1f} producer={p} consumer={c} queue_depth={q} cmd[0]={cmd_byte}')
    time.sleep(1)
addr.close(); os.close(fd)
\""
```

**Expected good output**: `producer` increments, `cmd[0]=1` (PCI_MMIO_BRIDGE_CMD_WRITE).  
**Current bug**: `cmd[0]=0` — `genPciMmioBridgeCmd` struct not written to host memory.

## 9. Validate data reached SPDK (host-side)

After a successful store, confirm SPDK actually holds the key:

```bash
docker exec spdk-kv-nvme-vm-spdk-nvme-1 \
  rpc.py kvdev_mem_get_entry KvMem0 testkey0
# -> {"code": 0, "message": "Success", "value": "...base64..."}
# Any non-zero code = the KV command did not reach SPDK or returned an error
```

Or use the convenience script for the data-integrity test keys:

```bash
SPDK_CONTAINER=spdk-kv-nvme-vm-spdk-nvme-1 \
  ./scripts/test/spdk-kv-check.sh kvverify0 kvverify1 kvverify2 kvverify3
```

## 10. Run the full KV ctest suite

```bash
ssh $SSH_OPTS batesste@localhost "sudo \
  ROCXIO_NVME_KV_CTRL=/dev/nvme0 \
  ROCXIO_NVME_KV_NSID=$KV_NSID \
  XIO_FORCE_PCI_MMIO_BRIDGE=1 \
  HSA_FORCE_FINE_GRAIN_PCIE=1 \
  timeout --kill-after=30 1000 \
  ctest --test-dir ~/rocm-xio/build \
        --label-regex kv \
        --output-on-failure \
        --no-tests=error 2>&1"
```

## 11. QEMU tracing

The compose file passes `--nvme-trace doorbell` to `qemu-tool`, which translates to
three `-trace` flags on the `qemu-system-x86_64` command line:

```
-trace enable=pci_nvme_mmio_doorbell_sq
-trace enable=pci_nvme_mmio_doorbell_cq
-trace enable=pci_mmio_*
```

Trace output goes to QEMU stderr → captured by Docker → visible via `docker logs`.

### Live trace stream

```bash
# Follow QEMU trace output in real time:
docker logs -f spdk-kv-nvme-vm-qemu-1 2>&1 | grep -v "^\[" | grep -v "^$"

# Filter to just NVMe doorbell and pci-mmio-bridge events:
docker logs -f spdk-kv-nvme-vm-qemu-1 2>&1 | \
  grep -E "pci_nvme_mmio_doorbell|pci_mmio_bridge"
```

### What to look for

| Trace line | Meaning |
|-----------|---------|
| `pci_mmio_bridge_poll_processed processed N commands` | QEMU consumed N commands from the shadow buffer ring |
| `pci_mmio_bridge_invalid_command invalid command=0` | **Bug** — command field is 0 (should be 1 = CMD_WRITE) |
| `pci_nvme_mmio_doorbell_sq nsid=1 new_tail=1` | QEMU forwarded an SQ doorbell write to SPDK — **this is what we need** |
| `pci_nvme_mmio_doorbell_cq nsid=1 new_head=1` | QEMU forwarded a CQ head doorbell (completion consumed) |

### Current state

```
pci_mmio_bridge_invalid_command invalid command=0  ← all 42 commands are invalid
pci_mmio_bridge_poll_processed processed 42 commands
```

No `pci_nvme_mmio_doorbell_sq` lines appear, which confirms QEMU never forwards
the doorbell to SPDK because the command type is 0 (invalid).

Once `genPciMmioBridgeCmd` is fixed to write `command=1`, you should see:

```
pci_mmio_bridge_poll_processed processed 1 commands
pci_nvme_mmio_doorbell_sq nsid=1 new_tail=1
```

followed by SPDK processing the KV Store and returning a CQE.

### Increase trace verbosity

To capture all NVMe events (expensive but complete), change `VM_NVME_TRACE` in `.env`:

```bash
# In .env:
VM_NVME_TRACE=all
# Then restart: docker compose ... down && up
```

This adds `-trace enable=pci_nvme_*` which logs every NVMe register access.

## Current debug state (2026-09-22)

**What works:**
- Stack boots, SPDK serves KV namespace, rocjitsu GPU attaches
- Shadow buffer is mapped and `hipHostRegister` succeeds (new rocjitsu fixed this)
- Shadow buffer CPU VA override: GPU kernel writes reach the mmap (`producer_idx` increments)
- `pci_mmio_bridge_poll_processed processed 42 commands` — QEMU receives commands

**Remaining bug:**
- QEMU sees `pci_mmio_bridge_invalid_command invalid command=0`
- The `command` field in every slot is 0 instead of 1 (`PCI_MMIO_BRIDGE_CMD_WRITE`)
- Root cause: `genPciMmioBridgeCmd` builds a local struct then passes `&cmd` to
  `XioComEnqueue`. On gfx1250-compiled code running as CPU (rocjitsu), the struct
  may not be materialised to host-addressable memory — the gfx1250 backend keeps it
  in GPU registers, so `XioComEnqueue`'s `uint64_t*` cast reads uninitialized bytes.

**Fix direction:**
- Mark `genPciMmioBridgeCmd` as `__host__`-only (remove `__device__`) and call it
  through a `__host__`-only trampoline from the GPU kernel path on rocjitsu.
- Or: add a call to `__attribute__((noinline))` helper that forces the struct to stack.
- The direct volatile-write approach and uint64_t-array approaches crash amdclang-23
  when compiling for gfx1250 target (compiler bug in this toolchain version).
