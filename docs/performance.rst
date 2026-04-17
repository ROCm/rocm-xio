Performance
===========

This page documents RDMA-EP loopback performance measurements collected on a
single-node system. All results are from GPU-initiated RDMA WRITE operations
with LFSR data verification, measured end-to-end from the GPU kernel (post WQE
to CQE completion).

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

Test Methodology
----------------

Each measurement runs ``test-rdma-loopback`` in a single-QP loopback
configuration: the NIC sends an RDMA WRITE to itself over a QP connected to its
own GID. The GPU kernel posts a single WQE, rings the doorbell from device code,
then spin-polls the CQ for completion. The GPU wall clock measures the elapsed
time from WQE post to CQE arrival.

All test programs allocate memory through the ``xio::allocHostMemory`` /
``xio::allocDeviceMemory`` abstraction rather than calling ``posix_memalign``,
``hipHostMalloc``, or ``hipMalloc`` directly. This ensures the same allocation
flags and pinning semantics used by the production endpoint code paths.

Ten iterations are run per (vendor, transfer size) pair, each with a distinct
LFSR seed for data verification. Statistics are computed over the ten successful
iterations:

- **Min** -- fastest observed operation
- **Mean** -- arithmetic mean of all iterations
- **Std** -- population standard deviation
- **Max** -- slowest observed operation

Throughput and IOPS are derived from the per-operation latency:

- **Throughput** = transfer size / latency (MB/s, where 1 MB = 10\ :sup:`6`
  bytes)
- **IOPS** = 10\ :sup:`6` / latency (ops/s)

Because these are single-operation measurements (not pipelined), the IOPS
figures represent the serial round-trip rate. Pipelined or multi-queue workloads
will achieve higher aggregate IOPS.

.. note::

   Transfer sizes below 32 bytes cause the GPU kernel to hang on both BNXT and
   IONIC hardware. The minimum working transfer size for loopback RDMA WRITE
   is 32 bytes.

Queue Memory Placement
----------------------

The CQ and SQ buffers can reside in either host memory or GPU VRAM. The
``--queue-mem host|vram`` flag on ``test-rdma-loopback`` (and the ``queueMem``
field in ``RdmaEpConfig``) selects the placement.

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

BNXT always uses VRAM for its CQ (allocated via DMA-BUF UMEM in the DV backend)
regardless of this setting. IONIC uses host coherent memory by default; the
IONIC kernel driver does not currently support VRAM-backed queues through
``ib_umem_get``.

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
``put_nbi_imm_single()`` for RDMA WRITE with Immediate Data
(``IBV_WR_RDMA_WRITE_WITH_IMM``). Opcode support is wired for all four vendors
(BNXT, IONIC, MLX5, ERNIC) and the ``--write-imm`` flag is available in
``test-rdma-loopback``. Only IONIC currently runs end-to-end with
``test-rdma-loopback --write-imm``; BNXT and other vendors exit with skip code
77 because their DV-created QPs do not expose ``ibv_post_recv``, which the
WRITE_IMM responder path requires.

Per the InfiniBand specification (section 9.3.3.3), WRITE_IMM is commonly used
as a **zero-length notification**: the 32-bit immediate value is the entire
payload, posted with ``num_sge = 0``. The NIC delivers the immediate value by
consuming a receive WQE from the responder's RQ and generating a completion with
the immediate data.

Current status:

- **IONIC**: Functional with ``hipHostMallocCoherent`` queue buffers.
  Zero-length WRITE_IMM completes in ~14--16 us (loopback). Occasional failures
  (~2/10) on rapid QP number reuse are a firmware timing issue, not a coherence
  problem.

- **BNXT**: The DV-created QP does not expose ``ibv_post_recv``. Posting receive
  WQEs (required for WRITE_IMM) is not supported through the current DV path.
  WRITE_IMM is skipped on BNXT (exit 77).

.. note::

   The ``hipHostMallocCoherent`` fix for the IONIC parent domain allocator was
   critical for reliable CQ polling. Without the coherent flag, the GPU L2 cache
   served stale CQE data from previous QP allocations, causing ~60% of WRITE_IMM
   operations to time out. This matches the nvme-ep queue allocation path which
   also uses coherent memory.

NVMe-EP Smoke Test
------------------

The ``xio-tester nvme-ep`` smoke test validates the GPU-initiated NVMe read path
end to end: admin queue setup, I/O queue creation, SQE construction from GPU
device code, doorbell ring, CQE polling, and LFSR data verification.

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

The unit tests (``test-nvme-config``, ``test-nvme-helpers``,
``test-nvme-hardware``) validate struct layout, helper functions, and hardware
queries (LBA size, namespace capacity, SMART log, queue ID enumeration) without
issuing I/O.

NVMe-EP Performance
-------------------

This section compares GPU-initiated NVMe I/O (via ``xio-tester nvme-ep``)
against CPU-initiated I/O (via ``fio``) on two NVMe devices. The GPU drives the
NVMe submission and completion queues directly from device code, bypassing the
kernel block layer entirely. The ``fio`` baseline uses the kernel NVMe driver
with ``io_uring`` (QD=32 for throughput) and ``sync`` (QD=1 for latency).

NVMe Devices Under Test
^^^^^^^^^^^^^^^^^^^^^^^^

.. list-table::
   :widths: 18 37 37
   :header-rows: 1

   * - Property
     - ``/dev/nvme2`` (MTR_SLC)
     - ``/dev/nvme1`` (WD_BLACK)
   * - **Model**
     - MTR_SLC_16GB
     - WD_BLACK SN850X 2000GB
   * - **Firmware**
     - 2.0.1.06
     - 620361WD
   * - **LBA Size**
     - 512 bytes
     - 512 bytes
   * - **Capacity**
     - 28,191,632 LBAs (13.4 GiB)
     - 3,907,029,168 LBAs (1.8 TiB)
   * - **PCI BDF**
     - ``0000:85:00.0``
     - ``0000:c2:00.0``
   * - **VID:DID**
     - 0x11f8:0xf117 (Microchip)
     - 0x15b7:0x5030 (Sandisk/WD)

CTest Results
^^^^^^^^^^^^^

All NVMe CTests were run on both devices using ``ROCXIO_NVME_DEVICE``.

.. list-table::
   :widths: 40 30 30
   :header-rows: 1

   * - Device
     - Passed
     - Failed
   * - ``/dev/nvme2`` (MTR_SLC)
     - 23 / 25
     - ``nvme-verify-rand-device-mem`` (timeout),
       ``nvme-verify-seq-device-mem-multi-lba``
   * - ``/dev/nvme1`` (WD_BLACK)
     - 24 / 25
     - ``nvme-verify-seq-device-mem-multi-lba``

The ``nvme-verify-seq-device-mem-multi-lba`` failure occurs on both devices and
indicates a data verification issue with multi-LBA writes (``--lbas-per-io 32``)
using device memory (memory mode 8). The ``nvme-verify-rand-device-mem`` timeout
on MTR_SLC is related to the same device-memory verification path.

fio CPU Baseline
^^^^^^^^^^^^^^^^

All fio tests used ``--direct=1`` (bypass page cache), 30-second runtime, and
``--time_based``. Bandwidth / IOPS tests used ``io_uring`` with
``--iodepth=32``; latency tests used ``sync`` with ``--iodepth=1``.

MTR_SLC (``/dev/nvme2n1``) -- io_uring QD=32
"""""""""""""""""""""""""""""""""""""""""""""

.. list-table::
   :widths: 12 10 12 12 12 12 10 10
   :header-rows: 1

   * - BS
     - Pattern
     - IOPS
     - BW (MB/s)
     - Lat (us)
     - p99 (us)
     - usr%
     - sys%
   * - 512
     - randread
     - 93,251
     - 46
     - 343
     - 106
     - 4.2
     - 23.4
   * - 512
     - seqread
     - 351,836
     - 172
     - 91
     - 102
     - 15.3
     - 84.6
   * - 4K
     - randread
     - 338,608
     - 1,323
     - 94
     - 105
     - 14.4
     - 85.4
   * - 4K
     - seqread
     - 344,886
     - 1,347
     - 93
     - 103
     - 13.3
     - 86.5
   * - 64K
     - randread
     - 80,864
     - 5,054
     - 396
     - 709
     - 3.6
     - 47.3
   * - 64K
     - seqread
     - 80,864
     - 5,054
     - 396
     - 553
     - 3.2
     - 47.3
   * - 1M
     - randread
     - 5,127
     - 5,127
     - 6,240
     - 11,469
     - 0.2
     - 25.2

MTR_SLC (``/dev/nvme2n1``) -- sync QD=1
""""""""""""""""""""""""""""""""""""""""

.. list-table::
   :widths: 12 12 12 12 12 12 10 10
   :header-rows: 1

   * - BS
     - Pattern
     - IOPS
     - BW (MB/s)
     - Lat (us)
     - p99 (us)
     - usr%
     - sys%
   * - 512
     - randread
     - 77,456
     - 38
     - 12.5
     - 17.3
     - 4.5
     - 28.9
   * - 4K
     - randread
     - 73,616
     - 288
     - 13.2
     - 18.3
     - 4.0
     - 27.4
   * - 64K
     - randread
     - 22,594
     - 1,412
     - 43.8
     - 52.0
     - 1.2
     - 15.7
   * - 1M
     - randread
     - 1,611
     - 1,611
     - 620
     - 643
     - 0.1
     - 7.6

