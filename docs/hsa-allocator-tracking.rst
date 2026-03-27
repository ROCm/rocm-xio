HSA Memory Allocator Tracking
=============================

This document tracks the HSA memory allocator architecture in
rocSHMEM and assesses what changes are needed in rocm-xio.

Background
----------

rocSHMEM (now in ``ROCm/rocm-systems``) is extending its HSA
memory allocator to include an ``allocator`` argument that
specifies the memory mechanism and carries its own
``export_dmabuf`` method pointer. This investigation
determines whether rocm-xio needs similar changes.  See
`ROCm/rocm-systems#3762
<https://github.com/ROCm/rocm-systems/issues/3762>`_ for
upstream details.

Current dmabuf Usage in rocm-xio
--------------------------------

rocm-xio calls ``hsa_amd_portable_export_dmabuf`` directly
(v1, no flags) at **four call sites**:

1. ``src/common/ibv-wrapper.cpp`` --
   ``IBVWrapper::reg_mr()`` exports GPU memory as dmabuf,
   then calls ``ibv_reg_dmabuf_mr`` for RDMA MR
   registration.  Used for GPU atomic buffers only, not the
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
----------

ROCm 7.1.0 ships ``hsa_amd_portable_export_dmabuf_v2``
(``/opt/rocm/include/hsa/hsa_ext_amd.h``) which adds a
``flags`` argument of type
``hsa_amd_dma_buf_mapping_type_t``:

- ``HSA_AMD_DMABUF_MAPPING_TYPE_NONE`` (0) -- default,
  identical to v1.
- ``HSA_AMD_DMABUF_MAPPING_TYPE_PCIE`` (1) -- PCIe mapping
  type, potentially relevant for P2P paths.

The v1 API is documented as equivalent to v2 with
``HSA_AMD_DMABUF_MAPPING_TYPE_NONE``.

Additionally, ``hsa_amd_portable_close_dmabuf()`` provides
proper cleanup of dmabuf file descriptors, replacing raw
``close(fd)`` calls.

Device Memory Allocation Patterns
----------------------------------

rocm-xio has **no unified device allocator**.  GPU memory
allocation is scattered across six distinct strategies:

.. list-table::
   :header-rows: 1
   :widths: 25 35 40

   * - Purpose
     - Method
     - File
   * - Data buffers
     - ``hsa_memory_allocate`` via ``allocDeviceMemory()``
     - ``xio-common.hip``
   * - Queues (device)
     - ``hipMalloc``
     - ``xio-common.hip``
   * - BNXT/ERNIC CQ
     - ``hipExtMallocWithFlags(uncached)``
     - ``bnxt/ernic-backend.cpp``
   * - SDMA buffers
     - ``hipMalloc`` / ``hipExtMallocWithFlags(uncached)``
     - ``sdma-ep.hip``
   * - Atomic scratch
     - ``hipMalloc``
     - ``queue-pair.hip``
   * - MLX5 BF/UAR
     - ``hsa_amd_memory_lock_to_pool``
     - ``mlx5-backend.cpp``

Host Memory Allocation Patterns
--------------------------------

Host allocation uses **five distinct patterns**:

.. list-table::
   :header-rows: 1
   :widths: 25 35 40

   * - Purpose
     - Method
     - File
   * - Queues (host)
     - ``hipHostMalloc(Mapped)`` / ``malloc`` fallback
     - ``xio-common.hip``
   * - RDMA data buffer
     - ``posix_memalign``
     - ``rdma-ep.hip``
   * - BNXT/ERNIC SQ/RQ
     - ``posix_memalign`` + ``hipHostRegister``
     - ``bnxt/ernic-backend.cpp``
   * - SDMA host dst
     - ``hipHostMalloc(Default)``
     - ``sdma-ep.hip``
   * - NVMe admin
     - ``malloc``
     - ``nvme-ep.hip``

Comparison with rocSHMEM
------------------------

rocSHMEM has a full allocator hierarchy
(``HIPAllocator``, ``FreeList``, ``Pow2Bins``) managing a
symmetric heap shared across PEs.  Each allocator knows how
to allocate memory and export it as dmabuf for RDMA
registration.

rocm-xio deliberately removed this abstraction (see
``src/endpoints/rdma-ep/README.md``: "Decoupled from
rocshmem internals").  rocm-xio uses a single-endpoint
model with no symmetric heap, making a full allocator
hierarchy unnecessary.

Assessment
----------

**Not needed:**

- Full allocator abstraction with ``export_dmabuf`` method
  pointer -- over-engineering for rocm-xio's simple
  single-endpoint model.
- Allocator argument threading -- rocm-xio allocates per
  endpoint with fixed strategies.

**Implemented (this changeset):**

- Centralized ``exportDmabuf()`` wrapper with v2 API
  support and ``hsa_amd_portable_close_dmabuf`` cleanup.
- Unified ``allocDeviceMemory()`` with flags for
  fine-grained, coarse-grained, uncached, and vmem
  allocation types.
- Unified ``allocHostMemory()`` / ``freeHostMemory()`` with
  flags for mapped, coherent, pinned, and plain allocation.
- HIP virtual memory integration for SDMA P2P buffers with
  per-buffer access control via ``hipMemSetAccess``.

HIP Virtual Memory Management
------------------------------

ROCm 7 introduces `HIP Virtual Memory Management
<https://rocm.docs.amd.com/projects/HIP/en/latest/how-to/
hip_runtime_api/memory_management/virtual_memory.html>`_
built on HSA ``hsa_amd_vmem_*`` APIs.  Key benefits for
rocm-xio:

1. **No device sync on free** --
   ``hipMemUnmap``/``hipMemRelease``/``hipMemAddressFree``
   do not synchronize the device, unlike ``hipFree``.

2. **Per-buffer P2P access** -- ``hipMemSetAccess``
   replaces device-wide ``hipDeviceEnablePeerAccess`` with
   per-buffer, per-device access control.

3. **Dynamic growth without copy** -- Buffers can be
   extended by reserving additional VA and mapping new
   physical pages.

4. **dmabuf compatibility** --
   ``hsa_amd_vmem_export_shareable_handle()`` exports vmem
   allocations as dmabuf file descriptors.

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

Upstream Tracking
-----------------

Monitor ``ROCm/rocm-systems#3762`` for any breaking
changes to the HSA allocator interface that would require
rocm-xio changes.
