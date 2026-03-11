Memory Modes and Coherence
==========================

This page documents memory coherence considerations when using rocm-xio on
different AMD GPU families.

Fine-Grained vs. Coarse-Grained Memory
---------------------------------------

**Coarse-grained** memory means that a store to a memory location may only
become visible to the CPU once the GPU kernel finishes. **Fine-grained** memory
means stores are visible with system-level coherence (not just at kernel
completion).

On consumer Radeon GPUs, fine-grained PCIe memory is only available when the
environment variable is set:

.. code-block:: bash

   export HSA_FORCE_FINE_GRAIN_PCIE=1

On MI-series accelerators (MI300X, etc.) fine-grained memory is available by
default.

Host Memory Allocation
----------------------

``hipHostMalloc()`` comes in two flavours:

1. **Pinned** -- pages are locked in physical memory. This is almost always
   what rocm-xio needs because device access to an unmapped pageable page
   triggers an XNACK and associated PTE updates, adding latency.
2. **Pageable / migratable** -- useful for very large VMAs where device code
   accesses memory randomly and sporadically.

On MI300X the host allocation should be **UNCACHED**.

Device-to-Host Visibility
-------------------------

If ``__device__`` code stores to host memory, the following are needed so a
host CPU core can see the store:

- ``hipHostMalloc()`` for the allocation
- ``volatile`` qualification on the host-side pointer
- ``__threadfence_system()`` on the device side

Host-to-Device Visibility
-------------------------

If ``__host__`` code stores to host memory that a GPU core reads,
``hipHostMalloc()`` alone is typically sufficient because it marks the memory as
uncached, making CPU writes visible at the system level.

Thread Fences
-------------

- ``__threadfence()`` -- sufficient on MI300X for intra-device ordering
- ``__threadfence_system()`` -- needed on Radeon GPUs for cross-device
  (GPU-to-CPU) ordering