WD_BLACK (``/dev/nvme1n1``) -- io_uring QD=32
"""""""""""""""""""""""""""""""""""""""""""""

.. list-table::
   :widths: 12 10 12 12 12 12 10 10
   :header-rows: 1

   * - BS
     - Pattern
     - IOPS
     - BW (MB/s)
     - Lat (us)
     - p99 (us)
     - usr%
     - sys%
   * - 512
     - randread
     - 8,204
     - 4
     - 3,900
     - 485
     - 0.4
     - 1.7
   * - 512
     - seqread
     - 234,273
     - 114
     - 136
     - 247
     - 10.3
     - 66.1
   * - 4K
     - randread
     - 264,744
     - 1,034
     - 121
     - 514
     - 13.2
     - 56.5
   * - 4K
     - seqread
     - 316,102
     - 1,235
     - 101
     - 142
     - 12.4
     - 76.8
   * - 64K
     - randread
     - 74,766
     - 4,673
     - 428
     - 2,605
     - 4.0
     - 43.3
   * - 64K
     - seqread
     - 97,875
     - 6,117
     - 327
     - 717
     - 3.7
     - 52.2
   * - 1M
     - randread
     - 6,730
     - 6,730
     - 4,754
     - 6,849
     - 0.3
     - 24.4

WD_BLACK (``/dev/nvme1n1``) -- sync QD=1
""""""""""""""""""""""""""""""""""""""""

.. list-table::
   :widths: 12 12 12 12 12 12 10 10
   :header-rows: 1

   * - BS
     - Pattern
     - IOPS
     - BW (MB/s)
     - Lat (us)
     - p99 (us)
     - usr%
     - sys%
   * - 512
     - randread
     - 17,449
     - 9
     - 56.7
     - 86.5
     - 1.4
     - 7.3
   * - 4K
     - randread
     - 33,931
     - 133
     - 28.9
     - 74.2
     - 2.3
     - 14.2
   * - 64K
     - randread
     - 9,559
     - 597
     - 104
     - 173
     - 0.6
     - 6.8
   * - 1M
     - randread
     - 2,117
     - 2,117
     - 472
     - 823
     - 0.2
     - 10.2

GPU-Initiated NVMe (xio-tester)
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

All runs used ``HSA_FORCE_FINE_GRAIN_PCIE=1`` and ``--less-timing``. Latency is
measured end-to-end on the GPU wall clock: from SQE post to CQE arrival.
Transfer size is 512 bytes (1 LBA) unless noted.

