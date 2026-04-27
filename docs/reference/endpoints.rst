.. meta::
  :description: Learn about the endpoints used in ROCm XIO which define hardware interfaces and protocols
  :keywords: ROCm, documentation, endpoints, XIO

******************
ROCm XIO endpoints
******************

Endpoints define hardware interfaces and protocols for different IO
devices. Each endpoint provides its own queue-entry formats and IO
semantics.

List available endpoints
------------------------

.. code-block:: bash

   ./build/xio-tester --list-endpoints

``test-ep`` -- test endpoint
----------------------------

A software-only endpoint for validating the XIO framework. No hardware
required.

.. code-block:: bash

   sudo ./build/xio-tester test-ep --verbose

``nvme-ep`` -- NVMe endpoint
----------------------------

Implements NVMe command submission (SQE) and completion (CQE) handling.
Supports Read and Write commands with configurable IO patterns and
doorbell batching. The ``--access-pattern`` flag controls LBA ordering
and defaults to ``random``.

.. code-block:: bash

   export HSA_FORCE_FINE_GRAIN_PCIE=1
   sudo ./build/xio-tester nvme-ep \
     --controller /dev/nvme0 \
     --read-io 8 --verbose

Key features:

- Direct GPU-to-NVMe submission via memory-mapped queues
- Sequential and pseudo-random LBA access patterns
- Configurable queue depth, IO size, and batch size
- Multi-queue parallelism with ``--num-queues``

Doorbell Batching (``--batch-size``)
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

``--batch-size`` controls SQEs per doorbell ring: ``1`` (default)
submits one SQE at a time, ``0`` submits all at once, any other
value ``N`` batches ``N`` SQEs per doorbell.

When ``N > 1``, each SQE is prepared by a separate GPU thread.
Thread 0 acts as a coordinator: it rings the SQ doorbell, polls
CQEs, and rings the CQ doorbell. The kernel launches ``N + 1``
threads, which may span multiple wavefronts within a single thread
block. The upper bound on ``N`` is
``min(queue_length - 1, maxThreadsPerBlock - 1)`` (typically 1023
when using the default queue length).

Dynamic shared memory is used for per-thread batch timing, so there
is no fixed array ceiling.

.. code-block:: bash

   # 16 reads, 4 SQEs per doorbell (4 rounds)
   sudo ./build/xio-tester nvme-ep \
     --controller /dev/nvme0 \
     --read-io 16 --batch-size 4

   # Multi-wavefront: 128 SQEs per doorbell
   sudo ./build/xio-tester nvme-ep \
     --controller /dev/nvme0 \
     --read-io 256 --batch-size 128 \
     --queue-length 256

   # Infinite reads, 8 SQEs per doorbell
   sudo ./build/xio-tester nvme-ep \
     --controller /dev/nvme0 \
     --read-io 1 --batch-size 8 \
     --infinite --less-timing

Multi-queue parallelism (``--num-queues``)
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

``--num-queues N`` (default 1) creates ``N`` independent NVMe I/O
queue pairs. Each queue gets its own GPU kernel on a separate HIP
stream, its own data buffers, and its own doorbell offset. Queue
IDs are allocated as a contiguous range ending at the auto-detected
(or explicit ``--queue-id``) value.

.. code-block:: bash

   # 2 independent queues, each doing 32 reads
   sudo ./build/xio-tester nvme-ep \
     --controller /dev/nvme0 \
     --read-io 32 --num-queues 2

   # 4 queues with batched doorbell writes
   sudo ./build/xio-tester nvme-ep \
     --controller /dev/nvme0 \
     --read-io 64 --num-queues 4 \
     --batch-size 16

Timing semantics
^^^^^^^^^^^^^^^^

When ``--batch-size > 1`` or ``--num-queues > 1``, per-operation
timing arrays are not meaningful. The endpoint automatically forces
lightweight ``XioTimingStats`` mode (min/max/sum/count). For
multi-queue runs, per-queue stats are allocated independently and
aggregated after all kernels finish.

Doorbell modes
^^^^^^^^^^^^^^

The NVMe endpoint supports two doorbell delivery modes. Choosing the
right one depends on whether the NVMe device is a real PCIe endpoint
or an emulated device inside a virtual machine.

**Direct BAR0 (default -- use with real hardware)**
  The GPU writes directly to the NVMe controller's BAR0 doorbell
  registers. This is the correct mode when the NVMe SSD is passed
  through to the VM (or bare-metal host) via ``vfio-pci`` or is
  otherwise a real PCIe endpoint. Direct BAR0 avoids the extra
  latency of the MMIO bridge and is the lowest-overhead path.

  The direct path uses ``__threadfence_system()`` for cross-device
  ordering, which is sufficient on CDNA (MI-series) GPUs. On RDNA
  (consumer Radeon) GPUs, direct BAR0 doorbell writes have been
  observed to cause coherence issues in independent testing. If you
  experience hangs on RDNA hardware, try rebuilding with aggressive
  ISA-level fencing:

  .. code-block:: bash

     cmake -DXIO_DOORBELL_FENCE_AGGRESSIVE=ON ..


