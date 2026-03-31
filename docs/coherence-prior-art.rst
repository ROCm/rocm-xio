GPU-NVMe Doorbell Coherence: Prior Art
=======================================

This page documents findings from an independent
GPU-NVMe coherence study (referred to as the
"from-germany" reproduction case) and how they
informed rocm-xio's doorbell write strategy.

Background
----------

An external research team built a minimal GPU-driven
NVMe read path on AMD RDNA GPUs using a HIP port of
the open-source `libnvm`_ library.  Their setup:

- Single GPU thread writes NVMe SQEs to a submission
  queue (VRAM or host-pinned)
- GPU rings doorbell registers via direct BAR0 MMIO
  write
- GPU polls completion queue for phase-bit flip
- Commands are sequential: one SQE, one doorbell, poll,
  then the next

The study focused on **coherence of GPU MMIO writes to
NVMe BAR0 doorbell registers** and **visibility of
SQE writes across the PCIe coherence domain**.

Observed Failure Mode
---------------------

The team observed **deadlocks** where the SSD either:

1. Received an **invalid command** (SQE writes not
   fully visible when the doorbell fires), or
2. Received a **spurious doorbell** (doorbell write
   arrived without a corresponding valid SQE)

The GPU thread would then spin forever waiting for a
completion entry that the SSD never produced.

The deadlock was **extremely sensitive to timing**:
inserting a ``printf`` after the MMIO write delayed
execution enough for 1--2 commands to succeed before
the hang.

Fencing Approaches Attempted
-----------------------------

The team iterated through progressively heavier
memory ordering techniques.  None reliably eliminated
the deadlock on their RDNA hardware:

1. **Volatile pointer writes** -- deadlocked
   immediately on every run.

2. **``__threadfence_system()`` before and after** --
   still deadlocked.

3. **LLVM AMDGPU sequentially-consistent store model**
   (``s_waitcnt`` drains before/after a
   ``global_store_dword``) -- still deadlocked.

4. **Full cache invalidation suite** --
   ``buffer_gl0_inv``, ``buffer_gl1_inv``,
   ``s_gl1_inv``, ``s_dcache_inv`` plus triple
   ``s_waitcnt`` barriers and ``__threadfence_system()``
   -- still deadlocked.

5. **``global_atomic_swap`` for SQE copies** -- used
   atomics per dword with full fence sandwiches to
   guarantee write ordering -- still unreliable.

Implications for rocm-xio
--------------------------

The from-germany findings informed several rocm-xio
design decisions:

``hipHostRegisterIoMemory`` for BAR mappings
  ``mapPciBar()`` now uses ``hipHostRegisterIoMemory``
  instead of ``hipHostRegisterMapped`` when registering
  NVMe BAR0 space for GPU access.
  ``hipHostRegisterIoMemory`` is designed for MMIO
  regions and sets non-cacheable TLB attributes,
  avoiding GPU write-combine buffering that may
  reorder or coalesce doorbell writes.

``ringDoorbellFenced()``
  A new doorbell-write function (``xio.h``) provides
  RDNA-specific ISA-level fencing: explicit
  ``s_waitcnt`` / ``s_waitcnt_vscnt`` drains, a
  ``global_store_dword`` with GLC|SLC|DLC bypass flags,
  and GL0/GL1 cache invalidation.  On CDNA (MI-series)
  this falls back to ``__threadfence_system()``.  The
  ``XIO_DOORBELL_FENCE_AGGRESSIVE`` CMake option makes
  all ``ringDoorbell()`` calls use this path.

PCI MMIO bridge for emulated NVMe devices
  When the NVMe device is emulated by QEMU (not a real
  PCIe endpoint), the PCI MMIO bridge is essential
  because the emulated BAR0 cannot be reached by a
  direct GPU store.  For real NVMe SSDs passed through
  via vfio-pci, direct BAR0 remains the correct and
  lowest-latency path.

Coherence stress test
  ``tests/system/coherence/test-doorbell-coherence.hip``
  reproduces the from-germany access pattern (single
  GPU thread, sequential produce/consume, poll for
  completion) against host-pinned memory.

Bugs Found in the from-germany Code
-------------------------------------

During review, two bugs were identified in the
from-germany reproduction case:

1. **memset argument order** (``main.cpp:158``):
   ``memset(ptr, size, value)`` should be
   ``memset(ptr, value, size)``.

2. **Loop index shadowing** (``main.cpp:93``): the
   SQE copy loop's inner body uses the outer loop
   variable ``i`` instead of the inner variable ``j``,
   causing every inner iteration to write the same
   dword.

These bugs may have contributed to the observed
failures, though the underlying coherence ordering
concern remains valid.

Further Reading
---------------

- :doc:`memory-modes` -- fine-grained vs coarse-grained
  memory and ``__threadfence_system()`` guidance
- :doc:`endpoints` -- NVMe doorbell mode documentation
- `LLVM AMDGPU Memory Model`_ -- canonical reference
  for GPU memory ordering on GFX10/11

.. _libnvm: https://github.com/enfiskutensykkel/ssd-gpu-dma
.. _LLVM AMDGPU Memory Model: https://llvm.org/docs/AMDGPUUsage.html#memory-model-gfx10-gfx11