Memory Mode Comparison -- MTR_SLC
""""""""""""""""""""""""""""""""""

Single-op latency (128 reads, batch size 1):

.. list-table::
   :widths: 10 10 10 10 10 40
   :header-rows: 1

   * - Mode
     - Min (us)
     - Avg (us)
     - Max (us)
     - Std (us)
     - Placement
   * - 0
     - 33.8
     - 38.4
     - 200.0
     - 14.3
     - SQ host, CQ host, data host
   * - 3
     - 27.6
     - 35.5
     - 196.5
     - 14.3
     - SQ VRAM, CQ VRAM, data host
   * - 8
     - 27.8
     - 41.8
     - 214.8
     - 15.4
     - SQ host, CQ host, data VRAM
   * - 11
     - 28.0
     - 35.1
     - 215.1
     - 16.0
     - SQ VRAM, CQ VRAM, data VRAM

Batched reads (128 reads, batch size 16):

.. list-table::
   :widths: 10 10 10 10 10
   :header-rows: 1

   * - Mode
     - Min (us)
     - Avg (us)
     - Max (us)
     - Std (us)
   * - 0
     - 30.2
     - 188.9
     - 524.4
     - 32.8
   * - 3
     - 41.7
     - 193.5
     - 521.8
     - 32.0
   * - 8
     - 41.2
     - 209.9
     - 477.0
     - 27.9
   * - 11
     - 31.6
     - 203.6
     - 523.6
     - 32.1

Multi-queue (128 reads, batch 16, 4 queues):

.. list-table::
   :widths: 10 10 10 10 10
   :header-rows: 1

   * - Mode
     - Min (us)
     - Avg (us)
     - Max (us)
     - Std (us)
   * - 0
     - 27.5
     - 151.5
     - 387.0
     - 11.8
   * - 3
     - 27.2
     - 152.8
     - 383.8
     - 11.6
   * - 8
     - 28.4
     - 170.5
     - 432.0
     - 13.2
   * - 11
     - 28.0
     - 164.2
     - 401.7
     - 12.1

Multi-LBA (128 reads, 8 LBAs/IO = 4 KiB, batch 16):

.. list-table::
   :widths: 10 10 10 10 10
   :header-rows: 1

   * - Mode
     - Min (us)
     - Avg (us)
     - Max (us)
     - Std (us)
   * - 0
     - 40.0
     - 198.5
     - 453.4
     - 26.5
   * - 3
     - 41.5
     - 212.6
     - 471.0
     - 27.4
   * - 8
     - 40.2
     - 207.8
     - 525.0
     - 31.7
   * - 11
     - 41.1
     - 193.0
     - 483.4
     - 29.0

Memory Mode Comparison -- WD_BLACK
""""""""""""""""""""""""""""""""""""

Single-op latency (128 reads, batch size 1):

.. list-table::
   :widths: 10 10 10 10 10 40
   :header-rows: 1

   * - Mode
     - Min (us)
     - Avg (us)
     - Max (us)
     - Std (us)
     - Placement
   * - 0
     - 42.8
     - 112.0
     - 470.7
     - 32.4
     - SQ host, CQ host, data host
   * - 3
     - 50.2
     - 315.7
     - 9,610
     - 824.9
     - SQ VRAM, CQ VRAM, data host
   * - 8
     - 50.1
     - 315.6
     - 9,568
     - 821.2
     - SQ host, CQ host, data VRAM
   * - 11
     - 50.8
     - 312.4
     - 9,653
     - 829.0
     - SQ VRAM, CQ VRAM, data VRAM

Batched reads (128 reads, batch size 16):

.. list-table::
   :widths: 10 10 10 10 10
   :header-rows: 1

   * - Mode
     - Min (us)
     - Avg (us)
     - Max (us)
     - Std (us)
   * - 0
     - 190
     - 2,020
     - 10,690
     - 780
   * - 3
     - 210
     - 1,920
     - 9,950
     - 730
   * - 8
     - 210
     - 1,920
     - 10,010
     - 730
   * - 11
     - 210
     - 1,930
     - 9,970
     - 730

Sustained Throughput (Infinite Mode)
""""""""""""""""""""""""""""""""""""

Both devices were run in infinite mode for ~15 seconds with 16 queues, batch
size 16, memory mode 3 (SQ/CQ in VRAM), and 512-byte reads:

.. list-table::
   :widths: 22 15 15 15 15
   :header-rows: 1

   * - Device
     - Iterations
     - Avg (us)
     - Min (us)
     - Max (us)
   * - MTR_SLC (nvme2)
     - 1,028,434
     - 126.8
     - 24.8
     - 1,838.8
   * - WD_BLACK (nvme1)
     - 653,969
     - 211.1
     - 24.5
     - 22,085.4

Derived sustained performance (16 queues x 512 B):

.. list-table::
   :widths: 22 15 20 20
   :header-rows: 1

   * - Device
     - Duration
     - IOPS
     - BW (MB/s)
   * - MTR_SLC (nvme2)
     - ~15 s
     - ~68,562
     - ~33.5
   * - WD_BLACK (nvme1)
     - ~15 s
     - ~43,598
     - ~21.3

Write + Read Verification
"""""""""""""""""""""""""

The ``--write-io N --read-io N`` mode writes LFSR patterns and then reads them
back. The host-side LFSR verifier runs after the GPU kernel finishes and reports
pass/fail counts. On both devices, 64 writes followed by 64 reads (batch size 1)
completed successfully across all four memory modes.

.. note::

   Pure read tests show ``Verify Failed`` counts equal to the number of reads.
   This is expected: the LFSR verifier checks read data against a pattern that
   was never written by ``xio-tester``, so the comparison always fails for
   arbitrary on-disk content.

CPU Utilization: GPU vs CPU
^^^^^^^^^^^^^^^^^^^^^^^^^^^^

A key advantage of GPU-initiated NVMe I/O is CPU offload. The GPU kernel
constructs SQEs, rings doorbells, and polls CQEs entirely from device code. The
CPU is only involved in queue setup and teardown.

fio (CPU-driven, 4K randread, io_uring QD=32):

.. list-table::
   :widths: 22 12 12 12 12 12
   :header-rows: 1

   * - Device
     - IOPS
     - usr%
     - sys%
     - Total%
     - CPU us/op
   * - MTR_SLC
     - 338,608
     - 14.4
     - 85.4
     - 99.8
     - 2.95
   * - WD_BLACK
     - 264,744
     - 13.2
     - 56.5
     - 69.7
     - 2.63

xio-tester (GPU-driven, 512B reads, mode 3):

.. list-table::
   :widths: 22 12 50
   :header-rows: 1

   * - Device
     - IOPS
     - CPU
   * - MTR_SLC
     - ~68,562
     - ~0% (GPU-driven, CPU idle)
   * - WD_BLACK
     - ~43,598
     - ~0% (GPU-driven, CPU idle)

The CPU-driven path consumes one full core (99.8% usr+sys on MTR_SLC at 338K
IOPS). The GPU-driven path achieves its IOPS with effectively zero CPU overhead,
freeing the CPU for other work. At 512 B transfer sizes, the GPU single-op
latency (~35 us on MTR_SLC) is higher than the kernel NVMe driver (~12.5 us via
sync QD=1), but the GPU path trades latency for CPU offload and can scale across
many queues without consuming CPU cores.

Access Pattern Comparison (MTR_SLC, mode 3, batch 16)
"""""""""""""""""""""""""""""""""""""""""""""""""""""

