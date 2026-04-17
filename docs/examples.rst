Examples
========

The ``examples/`` directory contains standalone projects that
demonstrate how to use the installed rocm-xio library. Each
example is a self-contained CMake project that uses
``find_package(rocm-xio)`` to locate the library.

Building Examples
-----------------

All examples follow the same build pattern. First install
rocm-xio to a temporary prefix, then configure and build the
example against that prefix:

.. code-block:: bash

   # Build and install rocm-xio
   cmake -S . -B build
   cmake --build build --target all
   cmake --install build --prefix /tmp/rocm-xio

   # Build an example (e.g. list-endpoints)
   cmake -S examples/list-endpoints \
     -B /tmp/list-endpoints-build \
     -DCMAKE_PREFIX_PATH="/tmp/rocm-xio;/opt/rocm"
   cmake --build /tmp/list-endpoints-build

CTest runs these automatically via the install-integration
test fixture (see :doc:`testing`).

Available Examples
------------------

find-package
^^^^^^^^^^^^

Configure-time smoke test. Verifies that
``find_package(rocm-xio)`` resolves the installed package
and prints the discovered version and paths. Contains no
source files.

**Requirements:** none (configure-time only).

list-endpoints
^^^^^^^^^^^^^^

Minimal example that lists all registered endpoints. Calls
``listAvailableEndpoints()`` from ``xio.h``. This is
CPU-only code compiled as HIP.

**Requirements:** none (CPU-only).

.. code-block:: bash

   /tmp/list-endpoints-build/list-endpoints

endpoint-info
^^^^^^^^^^^^^

Iterates the endpoint registry and prints each endpoint's
name, description, and type. Also validates that
``getEndpointName()`` and ``isValidEndpoint()`` agree with
the registry data. CPU-only.

**Requirements:** none (CPU-only).

.. code-block:: bash

   /tmp/endpoint-info-build/endpoint-info

sdma-ep-p2p
^^^^^^^^^^^^

GPU-initiated peer-to-peer DMA transfer via the SDMA
endpoint. Uses the public ``sdma_ep`` host-side API
(``initEndpoint()``, ``createConnection()``,
``createQueue()``) and device-side operations
(``putSignal()``, ``waitSignal()``, ``quiet()``) to perform
a GPU-to-GPU memory copy driven entirely from shader code.

**Requirements:**

- Two AMD GPUs with XGMI / Infinity Fabric P2P access
- Root access (hsakmt requires ``/dev/kfd``)
- Supported GPU architecture (see
  ``SDMA_EP_GFX_WHITELIST`` in the Alola test scripts)

.. code-block:: bash

   sudo /tmp/sdma-ep-p2p-build/sdma-ep-p2p

The example fills a 4 KiB source buffer on GPU 0 with
``0xAB``, transfers it to GPU 1 via SDMA, and verifies the
destination buffer contents.

sdma-ep-allgather
^^^^^^^^^^^^^^^^^^

MPI allgather collective driven entirely from GPU shader
code via SDMA. Each MPI rank owns one GPU and uses the
``sdma_ep`` device-side API to DMA its local input buffer
into the correct slot of every other rank's output buffer.
IPC memory handles are exchanged via ``MPI_Allgather`` so
each GPU can write directly into remote GPU memory.

This example is derived from the original
``shader-sdma-coll`` prototype and serves as a template for
building multi-process, multi-GPU SDMA collectives.

**Requirements:**

- N AMD GPUs with XGMI / Infinity Fabric P2P access
- MPI (OpenMPI, MPICH, etc.)
- Root access (hsakmt requires ``/dev/kfd``)
- Supported GPU architecture (see
  ``SDMA_EP_GFX_WHITELIST``)

.. code-block:: bash

   mpirun -np 2 sudo ./sdma-ep-allgather
   mpirun -np 4 sudo ./sdma-ep-allgather 8192

The optional argument sets the per-rank chunk size in
integers (default: 1024 = 4 KiB per rank). Each rank fills
its chunk with ``rank + 1`` and verifies that the gathered
output contains the correct values from all ranks.

nvme-ep-info
^^^^^^^^^^^^

Queries NVMe controller properties using the ``nvme_ep``
host-side API. Prints LBA size, namespace capacity, maximum
queue ID, and SMART/Health log data. Accepts an optional
device path argument (defaults to ``/dev/nvme0``).

**Requirements:**

- An NVMe device (e.g. ``/dev/nvme0``)
- Root access (NVMe admin commands require
  ``CAP_SYS_ADMIN``)

.. code-block:: bash

   sudo /tmp/nvme-ep-info-build/nvme-ep-info /dev/nvme0

Returns exit code 77 (CTest SKIP convention) when the NVMe
device cannot be opened, so it can be registered as a CTest
with graceful skip behavior.

Writing New Examples
--------------------

To add a new example:

1. Create a directory under ``examples/<name>/``.
2. Add a ``CMakeLists.txt`` that uses
   ``find_package(rocm-xio REQUIRED)`` and links against
   ``rocm-xio::rocm-xio``.
3. Add the source file(s) as ``.hip`` (even for CPU-only
   code, since rocm-xio headers use HIP types).
4. Register the example in
   ``tests/integration/CMakeLists.txt`` via
   ``xio_add_install_test()``. Use the ``RUN`` flag only if
   the example can run in CI without special hardware.
5. Document the example in this file.
