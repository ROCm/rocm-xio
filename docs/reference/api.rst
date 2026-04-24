.. meta::
  :description: Learn about the APIs used in ROCm XIO
  :keywords: ROCm, documentation, API, XIO

**********************
ROCm XIO API reference
**********************

This page documents the ROCm XIO public C++ API, extracted
from annotated source headers by Doxygen and rendered in Sphinx
via ``rocm_docs.doxygen`` (Breathe directives).

Core Framework
--------------

Base Classes
^^^^^^^^^^^^

.. doxygenclass:: xio::XioEndpoint
   :members:
   :undoc-members:

.. doxygenstruct:: xio::XioEndpointConfig
   :members:
   :undoc-members:

.. doxygenstruct:: xio::XioTimingStats
   :members:
   :undoc-members:

Endpoint Registry
^^^^^^^^^^^^^^^^^

.. doxygenstruct:: EndpointInfo
   :members:
   :undoc-members:

.. doxygenfunction:: xio::createEndpoint(EndpointType type)

.. doxygenfunction:: xio::createEndpoint(const std::string &endpointName)

Both ``createEndpoint`` overloads return a null pointer when the type or
name is unknown. Callers must check the result before use.

Memory and Buffer Management
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

.. doxygenstruct:: xio::xioBufferInfo
   :members:
   :undoc-members:

.. doxygenstruct:: xio::xioQueueSetup
   :members:
   :undoc-members:

.. doxygenfunction:: xio::allocateQueue

.. doxygenfunction:: xio::freeQueue

.. doxygenfunction:: xio::allocateGpuAccessibleBuffer

.. doxygenfunction:: xio::freeGpuAccessibleBuffer

.. doxygenfunction:: xio::setupQueueForGpu

.. doxygenfunction:: xio::registerMemoryForGpu

Doorbell and MMIO
^^^^^^^^^^^^^^^^^

.. doxygenstruct:: xio::pci_mmio_bridge_ring_meta
   :members:
   :undoc-members:

.. doxygenstruct:: xio::pci_mmio_bridge_command
   :members:
   :undoc-members:

.. doxygenfunction:: xio::mapPciBar

.. doxygenfunction:: xio::genPciMmioBridgeCmd

Device Helpers
^^^^^^^^^^^^^^

.. doxygenfunction:: xio::printDeviceInfo

.. doxygenfunction:: xio::checkKernelModuleLoaded

.. doxygenfunction:: xio::loadKernelModule

.. doxygenfunction:: xio::detectBdfFromDevice

NVMe Endpoint
-------------

.. doxygenstruct:: xio::nvme_ep::nvmeEpConfig
   :members:
   :undoc-members:

.. doxygenstruct:: xio::nvme_ep::nvmeIoParams
   :members:
   :undoc-members:

.. doxygenstruct:: xio::nvme_ep::nvmeDoorbellParams
   :members:
   :undoc-members:

.. doxygenstruct:: xio::nvme_ep::nvmeBufferParams
   :members:
   :undoc-members:

.. doxygenstruct:: xio::DataPatternParams
   :members:
   :undoc-members:

RDMA Endpoint
-------------

.. doxygenstruct:: xio::rdma_ep::RdmaEpConfig
   :members:
   :undoc-members:

Vendor WQE and CQE layouts (``struct rdma_wqe``, ``struct rdma_cqe``) live in
generated RDMA headers under ``src/endpoints/rdma-ep/`` (see
``scripts/build/generate-rdma-vendor-headers.sh``). They are not present until
those headers are generated, so they are omitted from this auto-generated API
page.

SDMA Endpoint
-------------

Configuration
^^^^^^^^^^^^^

.. doxygenstruct:: xio::sdma_ep::SdmaEpConfig
   :members:
   :undoc-members:

Host-Side Setup
^^^^^^^^^^^^^^^

.. doxygenstruct:: xio::sdma_ep::SdmaConnectionInfo
   :members:
   :undoc-members:

.. doxygenstruct:: xio::sdma_ep::SdmaQueueInfo
   :members:
   :undoc-members:

.. doxygenfunction:: xio::sdma_ep::initEndpoint

.. doxygenfunction:: xio::sdma_ep::shutdownEndpoint

.. doxygenfunction:: xio::sdma_ep::createConnection

.. doxygenfunction:: xio::sdma_ep::createQueue

.. doxygenfunction:: xio::sdma_ep::destroyQueue

Device-Side Operations
^^^^^^^^^^^^^^^^^^^^^^

.. doxygenfunction:: xio::sdma_ep::put

.. doxygenfunction:: xio::sdma_ep::putTile

.. doxygenfunction:: xio::sdma_ep::signal

.. doxygenfunction:: xio::sdma_ep::putSignal

.. doxygenfunction:: xio::sdma_ep::putSignalCounter

.. doxygenfunction:: xio::sdma_ep::putCounter

.. doxygenfunction:: xio::sdma_ep::signalCounter

.. doxygenfunction:: xio::sdma_ep::waitSignal

.. doxygenfunction:: xio::sdma_ep::waitCounter

.. doxygenfunction:: xio::sdma_ep::flush

.. doxygenfunction:: xio::sdma_ep::quiet

Validation
^^^^^^^^^^

.. doxygenfunction:: xio::sdma_ep::validateConfig

.. doxygenfunction:: xio::sdma_ep::getIterations

Test Endpoint
-------------

.. doxygenstruct:: xio::test_ep::TestEpConfig
   :members:
   :undoc-members:

.. doxygenstruct:: xio::test_ep::test_sqe
   :members:
   :undoc-members:

.. doxygenstruct:: xio::test_ep::test_cqe
   :members:
   :undoc-members:

Kernel Module IOCTL Structures
------------------------------

.. doxygenstruct:: rocm_xio_vram_req
   :members:
   :undoc-members:

.. doxygenstruct:: rocm_xio_register_queue_addr_req
   :members:
   :undoc-members:

.. doxygenstruct:: rocm_xio_register_buffer_req
   :members:
   :undoc-members:

.. doxygenstruct:: rocm_xio_mmio_bridge_shadow_req
   :members:
   :undoc-members:

.. doxygenstruct:: rocm_xio_alloc_contig_req
   :members:
   :undoc-members:

.. doxygenstruct:: rocm_xio_free_contig_req
   :members:
   :undoc-members:
