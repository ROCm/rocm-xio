Endpoints
=========

Endpoints define hardware interfaces and protocols for different IO devices.
Each endpoint provides its own queue entry formats and IO semantics.

Listing Available Endpoints
---------------------------

.. code-block:: bash

   ./build/xio-tester --list-endpoints

test-ep -- Test Endpoint
------------------------

A software-only endpoint for validating the XIO framework. No hardware required.

.. code-block:: bash

   sudo ./build/xio-tester test-ep --verbose

nvme-ep -- NVMe Endpoint
-------------------------

Implements NVMe command submission (SQE) and completion (CQE) handling.
Supports Read and Write commands with configurable IO patterns.

.. code-block:: bash

   export HSA_FORCE_FINE_GRAIN_PCIE=1
   sudo ./build/xio-tester nvme-ep \
     --controller /dev/nvme0 \
     --read-io 50 --write-io 50 --verbose

Key features:

- Direct GPU-to-NVMe submission via memory-mapped queues
- Sequential and pseudo-random LBA access patterns
- Configurable queue depth, IO size, and iteration count

rdma-ep -- RDMA Endpoint
-------------------------

GPU-Direct RDMA endpoint supporting four major vendors:

===========  ====================================
Vendor       Hardware
===========  ====================================
MLX5         Mellanox/NVIDIA ConnectX (IB/RoCE)
BNXT_RE      Broadcom NetXtreme RDMA Engine
IONIC        Pensando Ionic RDMA (SmartNIC)
rocm-ernic   AMD Emulated RDMA NIC
===========  ====================================

Emulation mode:

.. code-block:: bash

   sudo ./build/xio-tester rdma-ep

Hardware mode:

.. code-block:: bash

   sudo ./build/xio-tester rdma-ep --hardware

All vendors support GPU-direct doorbell ringing
using system-scope atomics.  No HSA memory locking
is needed (unlike NVMe, RDMA NICs support this
pattern natively).

Architecture
^^^^^^^^^^^^

The RDMA endpoint is derived from the GDA
(GPU-Direct Access) backend in
`ROCm/rocSHMEM <https://github.com/ROCm/rocSHMEM>`_.
Key adaptations from the original rocSHMEM code:

- Decoupled from rocSHMEM internals
  (``HIPAllocator``, ``FreeList``, MPI,
  ``constants.hpp``)
- Simplified from a full PE mesh to a
  single-endpoint model (1 QP + 1 CQ per connection
  instead of ``(max_contexts + 1) * num_pes`` QPs)
- Wrapped in ``rdma_ep`` namespace with vendor
  sub-namespaces
- Consolidated duplicated vendor control flow into
  shared abstractions

Each vendor provides the same function signatures
as static methods on an ``Ops`` class, dispatched
at compile time:

.. code-block:: cpp

   rdma_ep::bnxt::Ops::post_wqe_rma(qp, ...)
   rdma_ep::mlx5::Ops::post_wqe_rma(qp, ...)
   rdma_ep::ionic::Ops::post_wqe_rma(qp, ...)

The active vendor is selected by the CMake options
``GDA_BNXT``, ``GDA_MLX5``, ``GDA_IONIC``, or
``GDA_ERNIC``.

Two-node RDMA test
^^^^^^^^^^^^^^^^^^

For cross-node testing with two Thor 2 NICs:

.. code-block:: bash

   bash tests/unit/rdma-ep/run-2node-test.sh \
     <server-node> <client-node>

Or manually on each node:

.. code-block:: bash

   # Node A (server):
   ./build/tests/unit/rdma-ep/test-rdma-2node \
     --server --gid-index 3

   # Node B (client):
   ./build/tests/unit/rdma-ep/test-rdma-2node \
     --client --server-host <server-hostname> \
     --gid-index 3

GID index 3 is required for cross-subnet Thor 2
routing (RoCEv2 IPv4-mapped).  The test uses TCP
over the management network for QP info exchange
and RDMA over the Thor 2 fabric for data transfer.

