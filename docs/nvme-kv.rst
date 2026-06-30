.. meta::
  :description: GPU-initiated NVMe Key-Value (Store/Retrieve) support as an
    additive mode on the ROCm XIO nvme-ep endpoint
  :keywords: ROCm, documentation, XIO, NVMe, Key-Value, KV, nvme-ep

.. _nvme-kv:

**********************************
NVMe Key-Value support for nvme-ep
**********************************

GPU-initiated NVMe **Key-Value** (Store / Retrieve) from ``__device__`` code, as
an additive mode on the existing block ``nvme-ep`` endpoint. Block behavior is
unchanged when ``--kv-op`` is not set.

Why additive (a flag, not a new endpoint)
-----------------------------------------

KV reuses the entire ``nvme-ep`` machinery verbatim --- admin queue creation,
doorbells (incl. the ``--pci-mmio-bridge`` path), PRP/value-buffer allocation
(host **and** VRAM/P2PDMA via ``--memory-mode 8``), CQ polling, and the endpoint
registry/dispatch. The only delta is the **SQE encoding** and reading the
returned value length from the completion. So KV is a ``driveEndpointKv()``
sibling of ``driveEndpointSingle()`` selected by ``ioParams.kvOpcode``, plus a
few host fields. No new endpoint, no registry regen, no CMake or kernel-module
change.

On-the-wire format (NVMe KV Command Set)
----------------------------------------

Opcodes are numerically equal to block Write/Read; the controller routes them as
KV because the **namespace CSI is Key Value (0x1)**.

.. list-table:: NVMe KV Command Set field encoding
   :header-rows: 1
   :widths: 20 25 55

   * - Field
     - Location
     - Notes
   * - Opcode
     - CDW0
     - Store ``0x01``, Retrieve ``0x02``
   * - NSID
     - CDW1
     - the KV namespace id
   * - Key length
     - CDW11 bits 7:0
     - 1..16; options in bits 15:8 (0)
   * - Key bytes 0..7
     - CDW2 / CDW3
     - flat little-endian image
   * - Key bytes 8..15
     - CDW14 / CDW15
     - flat little-endian image
   * - Value size
     - CDW10
     - value len (Store) / host-buf size (Retrieve)
   * - Value data
     - PRP1 / PRP2 (DPTR)
     - same as a block transfer
   * - Retrieve result
     - CQE **DW0**
     - TRUE stored value length

``kvSqeSetup()`` (``src/include/nvme-kv.h``) encodes the KV dwords; the caller
sets opcode/nsid/DPTR exactly like block I/O. Status ``0x87`` = key does not
exist (reported, not fatal); ``0x86`` = invalid key size; ``0x85`` = invalid
value size.

Files touched
-------------

- ``src/include/nvme-kv.h`` (new) --- KV opcodes, status codes,
  ``kvSqeSetup()``.
- ``src/endpoints/nvme-ep/nvme-ep.h`` --- ``#include "nvme-kv.h"``; KV fields on
  ``nvmeIoParams`` (``kvOpcode``, ``kvKeyLen``, ``kvValueLen``, ``kvKey[4]``)
  and on the host ``nvmeEpConfig::ioParams`` (``kvOp``, ``kvKey``,
  ``kvValueLen``).
- ``src/endpoints/nvme-ep/nvme-ep.hip`` --- ``driveEndpointKv()`` (serial) and
  ``driveEndpointKvWavefront()`` (cooperative batch); dispatch in
  ``driveEndpoint()``; gate the block-only LBA-size and capacity queries in KV
  mode; pack the key + value size and upload the multi-key manifest in
  ``run()``.
- ``src/tester/xio-cli-options.cpp`` --- ``--kv-op``, ``--key``, ``--keys``,
  ``--value-size``.

Usage
-----

.. code-block:: bash

   # Store the value of "gpukey01" (4 KiB) -- value sourced from the GPU write buffer
   xio-tester nvme-ep --controller /dev/nvme0 \
       --kv-op store --key gpukey01 --value-size 4096 --write-io 1 --pci-mmio-bridge

   # Retrieve it -- value lands in the GPU read buffer (add --memory-mode 8 for VRAM)
   xio-tester nvme-ep --controller /dev/nvme0 \
       --kv-op retrieve --key gpukey01 --value-size 4096 --read-io 1 --pci-mmio-bridge