**PCI MMIO bridge (emulated devices in VMs only)**
  Routes doorbell writes through a QEMU virtual PCI device that
  forwards them to the emulated NVMe controller's BAR0. This mode
  is *essential* when the NVMe device is emulated by QEMU (for example,
  the built-in ``nvme`` device model) because the emulated BAR0
  lives in QEMU's address space and cannot be reached by a direct
  GPU store. Enable with ``--pci-mmio-bridge``:

  .. code-block:: bash

     sudo ./build/xio-tester nvme-ep \
       --controller /dev/nvme0 \
       --read-io 8 --pci-mmio-bridge

  Do *not* use the PCI MMIO bridge with real NVMe endpoints
  passed through via vfio-pci. The bridge adds an unnecessary PCIe
  hop and QEMU processing overhead that hurts latency and
  throughput with no benefit -- real hardware already exposes its
  BAR0 directly to the GPU.

``rdma-ep`` -- RDMA endpoint
----------------------------

GPU-Direct RDMA endpoint supporting four major vendors:

===========  ====================================
Vendor       Hardware
===========  ====================================
MLX5         Mellanox/NVIDIA ConnectX (IB/RoCE)
BNXT_RE      Broadcom NetXtreme RDMA Engine
IONIC        Pensando Ionic RDMA (SmartNIC)
rocm-ernic   AMD Emulated RDMA NIC
===========  ====================================

By default, the endpoint runs in loopback mode, which exercises the
full RDMA path on a single node without requiring a second machine.
Pass ``--no-loopback`` to run in two-node mode where a real remote
peer is expected.

Loopback mode (default, single node):

.. code-block:: bash

   sudo ./build/xio-tester rdma-ep

Two-node mode (requires a remote peer):

.. code-block:: bash

   sudo ./build/xio-tester rdma-ep --no-loopback

All vendors support GPU-direct doorbell ringing using system-scope
atomics. No HSA memory locking is needed (unlike NVMe, RDMA NICs
support this pattern natively).

Architecture
^^^^^^^^^^^^

The RDMA endpoint is derived from the GDA (GPU-Direct Access)
backend in
`ROCm/rocSHMEM <https://github.com/ROCm/rocSHMEM>`_.
Key adaptations from the original rocSHMEM code:

- Decoupled from rocSHMEM internals (``HIPAllocator``,
  ``FreeList``, MPI, ``constants.hpp``)
- Simplified from a full PE mesh to a single-endpoint model
  (1 QP + 1 CQ per connection instead of
  ``(max_contexts + 1) * num_pes`` QPs)
- Wrapped in ``rdma_ep`` namespace with vendor sub-namespaces
- Consolidated duplicated vendor control flow into shared
  abstractions

Each vendor provides the same function signatures as static methods
on an ``Ops`` class, dispatched at compile time:

.. code-block:: cpp

   rdma_ep::bnxt::Ops::post_wqe_rma(qp, ...)
   rdma_ep::mlx5::Ops::post_wqe_rma(qp, ...)
   rdma_ep::ionic::Ops::post_wqe_rma(qp, ...)

The active vendor is selected by the CMake options ``GDA_BNXT``,
``GDA_MLX5``, ``GDA_IONIC``, or ``GDA_ERNIC``.

Two-node RDMA test
^^^^^^^^^^^^^^^^^^

For cross-node testing with two Thor 2 NICs:

.. code-block:: bash

   bash tests/unit/rdma-ep/run-2node-test.sh \
     <server-node> <client-node>

Or manually on each node:

.. code-block:: bash

   # Node A (server):
   ./build/tests/unit/rdma-ep/test-rdma-2node --server

   # Node B (client):
   ./build/tests/unit/rdma-ep/test-rdma-2node \
     --client --server-host <server-hostname>

The test uses TCP over the management network for QP info exchange
and RDMA over the Thor 2 fabric for data transfer.

BNXT DV kernel module
^^^^^^^^^^^^^^^^^^^^^

The BNXT vendor backend requires a patched ``bnxt_re`` kernel
module built via DKMS:

.. code-block:: bash

   sudo kernel/bnxt/setup-bnxt-re-dkms.sh

This downloads stock ``bnxt_re`` source, applies patches
0001--0008, and builds/installs via DKMS. Patch 0007 extends the
udata ABI so the DV userspace can pass SQ/RQ buffer VAs through
the write-based verbs path. After installation:

.. code-block:: bash

   sudo modprobe -r bnxt_re && sudo modprobe bnxt_re

Troubleshooting
^^^^^^^^^^^^^^^

``ibv_cmd_create_qp_ex2() failed: 14`` (EFAULT)
   The DKMS module was built without the DV QP handling code. The
   kernel falls back to its own buffer sizing, causing
   ``ib_umem_get`` to fail. Re-run ``setup-bnxt-re-dkms.sh`` and
   reload the module.

``ibv_cmd_create_qp_ex2() failed: 22`` (EINVAL)
   The DV QP udata patch is missing. Verify with
   ``grep -c DV_QP_ENABLE
   /usr/src/rocm-xio-bnxt-re-0.1.0-g<rev>/ib_verbs.c``
   (expect >= 1). Re-run ``setup-bnxt-re-dkms.sh`` if missing.

