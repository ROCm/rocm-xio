Memory Modes, Allocation, and Coherence
=======================================

This page documents the unified memory allocation API, memory
coherence considerations, and the DMA-BUF export architecture
in rocm-xio.

Fine-Grained vs. Coarse-Grained Memory
---------------------------------------

**Coarse-grained** memory means that a store to a memory
location may only become visible to the CPU once the GPU
kernel finishes. **Fine-grained** memory means stores are
visible with system-level coherence (not just at kernel
completion).

On consumer Radeon GPUs, fine-grained PCIe memory is only
available when the environment variable is set:

.. code-block:: bash

   export HSA_FORCE_FINE_GRAIN_PCIE=1

On MI-series accelerators (MI300X, etc.) fine-grained memory
is available by default.

Host Memory Allocation
----------------------

All host allocation in rocm-xio goes through
``allocHostMemory()`` with ``XIO_HOST_MEM_*`` flags:

- ``XIO_HOST_MEM_MAPPED`` (0x0) --
  ``hipHostMalloc(Mapped)`` with ``malloc`` fallback.
  Default for queues, timing buffers, and GPU-accessible
  host memory.
- ``XIO_HOST_MEM_COHERENT`` (0x1) -- adds
  ``hipHostMallocCoherent`` for cross-device visibility
  (e.g. 2-node RDMA buffers on MI250).
- ``XIO_HOST_MEM_PINNED`` (0x2) -- ``posix_memalign`` +
  ``hipHostRegister``. Required for RDMA verbs paths
  where ``ib_umem_get`` needs real CPU pages.
- ``XIO_HOST_MEM_PLAIN`` (0x4) -- raw ``malloc``. Used
  for NVMe admin buffers and control structures that
  don't need GPU access.
- ``XIO_HOST_MEM_DEFAULT`` (0x8) --
  ``hipHostMalloc(Default)`` without ``Mapped`` flag.
  Used for SDMA host destination buffers.

On MI300X the host allocation should be **UNCACHED**.

.. list-table:: Host Allocation Call Sites
   :header-rows: 1
   :widths: 25 35 40

   * - Purpose
     - Flag
     - Callers
   * - Queues (host)
     - ``XIO_HOST_MEM_MAPPED``
     - ``xio-common.hip``
   * - RDMA data buffer
     - ``XIO_HOST_MEM_PINNED`` or
       ``XIO_DEVICE_MEM_FINE_GRAINED``
     - ``rdma-ep.hip`` (per ``--memory-mode`` bit 3)
   * - BNXT/ERNIC SQ/RQ
     - ``XIO_HOST_MEM_PINNED``
     - ``bnxt/ernic-backend.cpp``
   * - SDMA host dst
     - ``XIO_HOST_MEM_DEFAULT``
     - ``sdma-ep.hip``
   * - NVMe admin
     - ``XIO_HOST_MEM_PLAIN``
     - ``nvme-ep.hip``
   * - Timing buffers
     - ``XIO_HOST_MEM_MAPPED``
     - ``xio-tester.cpp``
   * - 2-node RDMA buffer
     - ``XIO_HOST_MEM_MAPPED | COHERENT``
     - ``rdma-ep.hip``

The only remaining raw host allocations are the
``ibv_alloc_parent_domain`` callbacks (constrained by the
libibverbs ABI).

Device Memory Allocation
-------------------------

All device (VRAM) allocation goes through
``allocDeviceMemory()`` with ``XIO_DEVICE_MEM_*`` flags:

- ``XIO_DEVICE_MEM_FINE_GRAINED`` (0x0) -- HSA region
  alloc with fine-grained coherence. Default for data
  buffers that need system-level visibility.
- ``XIO_DEVICE_MEM_COARSE_GRAINED`` (0x1) -- HSA region
  alloc, coarse-grained. Stores only become visible at
  kernel completion.
- ``XIO_DEVICE_MEM_UNCACHED`` (0x2) --
  ``hipExtMallocWithFlags(Uncached)``. Required for RDMA
  CQ buffers and SDMA P2P signal/counter memory.
- ``XIO_DEVICE_MEM_VMEM`` (0x4) -- HIP Virtual Memory
  Management (reserve + map + access). No device sync on
  free, per-buffer P2P access.
- ``XIO_DEVICE_MEM_HIP`` (0x8) -- plain ``hipMalloc``.
  DMA-BUF exportable. Used for queues, atomic scratch
  buffers, and GPU-side data structures.