.. list-table::
   :widths: 20 15 15 15 15
   :header-rows: 1

   * - Pattern
     - Min (us)
     - Avg (us)
     - Max (us)
     - Std (us)
   * - Sequential
     - 32.8
     - 188.0
     - 423.2
     - 24.9
   * - Random
     - 38.9
     - 210.8
     - 527.6
     - 31.9

Sequential access is ~10% faster on average than random on the MTR_SLC device,
consistent with the device's internal read-ahead and sequential prefetch logic.

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

Run the hardware setup fixture, then execute the sweep for each vendor and
transfer size:

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
     --size 4096 --seed 1 -n 10

   # Run IONIC sweep (example: 4 KiB, 10 iters)
   sudo env LD_LIBRARY_PATH="${LIB}" \
     build/tests/unit/rdma-ep/test-rdma-loopback \
     --provider ionic \
     --device rocm-rdma-ionic0 \
     --size 4096 --seed 1 -n 10

Queue memory placement can be selected per-run:

.. code-block:: bash

   # Host coherent (default, used by IONIC)
   sudo env LD_LIBRARY_PATH="${LIB}" \
     build/tests/unit/rdma-ep/test-rdma-loopback \
     --provider ionic \
     --device rocm-rdma-ionic0 \
     --size 4096 --seed 1 -n 10 \
     --queue-mem host

Or use the convenience script which iterates over multiple seeds and computes
statistics automatically:

.. code-block:: bash

   PROVIDER=bnxt TRANSFER_SIZE=4096 LFSR_SEED=1 \
     ITERATIONS=10 \
     scripts/test/test-rdma-ep-xio-loopback.sh

NVMe-EP smoke test (requires root and an NVMe device that is **not** the
rootfs):

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

NVMe-EP performance tests:

.. code-block:: bash

   # Run all NVMe CTests on a device
   sudo ROCXIO_NVME_DEVICE=/dev/nvme2 \
     XIO_TESTER=$(pwd)/build/xio-tester \
     ctest --test-dir build -L nvme \
     --output-on-failure

   # GPU-initiated: single-op latency, mode 3
   sudo env LD_LIBRARY_PATH=/opt/rocm/lib \
     HSA_FORCE_FINE_GRAIN_PCIE=1 \
     build/xio-tester nvme-ep \
     --controller /dev/nvme2 \
     --memory-mode 3 \
     --read-io 128 --batch-size 1 --less-timing

   # GPU-initiated: sustained throughput
   sudo env LD_LIBRARY_PATH=/opt/rocm/lib \
     HSA_FORCE_FINE_GRAIN_PCIE=1 \
     build/xio-tester nvme-ep \
     --controller /dev/nvme2 \
     --memory-mode 3 \
     --read-io 128 --batch-size 16 \
     --num-queues 16 --less-timing --infinite

   # fio CPU baseline (io_uring, QD=32)
   sudo fio --name=bw \
     --filename=/dev/nvme2n1 \
     --ioengine=io_uring --direct=1 \
     --bs=4k --iodepth=32 --rw=randread \
     --runtime=30 --time_based \
     --group_reporting --output-format=json

   # fio CPU baseline (sync, QD=1 latency)
   sudo fio --name=lat \
     --filename=/dev/nvme2n1 \
     --ioengine=sync --direct=1 \
     --bs=512 --iodepth=1 --rw=randread \
     --runtime=30 --time_based \
     --group_reporting --output-format=json
