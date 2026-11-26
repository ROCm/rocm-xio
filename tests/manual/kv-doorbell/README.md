# KV doorbell end-to-end tests

Minimal programs to isolate the pci-mmio-bridge → SPDK NVMe path.

## test1_cpu_doorbell.c — CPU-only ring write

Confirms the shadow buffer mmap works and QEMU picks up a CPU-written
doorbell command.  No HIP, no GPU.

```bash
# On guest:
gcc -O0 -o test1_cpu_doorbell test1_cpu_doorbell.c
sudo ./test1_cpu_doorbell

# On host while test runs:
docker logs spdk-kv-nvme-vm-qemu-1 2>&1 | grep -E "pci_mmio_bridge|pci_nvme_mmio"
```

Expected host output if working:
```
pci_mmio_bridge_poll_processed processed 1 commands
pci_nvme_mmio_doorbell_sq ...  new_tail=1
```

## test2_hip_doorbell.hip — HIP kernel ring write

Same as test1 but the write comes from a GPU kernel (running as CPU on
rocjitsu).  Passes the CPU mmap VA directly to the kernel rather than
the HIP GPU VA (which maps to different physical pages on rocjitsu).
Verifies that byte-by-byte volatile stores from device code reach QEMU.

```bash
# Build on guest:
/opt/rocm/core-10.0/bin/amdclang++ -O1 -std=c++17 \
  --offload-arch=gfx1250 -x hip \
  test2_hip_doorbell.hip -o test2_hip_doorbell \
  -I /opt/rocm/core-10.0/include \
  -L /opt/rocm/core-10.0/lib -lamdhip64

sudo ./test2_hip_doorbell
```

Expected: same QEMU trace as test1, plus the slot bytes read back
should show `command=1` (CMD_WRITE).

## Interpreting results

| test1 works | test2 works | Meaning |
|-------------|-------------|---------|
| yes | yes | GPU kernel can write doorbell — NVMe SQE path is next |
| yes | no  | GPU kernel byte stores don't reach the mmap — kernel VA/address issue |
| no  | n/a | Shadow buffer mmap broken — check rocm-xio kernel module |

After both pass, next step is test3 (not yet written): submit an actual
NVMe KV Store SQE from a HIP kernel and poll the CQ for a response.
