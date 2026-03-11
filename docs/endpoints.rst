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

All vendors support GPU-direct doorbell ringing using system-scope atomics. No
HSA memory locking is needed (unlike NVMe, RDMA NICs support this pattern
natively).

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
