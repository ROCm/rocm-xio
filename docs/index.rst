rocm-xio: ROCm Library for GPU-Initiated IO
============================================

Introduction
------------

rocm-xio provides an API for Accelerator-Initiated IO (XIO) for AMD GPU
``__device__`` code. It enables AMD GPUs to perform direct IO operations to
hardware devices without CPU intervention.

Supported Endpoints
-------------------

============  ==================  ================================
Endpoint      Device              Description
============  ==================  ================================
``nvme-ep``   NVMe SSDs           NVMe command submission /
                                  completion
``rdma-ep``   RDMA NICs           GPU-Direct RDMA (4 vendors)
``sdma-ep``   AMD SDMA engines    GPU-initiated DMA transfers
``test-ep``   Software-only       Framework validation endpoint
============  ==================  ================================

Architecture
------------

All endpoints derive from the :cpp:class:`xio::XioEndpoint` base class and
share a common :cpp:class:`xio::XioEndpointConfig` configuration structure.
The endpoint registry allows runtime discovery and instantiation via
``xio::createEndpoint()``.

Quick Start
-----------

.. code-block:: bash

   sudo apt install rocm-hip-sdk rocminfo \
     libcli11-dev cmake libdrm-dev libhsa-runtime-dev
   mkdir -p build
   cmake -S . -B build
   cmake --build build --target all

   export HSA_FORCE_FINE_GRAIN_PCIE=1
   sudo ./build/xio-tester nvme-ep \
     --controller /dev/nvme0 \
     --read-io 50 --write-io 50 --verbose

.. toctree::
   :maxdepth: 2
   :caption: User Guide

   building
   endpoints
   kernel-module
   memory-modes

.. toctree::
   :maxdepth: 2
   :caption: API Reference

   api

License
-------

MIT License
