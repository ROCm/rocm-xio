# vfu-doorbell

A small vfio-user test rig for doorbell-style writes. It trims away
everything that is not the write: no GPU emulator, no HIP, no NVMe or NIC
model. Two tiny PCI devices and a guest tool are enough to push a chosen
value to a chosen guest physical address through the same libvfio-user and QEMU
call chain an emulated GPU uses, and to read back exactly what arrived.

| Piece | What it is |
|---|---|
| `vfu-doorbell --role ringee` | A vfio-user PCI device whose BAR0 carries doorbell **overlays**: byte ranges with a semantic model, a slot width and a stride. It decodes every write and keeps per-key state the guest can read. It is the thing being rung. |
| `vfu-doorbell --role ringer` | A vfio-user PCI device the guest programs to write a pattern of values to any guest physical address. It is the thing doing the ringing. |
| `xio-doorbell` | A guest userspace tool. It maps both BARs through sysfs, configures the overlays, rings from the CPU or through the ringer, and checks the ringee's counters. |

There is no guest kernel driver. Run `xio-doorbell` as root; it maps
`resource0` of each device and reads physical addresses with pagemap.

## What it tests, and what it does not

The write itself is not special: a doorbell is a write to a register. The rig
tests the delivery chain (`vfu_mmio_write` into QEMU's `vfio_user_dma_write`,
into the ringee's BAR callback) and, because the ringee models the register
semantics, how a doorbell interaction behaves under different write patterns:
bursts, several writers on one register, repeated or backwards values, mixed
sizes. It does not model a real GPU's hardware, only the two kinds of writer:

* **Trap-style**: one message per store, as an emulated GPU delivers it
  (`--shm` off, the default, uses `vfu_mmio_write`).
* **Memory-style**: a plain store into DMA-mapped guest memory (`--shm`), which
  reaches RAM only. Use it to model a real GPU writing a memory-backed
  doorbell that something later polls.

## Doorbell overlays

Each region of the ringee is one overlay. Slot `n` of a region starts at
`base + n * stride`; a write must be exactly `width` bytes on a slot boundary.

| Model | Value layout | Key | Resembles |
|---|---|---|---|
| `index` | queue position in bits [15:0] | slot | NVMe: width 4, stride 4; slot 2q is queue q's SQ tail, slot 2q+1 its CQ head |
| `keyed` | index [15:0], ring [18:16], queue id [47:24] (width 8) | slot, queue id, ring | ionic: one register per queue type shared by many queues |
| `event` | any | slot | a register where each write counts |

With the `seq` flag the writer puts a per-key sequence number above the index
(bits [31:16] for width 4, [63:48] for width 8). The ringee uses it to count
sequence numbers it never saw (`seq_gaps`, lost writes) and ones that arrived
late (`seq_ooo`). It also counts an index that went backwards (`regress`).

Three overlays are configured by default: region 0 `index` at `0x2000`,
region 1 `keyed` at `0x3000`, region 2 `event` at `0x4000`, each one page. Use
`--region N:model:base:size:width:stride[:seq]` or `--no-defaults`, or
reconfigure from the guest with `xio-doorbell config`. The full register map
is in `vfu-doorbell.h`.

## Build

The servers need the sbates130272 libvfio-user fork (it provides
`vfu_mmio_write`). The simplest build uses the fork's container image:

```bash
./build-in-container.sh     # binaries in /tmp/vfu-doorbell/bin
```

`IMAGE` and `OUT_DIR` override the image and output directory. Or build
directly where libvfio-user is installed:

```bash
cmake -S tools/vfu-doorbell -B build-vfu-doorbell
cmake --build build-vfu-doorbell
```

`xio-doorbell` has no dependencies and also builds without libvfio-user.

## Run

Start one server per device on its own socket and attach both to a QEMU guest
with `vfio-user-pci`, for example with qemu-tool:

```bash
vfu-doorbell --role ringee --socket /run/vfu/ringee.sock &
vfu-doorbell --role ringer --socket /run/vfu/ringer.sock &
qemu-tool run-vm ... --vfio-userdev /run/vfu/ringee.sock,/run/vfu/ringer.sock
```

qemu-minimal carries this rig as the named stack `vfu-doorbell-vm`, with a
settings file, an Ansible playbook that installs `xio-doorbell`, and tests; it
is the supported way to run it. The QEMU must be the fork build whose
`vfio_user_dma_write` dispatches to MMIO, and the servers must be built against
the matching libvfio-user fork.

In the guest, copy `xio-doorbell` over and run:

```bash
sudo xio-doorbell info                 # devices and configured regions
sudo xio-doorbell selftest             # built-in scenarios, PASS/FAIL

# 1000 writes over 4 NVMe-like slots, once from the CPU, once via the ringer
sudo xio-doorbell cpu-ring 0 1000 --nslots 4
sudo xio-doorbell ring     0 1000 --nslots 4

# the ionic collision: two queue ids rung through one shared register
sudo xio-doorbell ring 1 1000 --qids 2

sudo xio-doorbell dump                 # per-region counters
sudo xio-doorbell log 16               # the last 16 writes, in arrival order
```

`ring` and `cpu-ring` print what was sent and what the ringee saw. For a
synchronous delivery path expect `arrived` to equal the count, with zero
`seq_gaps`, `seq_ooo` and `regress`. A delivery path that coalesces writes, as
a polled doorbell page does, shows up as fewer arrivals or sequence gaps; an
index overlay tolerates that because each value covers the earlier ones, an
event overlay does not.

Options: `--size`, `--nslots`, `--qids`, `--qid0`, `--ring`, `--step`,
`--value`, `--pattern monotonic|repeat|random`, `--seq`/`--no-seq`,
`--delay-ns`, `--stride`, `--shm`, `--inline`, `--poll-mmio`, `--timeout-ms`.

## Server logs

Both servers log to stderr (`docker logs` for the containers). A successful
write is not logged by default; the ringee counts it, and the guest reads the
counters and the write log back with `xio-doorbell dump` and `log`. What is
logged:

* At startup and attach: `serving on`, `client attached`, one `DMA map` line per
  guest memory region, resets, and `client disconnected`.
* Ringee: each region configured (`region N: index base=...`) and each reset,
  with the writes and bad writes counted since the last one.
* Ringer: one line when a job starts (address, count, size, slots, mode) and one
  when it ends (sent, errors, `errno`, elapsed time, slowest write).
* Errors and warnings from libvfio-user, such as the one-time `twin_socket`
  warning on the first ringer write.

`--trace N` on the ringee also logs the first N individual writes after each
reset (region, offset, size, value). Add it to the ringee's `command:` in the
compose file. `-v` turns on libvfio-user's own debug logging, one line per
protocol message, which is very noisy.

## Completion, and a hazard the rig reproduces

libvfio-user is not thread safe and a `vfu_mmio_write` waits for QEMU's reply
on the same socket that carries the guest's own accesses to the device. If the
guest reads a ringer register while a write is in flight, the guest's CPU holds
QEMU's global lock waiting on the ringer, while QEMU needs that lock to answer
the ringer. The two wait on each other until QEMU's message timeout, and the
library reports unexpected requests ("not a command req"). An emulated GPU that
issues a doorbell write from its own thread has the same structure.

The tool therefore does not poll the ringer over MMIO. The ringer stores a
cookie into a guest RAM page when the job ends, which is a DMA-mapped store with
no protocol message, and the guest polls that page. Pass `--poll-mmio` to poll
the STATUS register instead and reproduce the hazard:

```bash
sudo xio-doorbell ring 0 200 --poll-mmio --timeout-ms 40000
```

`--inline` performs the writes from inside the ringer's BAR callback instead of
its worker thread, the other way to hit the same restriction.

## Observed behaviour

Against the fork QEMU `4cb9698` and libvfio-user `3719c3a`, `selftest` passes
all eight scenarios (CPU and ringer, index, keyed with two queue ids on one
register, event, and backwards-index detection). `ring 0 200 --poll-mmio`
stalls: 196 of 200 writes fail with `EPROTO` after tens of seconds and the
ringer logs "not a command req" for nearly every message. libvfio-user prints
its one-time "without the twin_socket feature" warning on the first
server-initiated write because QEMU's client does not negotiate the second
socket.

## Notes

* Guest MMIO accessors in `xio-doorbell` are inline assembly on purpose. KVM's
  instruction emulator rejects SSE moves to an MMIO address and injects an
  invalid-opcode fault; an optimizing compiler will otherwise load two adjacent
  64-bit registers with `movq` into an XMM register.
* Stop the stack before rebuilding. A running binary on a bind mount cannot be
  overwritten and the copy fails with "text file busy".
* The PCI vendor ID `0x1de0` is not allocated to this rig; pci.ids happens to
  label it "Groq". The guest tool matches vendor and device together.
* Not implemented yet: a posted (no-reply) write mode, which needs a
  libvfio-user API, and a shared-memory doorbell ringee that a poller watches.
