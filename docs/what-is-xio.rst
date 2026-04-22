.. meta::
  :description: ROCm XIO license
  :keywords: ROCm, documentation

*****************
What is ROCm XIO?
*****************

ROCm XIO provides an API for Accelerator-Initiated IO (XIO) for AMD
GPU ``__device__`` code. It enables AMD GPUs to perform direct IO
operations to hardware devices without CPU intervention.

Supported endpoints
===================

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
============

All endpoints derive from the :cpp:class:`xio::XioEndpoint` base
class and share a common :cpp:class:`xio::XioEndpointConfig`
configuration structure. The endpoint registry allows runtime
discovery and instantiation via ``xio::createEndpoint()``.

Quick Start
===========

.. describe the flow instead of providing the instructions

.. code-block:: bash

   sudo apt install rocm-hip-sdk rocminfo \
     cmake libdrm-dev libhsa-runtime-dev libcli11-dev
   mkdir -p build
   cmake -S . -B build
   cmake --build build --target all

   export HSA_FORCE_FINE_GRAIN_PCIE=1
   sudo ./build/xio-tester nvme-ep \
     --controller /dev/nvme0 \
     --read-io 50 --verbose


