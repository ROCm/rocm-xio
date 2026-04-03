Performance
===========

This page documents RDMA-EP loopback performance
measurements collected on a single-node system. All
results are from GPU-initiated RDMA WRITE operations
with LFSR data verification, measured end-to-end from
the GPU kernel (post WQE to CQE completion).

Test Environment
----------------

.. list-table::
   :widths: 30 70
   :header-rows: 0

   * - **GPU**
     - AMD Radeon RX 9070 XT
   * - **CPU**
     - AMD Ryzen Threadripper PRO 7955WX 16-Cores
   * - **Broadcom NIC**
     - BCM57608 NetXtreme 25G/50G/100G/200G/400G
   * - **Pensando NIC**
     - AMD Pensando DSC Ethernet Controller
   * - **OS**
     - Ubuntu 24.04.4 LTS
   * - **Kernel**
     - 6.17.0-19-generic
   * - **ROCm**
     - 7.2.0
   * - **Commit**
     - ``a1ad2a9``

Test Methodology
----------------

Each measurement runs ``test-rdma-loopback`` in a
single-QP loopback configuration: the NIC sends an RDMA
WRITE to itself over a QP connected to its own GID. The
GPU kernel posts a single WQE, rings the doorbell from
device code, then spin-polls the CQ for completion. The
GPU wall clock measures the elapsed time from WQE post
to CQE arrival.

All test programs allocate memory through the
``xio::allocHostMemory`` / ``xio::allocDeviceMemory``
abstraction rather than calling ``posix_memalign``,
``hipHostMalloc``, or ``hipMalloc`` directly. This
ensures the same allocation flags and pinning semantics
used by the production endpoint code paths.

Ten iterations are run per (vendor, transfer size) pair,
each with a distinct LFSR seed for data verification.
Statistics are computed over the ten successful
iterations:

- **Min** -- fastest observed operation
- **Mean** -- arithmetic mean of all iterations
- **Std** -- population standard deviation
- **Max** -- slowest observed operation

Throughput and IOPS are derived from the per-operation
latency:

- **Throughput** = transfer size / latency (MB/s, where
  1 MB = 10\ :sup:`6` bytes)
- **IOPS** = 10\ :sup:`6` / latency (ops/s)

Because these are single-operation measurements (not
pipelined), the IOPS figures represent the serial
round-trip rate. Pipelined or multi-queue workloads
will achieve higher aggregate IOPS.

.. note::

   Transfer sizes below 32 bytes cause the GPU kernel
   to hang on both BNXT and IONIC hardware. The
   minimum working transfer size for loopback RDMA
   WRITE is 32 bytes.

Queue Memory Placement
----------------------

The CQ and SQ buffers can reside in either host memory
or GPU VRAM.  The ``--queue-mem host|vram`` flag on
``test-rdma-loopback`` (and the ``queueMem`` field in
``RdmaEpConfig``) selects the placement.

============  ========================================
Mode          Description
============  ========================================
``host``      ``hipHostMallocCoherent`` -- host-pinned,
              fine-grained coherent memory.  NIC DMA
              writes are visible to the GPU L2 without
              explicit cache management.  Default.
``vram``      ``allocDeviceMemory(UNCACHED)`` -- GPU
              VRAM.  NIC writes via PCIe DMA; GPU
              reads are local VRAM accesses with no
              coherence concern.
============  ========================================

BNXT always uses VRAM for its CQ (allocated via DMA-BUF
UMEM in the DV backend) regardless of this setting.
IONIC uses host coherent memory by default; the IONIC
kernel driver does not currently support VRAM-backed
queues through ``ib_umem_get``.

RDMA-EP Loopback Results
------------------------

Broadcom (BNXT) -- CQ in VRAM
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Latency
"""""""

.. list-table::
   :widths: 15 17 17 17 17
   :header-rows: 1

   * - Size
     - Min (us)
     - Mean (us)
     - Std (us)
     - Max (us)
   * - 256 B
     - 21.8
     - 23.8
     - 4.6
     - 37.4
   * - 1 KiB
     - 21.6
     - 22.5
     - 0.5
     - 23.2
   * - 4 KiB
     - 22.1
     - 22.9
     - 0.7
     - 24.4
   * - 64 KiB
     - 37.6
     - 40.2
     - 1.8
     - 43.2
   * - 1 MiB
     - 150.3
     - 153.3
     - 1.8
     - 156.6