.. list-table:: Device Allocation Call Sites
   :header-rows: 1
   :widths: 25 35 40

   * - Purpose
     - Flag
     - Callers
   * - Data buffers
     - ``XIO_DEVICE_MEM_FINE_GRAINED``
     - ``xio-common.hip``
   * - Queues (device)
     - ``XIO_DEVICE_MEM_HIP``
     - ``xio-common.hip``
   * - BNXT/ERNIC CQ
     - ``XIO_DEVICE_MEM_UNCACHED``
     - ``bnxt/ernic-backend.cpp``
   * - SDMA buffers
     - ``XIO_DEVICE_MEM_HIP`` / ``UNCACHED``
     - ``sdma-ep.hip``
   * - Atomic scratch
     - ``XIO_DEVICE_MEM_HIP``
     - ``queue-pair.hip``
   * - MLX5 BF/UAR
     - ``hsa_amd_memory_lock_to_pool`` (HSA-only)
     - ``mlx5-backend.cpp``
   * - SDMA Anvil
     - ``XIO_DEVICE_MEM_HIP`` / ``UNCACHED``
     - ``anvil.hip``

The only remaining raw HIP/HSA device allocation is the
MLX5 BF/UAR mapping (``hsa_amd_memory_lock_to_pool``) and
the ``ibv_alloc_parent_domain`` callbacks which are
constrained by the libibverbs ABI.

Memory Mode CLI Flags
---------------------

The ``--memory-mode`` CLI option (0--15) controls
placement:

- Bit 0 (``XIO_MEM_MODE_SQ_DEVICE``): submission queue
  in VRAM
- Bit 1 (``XIO_MEM_MODE_CQ_DEVICE``): completion queue
  in VRAM
- Bit 2 (``XIO_MEM_MODE_DOORBELL_DEVICE``): doorbell in
  VRAM
- Bit 3 (``XIO_MEM_MODE_DATA_DEVICE``): data buffer in
  VRAM

When a bit is **set**, the corresponding buffer is
allocated with ``allocDeviceMemory()`` (VRAM); when
**clear**, with ``allocHostMemory()`` (system RAM).

NVMe-EP Memory Mode
^^^^^^^^^^^^^^^^^^^^

All four bits are honoured independently.  The SQ and CQ
are allocated by ``createQueue()`` based on bits 0 and 1.
The doorbell is placed per bit 2 via a kernel-module MMIO
bridge path.  Data buffers use bit 3 for host vs. device
P2PDMA allocation.

RDMA-EP Memory Mode
^^^^^^^^^^^^^^^^^^^^

.. list-table::
   :header-rows: 1
   :widths: 10 25 65

   * - Bit
     - Effect
     - Details
   * - 0
     - SQ **and** CQ placement
     - Maps to ``QueueMemMode::DEVICE_VRAM`` (bit set)
       vs ``HOST_COHERENT`` (bit clear).  Controls the
       ``ibv_alloc_parent_domain`` allocator used by
       ``ibv_create_qp_ex`` for SQ/RQ buffers and is
       also used by ionic for CQ allocation.  BNXT and
       ERNIC allocate CQ via their DV API (VRAM,
       uncached).
   * - 1
     - *(reserved for future per-queue CQ control)*
     - Currently ignored.  A future change could split
       bit 0 (SQ only) and bit 1 (CQ only) by routing
       the ``resource_type`` callback in the parent
       domain allocator, or by switching vendors to
       explicit per-queue allocation.
   * - 2
     - *(not applicable)*
     - RDMA doorbells are always MMIO writes to
       NIC-mapped BAR regions; memory mode does not
       apply.
   * - 3
     - Data buffer placement
     - When set, the loopback data buffer (src + dst)
       is allocated with ``allocDeviceMemory()``
       (fine-grained VRAM).  When clear, it is
       allocated with ``allocHostMemory()``
       (``XIO_HOST_MEM_PINNED``).  The LFSR fill and
       verify patterns are staged through a temporary
       host buffer when data is on device.

Mirrored Host+Device Pairs
---------------------------

``allocDeviceMemoryPair()`` allocates a host+device pair
(``XIO_HOST_MEM_PLAIN`` + ``XIO_DEVICE_MEM_HIP``) for
objects that are constructed on the host then copied to the
GPU with ``hipMemcpy``. Used for GPU QueuePair staging in
the RDMA endpoint.

DMA-BUF Export
--------------

rocm-xio calls ``hsa_amd_portable_export_dmabuf`` directly
(v1, no flags) at **four call sites**, all routed through
the centralized ``exportDmabuf()`` wrapper:

1. ``src/common/ibv-wrapper.cpp`` --
   ``IBVWrapper::reg_mr()`` exports GPU memory as dmabuf,
   then calls ``ibv_reg_dmabuf_mr`` for RDMA MR
   registration. Used for GPU atomic buffers only, not the
   main data path.

2. ``src/common/xio-common.hip`` --
   ``exportRegVramBuf()`` exports VRAM for NVMe physical
   address resolution via the kernel module ioctl.

