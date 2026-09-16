.. meta::
  :description: Build and run the rocm-xio fio engine for GPU-initiated NVMe benchmarking
  :keywords: ROCm, documentation, XIO, fio, NVMe, benchmark, GPU, engine

.. _fio-engine:

*****************************
Use the rocm-xio fio engine
*****************************

The rocm-xio fio engine drives GPU-initiated NVMe I/O through
:ref:`nvme-ep` directly from `fio <https://fio.readthedocs.io>`_.
It allows standard fio job files to benchmark the GPU-to-NVMe path
alongside conventional CPU-driven engines, using the same measurement
and reporting infrastructure.

The engine uses a **persistent GPU kernel** model: one
``gpuKernelPersistent`` instance runs for the lifetime of each fio file
(one NVMe queue).  The CPU posts work items to a GPU-accessible ring
buffer; the GPU kernel picks them up, executes NVMe I/O, and signals
completion.  This eliminates per-operation kernel launch overhead and
enables pipelining of multiple in-flight operations.

.. note::

   The engine requires the rocm-xio kernel module, a supported AMD GPU,
   and a non-mounted NVMe controller node (e.g. ``/dev/nvme1``).  It
   operates on the **controller** device node, not on a namespace
   (``/dev/nvme1n1``).  See :ref:`kernel-module` for module setup.

Prerequisites
=============

* ROCm ≥ 7.0 with HIP runtime
* ``fio`` source tree (the engine is an external ``.so``; it is not
  compiled into fio itself)
* ``librocm-xio.so`` built from this repository (see :ref:`building`)
* rocm-xio kernel module loaded (``/dev/rocm-xio`` present)
* A non-mounted NVMe drive accessible as a controller node

Build the engine
================

The engine consists of two source files in ``docker/rocm-xio-engine/``:

* ``rocm-xio-hip.hip`` -- HIP/C++ translation unit compiled with
  ``hipcc``; exports ``extern "C"`` shims that wrap the rocm-xio
  library.
* ``rocm-xio.c`` -- plain C fio engine vtable, compiled with ``gcc``.

Build ``librocm-xio.so`` first (shared library is required):

.. code-block:: bash

   cmake -S . -B build-shared \
     -DBUILD_SHARED_LIBS=ON \
     -DCMAKE_BUILD_TYPE=Release \
     -DGDA_BNXT=OFF -DGDA_MLX5=OFF -DGDA_IONIC=OFF -DGDA_ERNIC=OFF \
     -DBUILD_TESTING=OFF \
     -DROCM_PATH=/opt/rocm
   cmake --build build-shared --target rocm-xio -j "$(nproc)"

Then build the engine shared object (three steps because the HIP shim
and the C engine use different compilers):

.. code-block:: bash

   ROCM=/opt/rocm
   FIO=/path/to/fio          # fio source tree
   ROCMXIO=/path/to/rocm-xio # this repository

   # 1. Compile HIP shim
   $ROCM/bin/hipcc --offload-arch=gfx1201 -fPIC \
     -DAXIIO_ENDPOINT_NVME \
     -I$ROCMXIO/src/include \
     -I$ROCMXIO/src/endpoints/nvme-ep \
     -I$ROCMXIO/src/common \
     -I$ROCMXIO/src/endpoints/common \
     -I$FIO -I$ROCM/include \
     -c $ROCMXIO/docker/rocm-xio-engine/rocm-xio-hip.hip \
     -o /tmp/rocm-xio-hip.o

   # 2. Compile C engine
   gcc -std=gnu99 -fPIC -I$FIO -I$ROCM/include \
     -c $ROCMXIO/docker/rocm-xio-engine/rocm-xio.c \
     -o /tmp/rocm-xio-c.o

   # 3. Link engine shared object
   $ROCM/bin/hipcc --offload-arch=gfx1201 -fPIC -shared \
     -o /tmp/rocm-xio.so \
     /tmp/rocm-xio-hip.o /tmp/rocm-xio-c.o \
     -L$ROCMXIO/build-shared -lrocm-xio \
     -Wl,-rpath,$ROCMXIO/build-shared \
     -L$ROCM/lib -Wl,-rpath,$ROCM/lib \
     -lamdhip64 -lpthread

Alternatively, build and run inside the Docker image (see
:ref:`docker-build`).

.. _fio-engine-options:

Engine options
==============

The engine registers as ``rocm-xio`` and exposes four engine-specific
options in addition to standard fio settings.

.. list-table::
   :header-rows: 1
   :widths: 20 15 65

   * - Option
     - Default
     - Description
   * - ``gpu_id``
     - ``0``
     - HIP device index to use for I/O operations.
   * - ``queue_id``
     - ``0``
     - NVMe I/O queue ID.  ``0`` = auto-detect: job N is assigned
       ``max_queue_id − N`` so parallel ``--thread`` jobs each own a
       distinct queue without collision.
   * - ``queue_depth``
     - ``64``
     - NVMe submission/completion queue depth in entries (power of 2,
       maximum 4096).
   * - ``memory_mode``
     - ``8``
     - ``XIO_MEM_MODE_*`` flags controlling where SQ, CQ, and data
       buffers are placed.  ``0`` = host-coherent memory; ``8`` = GPU
       VRAM for the data buffer (+10% IOPS versus mode 0).

Standard fio options that affect the engine:

.. list-table::
   :header-rows: 1
   :widths: 20 80

   * - Option
     - Effect
   * - ``iodepth``
     - Number of ops simultaneously in-flight per queue.  ``iodepth=1``
       works but the GPU work-ring polling overhead dominates.
       ``iodepth=4``–``16`` pipelines ops, reducing effective overhead
       and raising throughput 3–4×.
   * - ``numjobs``
     - Number of parallel fio jobs, each owning a separate NVMe queue
       and HIP stream.  Must be used with ``--thread`` (shared address
       space) because each job maps BAR0 into the same process GPU
       context.
   * - ``filename``
     - Path to the **NVMe controller node** (e.g. ``/dev/nvme2``), not
       a namespace path.  The engine opens the controller directly for
       queue management.
   * - ``bs``
     - Block size.  4K–512K supported.  1M requires a multi-page PRP
       list that is not yet implemented.
   * - ``rw``
     - ``read``, ``randread``, ``write``, ``randwrite`` all supported.

Run the engine
==============

Load the engine with ``ioengine=external:/path/to/rocm-xio.so``.  The
following examples use the MTR SLC drive (non-mounted, ``/dev/nvme1``)
with ``queue_id=32`` (the known-good value for this controller whose
``queue_count=33``).

.. warning::

   Always target non-mounted NVMe drives.  The engine hijacks NVMe
   hardware queues from the kernel driver; writing to a mounted drive
   **will corrupt the filesystem**.  Use the stable device identity path
   (e.g. ``/dev/disk/by-id/nvme-MTR_SLC_16GB_0400000E3CBC``) to avoid
   accidentally targeting the root drive.

4K sequential read — baseline
------------------------------

.. code-block:: bash

   sudo LD_LIBRARY_PATH=/path/to/build-shared:/opt/rocm/lib \
     fio \
     --ioengine=external:/tmp/rocm-xio.so \
     --filename=/dev/nvme1 \
     --rw=read --bs=4k --iodepth=1 \
     --numjobs=1 --queue_id=32 --queue_depth=64 \
     --size=512m --runtime=30 --time_based=1 \
     --direct=1 --name=baseline

Maximise IOPS — persistent kernel pipeline
-------------------------------------------

Use ``iodepth≥4`` to pipeline multiple operations and ``numjobs``
parallel threads to drive multiple NVMe queues simultaneously:

.. code-block:: bash

   sudo LD_LIBRARY_PATH=/path/to/build-shared:/opt/rocm/lib \
     fio \
     --ioengine=external:/tmp/rocm-xio.so \
     --filename=/dev/nvme1 \
     --rw=read --bs=4k --iodepth=8 \
     --numjobs=4 --thread --group_reporting=1 \
     --queue_id=0 --queue_depth=64 --memory_mode=8 \
     --size=2g --runtime=30 --time_based=1 \
     --direct=1 --name=peak

128K sequential read — bandwidth measurement
---------------------------------------------

.. code-block:: bash

   sudo LD_LIBRARY_PATH=/path/to/build-shared:/opt/rocm/lib \
     fio \
     --ioengine=external:/tmp/rocm-xio.so \
     --filename=/dev/nvme1 \
     --rw=read --bs=128k --iodepth=8 \
     --numjobs=2 --thread --group_reporting=1 \
     --queue_id=0 --queue_depth=64 --memory_mode=8 \
     --size=2g --runtime=30 --time_based=1 \
     --direct=1 --name=bw

.. _fio-engine-docker:
.. _docker-build:

Docker image
============

A self-contained Docker image builds fio from upstream HEAD together
with the engine.  See the Dockerfile comments for usage:

.. code-block:: bash

   docker build \
     -f docker/Dockerfile.fio \
     -t rocm-xio-fio:latest \
     .

   docker run --rm --privileged \
     --device /dev/rocm-xio \
     --device /dev/nvme1 \
     --device /dev/kfd \
     --device /dev/dri \
     rocm-xio-fio:latest \
     fio /opt/rocm-xio-fio/jobs/nvme1-read.fio

Pre-written job files are installed at ``/opt/rocm-xio-fio/jobs/`` in
the image.

Performance expectations
========================

The following figures are measured on the test node documented in
:ref:`fio-engine-results`.

.. list-table::
   :header-rows: 1
   :widths: 15 15 15 15 40

   * - bs
     - iodepth
     - numjobs
     - IOPS
     - Notes
   * - 4K
     - 8
     - 4
     - ~190K
     - Stable peak; ~50% of CPU io_uring
   * - 4K
     - 1
     - 8
     - ~60K
     - Limited by GPU dispatch overhead
   * - 128K
     - 8
     - 4
     - ~15K
     - ~1 GB/s
   * - 512K
     - 4
     - 2
     - ~2K
     - ~1 GB/s peak bandwidth
   * - CPU io_uring QD32
     - 32
     - 1
     - ~381K
     - Reference CPU path

The GPU engine at iodepth=8 numjobs=4 delivers approximately **50% of
CPU io_uring** throughput while consuming **zero CPU cycles** on the I/O
data path.

See :ref:`fio-engine-results` for full benchmark data and historical
trend charts.

Limitations
===========

* ``iodepth=1`` performance is limited by GPU work-ring polling overhead
  (~45 µs PCIe round-trip); use ``iodepth≥4`` for best results.
* Block sizes above 512K require a multi-page PRP list chain that is not
  yet implemented.
* ``numjobs`` without ``--thread`` is unsupported: each process would
  need its own HIP context and BAR0 mapping.
* The first NVMe operation on a newly-created queue may stall for up to
  ~30 s if the queue ID was previously used without a snapshot being
  captured (one-time NVMe controller timeout from the kernel module's
  resurrection mechanism).  Subsequent operations are unaffected.