BNXT DV kernel module
^^^^^^^^^^^^^^^^^^^^^

The BNXT vendor backend requires a patched
``bnxt_re`` kernel module built via DKMS:

.. code-block:: bash

   sudo kernel/bnxt/setup-bnxt-re-dkms.sh

This downloads stock ``bnxt_re`` source, applies
patches 0001--0007, and builds/installs via DKMS.
Patch 0007 extends the udata ABI so the DV
userspace can pass SQ/RQ buffer VAs through the
write-based verbs path.  After installation:

.. code-block:: bash

   sudo modprobe -r bnxt_re && sudo modprobe bnxt_re

Troubleshooting
^^^^^^^^^^^^^^^

``ibv_cmd_create_qp_ex2() failed: 14`` (EFAULT)
   The DKMS module was built without the DV QP
   handling code.  The kernel falls back to its own
   buffer sizing, causing ``ib_umem_get`` to fail.
   Re-run ``setup-bnxt-re-dkms.sh`` and reload the
   module.

``ibv_cmd_create_qp_ex2() failed: 22`` (EINVAL)
   The DV QP udata patch is missing.  Verify with
   ``grep -c DV_QP_ENABLE
   /usr/src/rocm-xio-bnxt-re-0.1/ib_verbs.c``
   (expect >= 1).  Re-run ``setup-bnxt-re-dkms.sh``
   if missing.

``Could not open libbnxt_re.so``
   ``LD_LIBRARY_PATH`` is missing the rdma-core
   install directory.  When running through CTest
   this is set automatically; for manual runs add
   ``build/_deps/rdma-core/install/lib``.

``DV Modify QP error: 110`` (ETIMEDOUT)
   The IPv4-mapped GID is not yet populated.
   Verify the IP address is assigned
   (``ip addr show``), the static neighbor entry
   exists (``ip neigh show``), and the GID
   ``::ffff:c612:0001`` appears in
   ``/sys/class/infiniband/*/ports/1/gids/``.
   Wait a few seconds after module reload for the
   GID table to populate.

sdma-ep -- SDMA Endpoint
-------------------------

GPU-initiated DMA transfers using AMD hardware SDMA engines. Based on the
anvil library from AMD's RAD team.

Hardware Requirements
^^^^^^^^^^^^^^^^^^^^^

- AMD Instinct datacenter GPUs
- ROCm 6.0+ with hsakmt library
- P2P mode: multi-GPU system with XGMI/Infinity Fabric
- Single-GPU mode: use ``--to-host``

Usage Examples
^^^^^^^^^^^^^^

Single-GPU (SDMA to pinned host memory):

.. code-block:: bash

   sudo ./build/xio-tester sdma-ep \
     --to-host -n 10 -v

P2P (two GPUs, default GPU 0 to GPU 1):

.. code-block:: bash

   sudo ./build/xio-tester sdma-ep -n 100 -v

With data verification (LFSR pattern):

.. code-block:: bash

   sudo ./build/xio-tester sdma-ep \
     --to-host --verify -n 10 -v

Larger transfer size:

.. code-block:: bash

   sudo ./build/xio-tester sdma-ep \
     --to-host -n 8 -s 1048576 --verify

Transfer size (``-s``) accepts bytes or suffixes: ``4k``, ``1M``, ``2G``.
Suffixes are power-of-2 (KiB, MiB, GiB). Value must be a multiple of 4.

Limitations
^^^^^^^^^^^

- Hardware-only (no emulation mode)
- P2P requires at least two GPUs
- Requires hsakmt (KFD kernel driver interface)

Environment Variables
---------------------

On consumer Radeon GPUs (RX series), set the following before running any
tests:

.. code-block:: bash

   export HSA_FORCE_FINE_GRAIN_PCIE=1

This enables fine-grained memory coherence required for GPU-to-CPU memory
visibility. Without it the GPU will encounter page faults when accessing host
memory.

On MI-series accelerators (MI300X, etc.) this is typically not required.