3. ``src/endpoints/rdma-ep/bnxt/bnxt-backend.cpp`` --
   Exports CQ buffer for BNXT Direct Verbs UMEM
   registration with ``BNXT_RE_DV_UMEM_FLAGS_DMABUF``.

4. ``src/endpoints/rdma-ep/rocm-ernic/ernic-backend.cpp``
   -- Same pattern for ERNIC CQ buffers.

HSA API v2
~~~~~~~~~~

ROCm 7.1.0 ships ``hsa_amd_portable_export_dmabuf_v2``
(``/opt/rocm/include/hsa/hsa_ext_amd.h``) which adds a
``flags`` argument of type
``hsa_amd_dma_buf_mapping_type_t``:

- ``HSA_AMD_DMABUF_MAPPING_TYPE_NONE`` (0) -- default,
  identical to v1.
- ``HSA_AMD_DMABUF_MAPPING_TYPE_PCIE`` (1) -- PCIe
  mapping type, potentially relevant for P2P paths.

The v1 API is documented as equivalent to v2 with
``HSA_AMD_DMABUF_MAPPING_TYPE_NONE``.

Additionally, ``hsa_amd_portable_close_dmabuf()`` provides
proper cleanup of dmabuf file descriptors, replacing raw
``close(fd)`` calls.

HIP Virtual Memory Management
------------------------------

ROCm 7 introduces `HIP Virtual Memory Management
<https://rocm.docs.amd.com/projects/HIP/en/latest/how-to/
hip_runtime_api/memory_management/virtual_memory.html>`_
built on HSA ``hsa_amd_vmem_*`` APIs. Key benefits for
rocm-xio:

1. **No device sync on free** --
   ``hipMemUnmap``/``hipMemRelease``/``hipMemAddressFree``
   do not synchronize the device, unlike ``hipFree``.

2. **Per-buffer P2P access** -- ``hipMemSetAccess``
   replaces device-wide ``hipDeviceEnablePeerAccess``
   with per-buffer, per-device access control.

3. **Dynamic growth without copy** -- Buffers can be
   extended by reserving additional VA and mapping new
   physical pages.

4. **dmabuf compatibility** --
   ``hsa_amd_vmem_export_shareable_handle()`` exports
   vmem allocations as dmabuf file descriptors.

The ``requestedHandleTypes`` field must be set to
``hipMemHandleTypePosixFileDescriptor`` at allocation time
to enable later dmabuf export:

.. code-block:: cpp

   hipMemAllocationProp prop = {};
   prop.type = hipMemAllocationTypePinned;
   prop.location.type = hipMemLocationTypeDevice;
   prop.location.id = gpuId;
   prop.requestedHandleTypes =
       hipMemHandleTypePosixFileDescriptor;

   size_t granularity;
   hipMemGetAllocationGranularity(
       &granularity, &prop,
       hipMemAllocationGranularityMinimum);
   size_t allocSize =
       ((size + granularity - 1) / granularity)
       * granularity;

   hipMemCreate(&handle, allocSize, &prop, 0);
   hipMemAddressReserve(&ptr, allocSize, 0, 0, 0);
   hipMemMap(ptr, allocSize, 0, handle, 0);

   hipMemAccessDesc access = {};
   access.location.type = hipMemLocationTypeDevice;
   access.location.id = gpuId;
   access.flags = hipMemAccessFlagsProtReadWrite;
   hipMemSetAccess(ptr, allocSize, &access, 1);

Device-to-Host Visibility
-------------------------

If ``__device__`` code stores to host memory, the
following are needed so a host CPU core can see the store:

- ``hipHostMalloc()`` for the allocation
- ``volatile`` qualification on the host-side pointer
- ``__threadfence_system()`` on the device side

Host-to-Device Visibility
-------------------------

If ``__host__`` code stores to host memory that a GPU core
reads, ``hipHostMalloc()`` alone is typically sufficient
because it marks the memory as uncached, making CPU writes
visible at the system level.

Thread Fences
-------------

- ``__threadfence()`` -- sufficient on MI300X for
  intra-device ordering
- ``__threadfence_system()`` -- needed on Radeon GPUs for
  cross-device (GPU-to-CPU) ordering

Comparison with rocSHMEM
------------------------

rocSHMEM has a full allocator hierarchy
(``HIPAllocator``, ``FreeList``, ``Pow2Bins``) managing a
symmetric heap shared across PEs. Each allocator knows how
to allocate memory and export it as dmabuf for RDMA
registration.

rocm-xio deliberately removed this abstraction (see
``src/endpoints/rdma-ep/README.md``: "Decoupled from
rocshmem internals"). rocm-xio uses a single-endpoint
model with no symmetric heap, making a full allocator
hierarchy unnecessary.

Upstream Tracking
-----------------

Monitor ``ROCm/rocm-systems#3762`` for any breaking
changes to the HSA allocator interface that would require
rocm-xio changes.