Throughput
""""""""""

.. list-table::
   :widths: 15 17 17 17 17
   :header-rows: 1

   * - Size
     - Min (MB/s)
     - Mean (MB/s)
     - Std (MB/s)
     - Max (MB/s)
   * - 256 B
     - 6.8
     - 10.8
     - 2.1
     - 11.7
   * - 1 KiB
     - 44.1
     - 45.5
     - 1.0
     - 47.4
   * - 4 KiB
     - 167.9
     - 178.9
     - 5.5
     - 185.3
   * - 64 KiB
     - 1,517.0
     - 1,630.2
     - 73.0
     - 1,743.0
   * - 1 MiB
     - 6,695.9
     - 6,840.0
     - 80.3
     - 6,976.6

IOPS
""""

.. list-table::
   :widths: 15 17 17 17 17
   :header-rows: 1

   * - Size
     - Min
     - Mean
     - Std
     - Max
   * - 256 B
     - 26,738
     - 42,017
     - 8,121
     - 45,872
   * - 1 KiB
     - 43,103
     - 44,444
     - 988
     - 46,296
   * - 4 KiB
     - 40,984
     - 43,668
     - 1,335
     - 45,249
   * - 64 KiB
     - 23,148
     - 24,876
     - 1,114
     - 26,596
   * - 1 MiB
     - 6,386
     - 6,523
     - 77
     - 6,653

Pensando (IONIC) -- CQ in Host Coherent
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Latency
"""""""

.. list-table::
   :widths: 15 17 17 17 17
   :header-rows: 1

   * - Size
     - Min (us)
     - Mean (us)
     - Std (us)
     - Max (us)
   * - 256 B
     - 14.6
     - 15.5
     - 0.7
     - 17.1
   * - 1 KiB
     - 14.0
     - 15.0
     - 0.5
     - 15.9
   * - 4 KiB
     - 16.3
     - 16.7
     - 0.3
     - 17.2
   * - 64 KiB
     - 22.2
     - 22.7
     - 0.4
     - 23.2
   * - 1 MiB
     - 96.7
     - 97.9
     - 0.5
     - 98.6

Throughput
""""""""""

.. list-table::
   :widths: 15 17 17 17 17
   :header-rows: 1

   * - Size
     - Min (MB/s)
     - Mean (MB/s)
     - Std (MB/s)
     - Max (MB/s)
   * - 256 B
     - 15.0
     - 16.5
     - 0.7
     - 17.5
   * - 1 KiB
     - 64.4
     - 68.3
     - 2.3
     - 73.1
   * - 4 KiB
     - 238.1
     - 245.3
     - 4.4
     - 251.3
   * - 64 KiB
     - 2,824.8
     - 2,887.0
     - 50.9
     - 2,952.1
   * - 1 MiB
     - 10,634.6
     - 10,710.7
     - 54.7
     - 10,843.6

IOPS
""""

.. list-table::
   :widths: 15 17 17 17 17
   :header-rows: 1

   * - Size
     - Min
     - Mean
     - Std
     - Max
   * - 256 B
     - 58,480
     - 64,516
     - 2,914
     - 68,493
   * - 1 KiB
     - 62,893
     - 66,667
     - 2,222
     - 71,429
   * - 4 KiB
     - 58,140
     - 59,880
     - 1,076
     - 61,350
   * - 64 KiB
     - 43,103
     - 44,053
     - 776
     - 45,045
   * - 1 MiB
     - 10,142
     - 10,215
     - 52
     - 10,341

RDMA WRITE with Immediate
-------------------------

The ``QueuePair`` API now includes ``put_nbi_imm()`` and
``put_nbi_imm_single()`` for RDMA WRITE with Immediate
Data (``IBV_WR_RDMA_WRITE_WITH_IMM``). Opcode support
is wired for all four vendors (BNXT, IONIC, MLX5, ERNIC)
and the ``--write-imm`` flag is available in
``test-rdma-loopback``.

Per the InfiniBand specification (section 9.3.3.3),
WRITE_IMM is commonly used as a **zero-length
notification**: the 32-bit immediate value is the entire
payload, posted with ``num_sge = 0``. The NIC delivers
the immediate value by consuming a receive WQE from the
responder's RQ and generating a completion with the
immediate data.

Current status:

- **IONIC**: Functional with ``hipHostMallocCoherent``
  queue buffers.  Zero-length WRITE_IMM completes in
  ~14--16 us (loopback).  Occasional failures (~2/10)
  on rapid QP number reuse are a firmware timing issue,
  not a coherence problem.

