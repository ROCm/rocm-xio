.. meta::
  :description: rocm-xio fio engine benchmark results
  :keywords: ROCm, documentation, XIO, fio, NVMe, benchmark, performance, IOPS

.. _fio-engine-results:

*****************************
fio engine benchmark results
*****************************

This page records performance measurements from the
:ref:`rocm-xio fio engine <fio-engine>` collected on a fixed reference
system.  Results are updated automatically by a scheduled CI job; see
:ref:`fio-engine-ci` for methodology details.

Test environment
================

.. list-table::
   :widths: 30 70
   :header-rows: 0

   * - **GPU**
     - AMD Radeon RX 9070 XT (gfx1201)
   * - **CPU**
     - AMD Ryzen Threadripper PRO 7955WX 16-Cores
   * - **NVMe (primary)**
     - WD_BLACK SN850X 2000GB (``/dev/nvme2``, unmounted)
   * - **NVMe (secondary)**
     - MTR_SLC_16GB (``/dev/nvme1``, unmounted)
   * - **OS**
     - Ubuntu 24.04 LTS
   * - **ROCm**
     - 7.14.1
   * - **Engine version**
     - v5 (persistent kernel, ``gpuKernelPersistent``)

Engine progression
==================

The following table summarises peak IOPS achieved at each development
milestone.  All measurements use nvme2 (WD_BLACK SN850X), 4K reads,
``memory_mode=8``.

.. list-table::
   :header-rows: 1
   :widths: 10 30 15 15 30

   * - Version
     - Mechanism
     - IOPS
     - vs CPU
     - Notes
   * - v1
     - ``gpuKernel``, synchronous, j=1
     - 2,200
     - 0.6%
     - Baseline; single kernel per op
   * - v2
     - Per-context HIP streams
     - 15,100
     - 4.0%
     - j=8 parallel streams
   * - v3
     - ``gpuKernelStateful`` (queue state persistence)
     - 63,000
     - 16.5%
     - 13× faster kernel, j=8
   * - v4
     - + shared BAR0 cache for multi-thread
     - 63,038
     - 16.5%
     - Stable at j=4 with mm=8
   * - **v5**
     - **Persistent GPU kernel** (``gpuKernelPersistent``)
     - **190,000**
     - **49.8%**
     - **j=4, iodepth=8; current**
   * - CPU baseline
     - io_uring QD32
     - 381,385
     - 100%
     - Reference

Latest results — WD_BLACK SN850X nvme2
=======================================

The table below is generated automatically by the
``fio-engine-benchmark`` CI workflow and committed to the repository.
The workflow runs weekly; the Sphinx build picks up the latest data.

.. include:: _fio-benchmark-results.rst

Full results by configuration
------------------------------

4K IOPS by iodepth and numjobs
-------------------------------

``rw=read``, ``bs=4k``, ``memory_mode=8``, 15 s runs.

.. list-table::
   :header-rows: 1
   :widths: 15 15 15 15 40

   * - iodepth
     - numjobs
     - IOPS
     - BW (MB/s)
     - Notes
   * - 1
     - 1
     - 17,200
     - 67
     - Work-ring PCIe poll bottleneck
   * - 1
     - 4
     - 17,200
     - 68
     - No gain — each thread still poll-bound
   * - 4
     - 1
     - 62,100
     - 242
     - 4-op pipeline hides poll overhead
   * - 4
     - 4
     - 178,000
     - 693
     - —
   * - 8
     - 2
     - 161,000
     - 631
     - —
   * - **8**
     - **4**
     - **190,000**
     - **743**
     - **Peak; ~50% of CPU io_uring**
   * - 16
     - 1
     - 69,100
     - 270
     - Single-thread peak

Block size sweep — nvme2, j=4, iodepth=8
-----------------------------------------

``rw=read``, ``memory_mode=8``.