``--read-io N`` / ``--write-io N`` set the op count (Retrieve / Store). The
value buffer is ``--data-buffer-size`` (default 1 MiB); ``--value-size`` caps
the transfer.

Wavefront/batched KV (multi-key)
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

``--keys`` takes a manifest of keys and, with ``--batch-size B > 1``, drives the
cooperative ``driveEndpointKvWavefront()`` path: threads ``1..B`` each encode
one key's Store/Retrieve into its own value-buffer slot (``b * value_size``),
and
thread 0 rings the SQ doorbell once, polls the ``B`` completions, and rings the
CQ doorbell --- the KV sibling of the block wavefront path. One key is processed
per op (the manifest is cycled in ``--infinite`` mode).

.. code-block:: bash

   # Retrieve four shards in batches of four (one doorbell ring), each value
   # landing in its own GPU buffer slot
   xio-tester nvme-ep --controller /dev/nvme0 --kv-op retrieve \
       --keys shard0 shard1 shard2 shard3 \
       --batch-size 4 --value-size 4096 --data-buffer-size 16384 \
       --read-io 1 --pci-mmio-bridge

``--read-io`` (retrieve) / ``--write-io`` (store) must be non-zero --- they gate
the allocation of the value buffer the op reads into / sources from.

The value buffer must hold ``batch-size * value-size`` bytes (each in-flight key
needs its own slot); ``run()`` validates this. A single ``--key`` continues to
use the serial path at ``--batch-size 1``.

``scripts/test/stage3_kv_wavefront_gpu.sh`` runs this end-to-end against the
SPDK kvdev_rados target: it batched-Stores a key manifest, batched-Retrieves it
(host
buffer and VRAM/P2PDMA), and ``rados stat``\ s every object. The SPDK kvdev
target needs no changes for the batched path --- the NVMf KV handler is async
with per-command request context, and the rados backend uses librados aio, so
the manifest's commands are genuinely concurrent in flight.

Reference target: SPDK kvdev over RADOS
---------------------------------------

The KV path targets any conformant NVMe-KV controller that exposes a CSI=KV
namespace. The bundled ``scripts/test/stage2_kv_rados_gpu.sh`` exercises it
end-to-end against one such target --- an SPDK vfio-user **NVMe-KV** subsystem
backed by Ceph RADOS --- and runs a GPU Store+Retrieve:

.. code-block:: text

   nvmf_create_transport -t VFIOUSER -q 1024 -m 16
   kvdev_rados_register_cluster ceph0 --user admin --config-file ceph.conf --key-file keyring
   kvdev_rados_create KvRados0 ceph0 kvpool --namespace kvns
   nvmf_create_subsystem <nqn> -s SPDKKVR01 -a
   nvmf_subsystem_add_kv_ns <nqn> KvRados0          # CSI=KV namespace
   nvmf_subsystem_add_listener <nqn> -t VFIOUSER -a <muser> -s 0

The store is verified by ``rados -p kvpool -N kvns stat <hex(key)>``. Any other
NVMe-KV target --- different transport or value backend --- works unchanged from
the host side, as long as it presents a CSI=KV namespace.

Status
------

- ✅ rocm-xio KV path implemented; **compiles** (host hipcc), CLI wired, block
  path untouched.
- ✅ Reference SPDK vfio-user NVMe-KV target (kvdev_rados) comes up clean
  host-side (validated reboot-free).
- ✅ End-to-end GPU run verified: GPU ``__device__`` code issues KV Store then
  Retrieve and the value lands directly in GPU memory. The guest Linux NVMe
  driver enumerates the KV-only controller directly (``CC.CSS=IOCS``, exposes
  ``/dev/nvme0``) --- no block namespace required --- so rocm-xio creates IO
  queues and targets the KV nsid.

Follow-ups
----------

- ✅ Wavefront/batched KV --- ``driveEndpointKvWavefront()`` batches a multi-key
  manifest (``--keys``) one doorbell ring at a time. The serial single-thread
  ``driveEndpointKv()`` still drives ``--batch-size 1``.
- KV Delete / Exist / List opcodes (defines are already in ``nvme-kv.h``).
- Multi-key manifest from a file (currently ``--keys`` is an inline list) and
  per-key value sizes (currently one ``--value-size`` for the whole batch) for
  weight-shard fetch.