- **BNXT**: The DV-created QP does not expose
  ``ibv_post_recv``.  Posting receive WQEs (required
  for WRITE_IMM) is not supported through the current
  DV path.  WRITE_IMM is skipped on BNXT (exit 77).

.. note::

   The ``hipHostMallocCoherent`` fix for the IONIC
   parent domain allocator was critical for reliable
   CQ polling.  Without the coherent flag, the GPU L2
   cache served stale CQE data from previous QP
   allocations, causing ~60% of WRITE_IMM operations
   to time out.  This matches the nvme-ep queue
   allocation path which also uses coherent memory.

NVMe-EP Smoke Test
------------------

The ``xio-tester nvme-ep`` smoke test validates the
GPU-initiated NVMe read path end to end: admin queue
setup, I/O queue creation, SQE construction from GPU
device code, doorbell ring, CQE polling, and LFSR data
verification.

.. list-table::
   :widths: 30 70
   :header-rows: 0

   * - **NVMe Device**
     - ``/dev/nvme2`` (MTR_SLC_16GB, FW 2.0.1.06)
   * - **LBA Size**
     - 512 bytes
   * - **Namespace Capacity**
     - 28,191,632 LBAs (~13.4 GiB)
   * - **Max Queue ID**
     - 32
   * - **PCI BDF**
     - ``0000:85:00.0``

Results (4 sequential 512-byte reads, batch size 1):

.. list-table::
   :widths: 20 20 20 20
   :header-rows: 1

   * - Min (us)
     - Mean (us)
     - Std (us)
     - Max (us)
   * - 29.6
     - 30.0
     - 0.5
     - 30.6

The unit tests (``test-nvme-config``,
``test-nvme-helpers``, ``test-nvme-hardware``) validate
struct layout, helper functions, and hardware queries
(LBA size, namespace capacity, SMART log, queue ID
enumeration) without issuing I/O.

Reproducing These Results
-------------------------

Build with both BNXT and IONIC providers enabled:

.. code-block:: bash

   cmake -S . -B build \
     -DCMAKE_BUILD_TYPE=Release \
     -DGDA_BNXT=ON -DGDA_IONIC=ON \
     -DBUILD_TESTING=ON
   cmake --build build \
     --target test-rdma-loopback \
     --target install-rdma-core \
     --parallel

Run the hardware setup fixture, then execute the sweep
for each vendor and transfer size:

.. code-block:: bash

   # Setup loopback interfaces
   sudo VENDOR=all \
     scripts/test/setup-rdma-loopback.sh

   # Run BNXT sweep (example: 4 KiB, 10 iters)
   LIB="build/_deps/rdma-core/install/lib"
   LIB="${LIB}:/opt/rocm/lib"
   sudo env LD_LIBRARY_PATH="${LIB}" \
     build/tests/unit/rdma-ep/test-rdma-loopback \
     --provider bnxt \
     --device rocm-rdma-bnxt0 \
     --size 4096 --seed 1

   # Run IONIC sweep (example: 4 KiB, 10 iters)
   sudo env LD_LIBRARY_PATH="${LIB}" \
     build/tests/unit/rdma-ep/test-rdma-loopback \
     --provider ionic \
     --device rocm-rdma-ionic0 \
     --size 4096 --seed 1

Queue memory placement can be selected per-run:

.. code-block:: bash

   # Host coherent (default, used by IONIC)
   sudo env LD_LIBRARY_PATH="${LIB}" \
     build/tests/unit/rdma-ep/test-rdma-loopback \
     --provider ionic \
     --device rocm-rdma-ionic0 \
     --size 4096 --seed 1 \
     --queue-mem host

Or use the convenience script which iterates over
multiple seeds and computes statistics automatically:

.. code-block:: bash

   VENDOR=bnxt TEST_SIZE=4096 ITERATIONS=10 \
     ./run-test-rdma-loopback.sh

NVMe-EP smoke test (requires root and an NVMe device
that is **not** the rootfs):

.. code-block:: bash

   # Unit tests (no hardware required for config/helpers)
   build/tests/unit/nvme-ep/test-nvme-config
   build/tests/unit/nvme-ep/test-nvme-helpers

   # Hardware query test
   sudo build/tests/unit/nvme-ep/test-nvme-hardware \
     --controller /dev/nvme2

   # Full data-path smoke test (4 reads)
   sudo build/xio-tester nvme-ep \
     --controller /dev/nvme2 \
     --read-io 4 --batch-size 1