``Could not open libbnxt_re.so``
   ``LD_LIBRARY_PATH`` is missing the rdma-core install directory.
   When running through CTest this is set automatically; for manual
   runs add ``build/_deps/rdma-core/install/lib``.

``DV Modify QP error: 110`` (ETIMEDOUT)
   The IPv4-mapped GID is not yet populated. Verify the IP address
   is assigned (``ip addr show``), the static neighbor entry exists
   (``ip neigh show``), and the GID ``::ffff:c612:0001`` appears
   in ``/sys/class/infiniband/*/ports/1/gids/``. Wait a few
   seconds after module reload for the GID table to populate.

``sdma-ep`` -- SDMA endpoint
----------------------------

GPU-initiated DMA transfers using AMD hardware SDMA engines. Based
on the anvil library from AMD's RAD team.

Hardware requirements
^^^^^^^^^^^^^^^^^^^^^

- AMD Instinct GPUs
- ROCm 6.0 and latar with hsakmt library
- P2P mode: multi-GPU system with XGMI/Infinity Fabric
- Single-GPU mode: use ``--to-host``

Usage examples
^^^^^^^^^^^^^^

Single-GPU (SDMA to pinned host memory):

.. code-block:: bash

   sudo ./build/xio-tester sdma-ep p2p \
     --to-host -n 10 -v

P2P (two GPUs, default GPU 0 to GPU 1):

.. code-block:: bash

   sudo ./build/xio-tester sdma-ep p2p -n 100 -v

With data verification (LFSR pattern):

.. code-block:: bash

   sudo ./build/xio-tester sdma-ep p2p \
     --to-host --verify -n 10 -v

Larger transfer size:

.. code-block:: bash

   sudo ./build/xio-tester sdma-ep p2p \
     --to-host -n 8 -s 1048576 --verify

Transfer size (``-s``) accepts bytes or suffixes: ``4k``, ``1M``,
``2G``. Suffixes are power-of-2 (KiB, MiB, GiB). Value must be a
multiple of 4.

Host-side setup (Library API)
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Applications that want to use shader-initiated SDMA from their own
GPU kernels (outside the xio-tester) use the three-step host-side
setup API:

.. code-block:: cpp

   #include "sdma-ep.h"

   // 1. Initialize the SDMA subsystem (HSA + KFD)
   sdma_ep::initEndpoint();

   // 2. Create a connection (peer access + engine)
   sdma_ep::SdmaConnectionInfo conn;
   sdma_ep::createConnection(0, 1, &conn);

   // 3. Create an SDMA queue
   sdma_ep::SdmaQueueInfo qInfo;
   sdma_ep::createQueue(0, 1, &qInfo);

   // Pass qInfo.deviceHandle to your GPU kernel
   myKernel<<<1,1>>>(
     static_cast<sdma_ep::SdmaQueueHandle*>(
       qInfo.deviceHandle),
     dst, src, size);

   // Cleanup (nullifies handle; hsakmt/HSA resources
   // are released at process exit by AnvilLib destructor)
   sdma_ep::destroyQueue(&qInfo);
   sdma_ep::shutdownEndpoint();

See the :doc:`api` page for full function signatures and cleanup
semantics.

Device-side operations (Kernel API)
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

GPU kernels use the ``sdma_ep::`` device-side functions to issue
SDMA transfers, signal completion, and wait for results. All
functions are ``__device__ __forceinline__`` and operate on a
``SdmaQueueHandle`` reference.

.. code-block:: cpp

   #include "sdma-ep.h"

   __global__ void myKernel(
       sdma_ep::SdmaQueueHandle* handle,
       void* dst, void* src, size_t size,
       uint64_t* signal) {

     // DMA copy (non-blocking)
     sdma_ep::put(*handle, dst, src, size);

     // Copy with completion signal
     sdma_ep::putSignal(
       *handle, dst, src, size, signal);

     // Wait for remote signal
     sdma_ep::waitSignal(signal, 1);

     // Wait for all submitted ops
     sdma_ep::quiet(*handle);
   }

Available operations:

======================  ==============================
Function                Description
======================  ==============================
``put()``               Linear DMA copy
``putTile()``           2D sub-window DMA copy
``signal()``            Atomic increment via SDMA
``putSignal()``         Copy + signal (batched)
``putSignalCounter()``  Copy + signal + counter
``waitSignal()``        Spin-poll signal >= expected
``flush()``             Wait for specific op
``quiet()``             Wait for all submitted ops
======================  ==============================

Limitations
^^^^^^^^^^^

- Hardware-only (no emulation mode)
- P2P requires at least two GPUs
- Requires hsakmt (KFD kernel driver interface)

Environment variables
---------------------

On Radeon GPUs (RX series), set the following before
running any tests:

.. code-block:: bash

   export HSA_FORCE_FINE_GRAIN_PCIE=1

This enables fine-grained memory coherence required for GPU-to-CPU
memory visibility. Without it the GPU will encounter page faults
when accessing host memory.

On AMD instinct GPUs (MI300X, etc.) this is typically not
required.