.. list-table::
   :header-rows: 1
   :widths: 15 15 15 55

   * - bs
     - IOPS
     - BW (MB/s)
     - Notes
   * - 4K
     - 190,000
     - 743
     - —
   * - 8K
     - ~100,000
     - ~780
     - —
   * - 16K
     - ~50,000
     - ~780
     - —
   * - 32K
     - ~25,000
     - ~780
     - —
   * - 64K
     - ~12,000
     - ~750
     - —
   * - 128K
     - ~6,000
     - ~750
     - —
   * - 256K
     - ~3,000
     - ~750
     - —
   * - 512K
     - ~1,500
     - ~750
     - —
   * - 1M
     - N/A
     - N/A
     - PRP overflow — not yet supported

Bandwidth peaks at ~750 MB/s and is stable above 8K.  The GPU-initiated
path is bandwidth-limited by the PCIe work-ring signalling overhead, not
by the NVMe device.

Random vs sequential read
--------------------------

At the IOPS levels achievable via the GPU path, sequential and random
reads are indistinguishable: the NVMe controller serves both from its
internal cache at the same rate.

CPU baseline (reference) — nvme2n1
====================================

Measured with standard ``fio --ioengine=io_uring`` against the
namespace path ``/dev/nvme2n1``.

.. list-table::
   :header-rows: 1
   :widths: 15 15 15 15 40

   * - rw
     - bs
     - IOPS
     - BW (MB/s)
     - Notes
   * - seqread
     - 4K
     - 327,000
     - 1,276
     - QD32 single job
   * - randread
     - 4K
     - 381,385
     - 1,490
     - QD32 single job
   * - seqread
     - 128K
     - 53,361
     - 6,670
     - —
   * - randread
     - 128K
     - 55,168
     - 6,896
     - —

Bottleneck analysis
===================

.. code-block:: text

   NVMe device 4K read RTT (CPU QD1):    ~14 µs
   GPU work-ring PCIe poll overhead:      ~45 µs   (at iodepth=1)
   GPU work-ring overhead (pipelined):     ~3 µs   (at iodepth=8)
   Effective RTT at iodepth=8:           ~17 µs
   Effective IOPS/thread at iodepth=8:  ~59K

   CPU io_uring QD32 IOPS:             ~381K
   GPU persistent kernel peak IOPS:    ~190K
   GPU/CPU ratio:                       ~50%

The dominant overhead at ``iodepth=1`` is PCIe round-trip latency
reading ``item->seq`` in the work ring from GPU device code (pinned host
memory, ~45 µs).  At ``iodepth≥4``, multiple ops are simultaneously
in-flight at the NVMe controller while the GPU polls for completions,
hiding this overhead.  The GPU/CPU gap of ~50% is the combined effect of
the remaining work-ring overhead and the NVMe controller's per-queue
throughput limit when driven from device code.

Known work items
================

* **Fine-grained GPU memory for the work ring**: replacing pinned host
  memory with ``hipExtMallocWithFlags(hipDeviceMallocFinegrained)`` would
  give the GPU ~10 ns local reads vs ~45 µs PCIe reads, closing the
  ``iodepth=1`` gap and potentially matching CPU io_uring throughput per
  thread.  Blocked by the NVMe queue-snapshot mechanism (one-time 30 s
  stall on queue recreation).
* **Multi-page PRP list**: support for 1M block sizes.
* **Async batch**: cooperative ``driveEndpointWavefront`` mode would
  submit N SQEs per doorbell ring; blocked by queue-state persistence
  across kernel calls (same root cause as the fine-grained memory work).

.. _fio-engine-ci:

CI methodology
==============

Benchmarks are run on a self-hosted GitHub Actions runner attached to the
reference hardware described above.  The workflow
``.github/workflows/fio-engine-benchmark.yml`` runs on a weekly
schedule, executes the fio job files in ``docker/jobs/``, parses the
JSON output, and commits a results artifact that updates this page via
the Sphinx build in the ``docs-check`` workflow.

See the workflow file for details on job file selection, runtime
parameters, and result parsing.
