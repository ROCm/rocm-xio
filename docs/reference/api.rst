.. meta::
  :description: Learn about the APIs used in ROCm XIO
  :keywords: ROCm, documentation, API, XIO

**********************
ROCm XIO API reference
**********************

This page documents the ROCm XIO public C++ API, extracted
from annotated source headers by Doxygen and rendered via
Breathe.

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

.. doxygenstruct:: xio::nvme_ep::dataPatternParams
   :members:
   :undoc-members:

RDMA Endpoint
-------------

.. doxygenstruct:: rdma_ep::RdmaEpConfig
   :members:
   :undoc-members:

.. doxygenstruct:: rdma_wqe
   :members:
   :undoc-members:

.. doxygenstruct:: rdma_cqe
   :members:
   :undoc-members:

SDMA Endpoint
-------------

Configuration
^^^^^^^^^^^^^

.. doxygenstruct:: sdma_ep::SdmaEpConfig
   :members:
   :undoc-members:

Host-Side Setup
^^^^^^^^^^^^^^^

.. doxygenstruct:: sdma_ep::SdmaConnectionInfo
   :members:
   :undoc-members:

.. doxygenstruct:: sdma_ep::SdmaQueueInfo
   :members:
   :undoc-members:

.. doxygenfunction:: sdma_ep::initEndpoint

.. doxygenfunction:: sdma_ep::shutdownEndpoint

.. doxygenfunction:: sdma_ep::createConnection

.. doxygenfunction:: sdma_ep::createQueue

.. doxygenfunction:: sdma_ep::destroyQueue

Device-Side Operations
^^^^^^^^^^^^^^^^^^^^^^

.. doxygenfunction:: sdma_ep::put

.. doxygenfunction:: sdma_ep::putTile

.. doxygenfunction:: sdma_ep::signal

.. doxygenfunction:: sdma_ep::putSignal

.. doxygenfunction:: sdma_ep::putSignalCounter

.. doxygenfunction:: sdma_ep::putCounter

.. doxygenfunction:: sdma_ep::signalCounter

.. doxygenfunction:: sdma_ep::waitSignal

.. doxygenfunction:: sdma_ep::waitCounter

.. doxygenfunction:: sdma_ep::flush

.. doxygenfunction:: sdma_ep::quiet

Validation
^^^^^^^^^^

.. doxygenfunction:: sdma_ep::validateConfig

.. doxygenfunction:: sdma_ep::getIterations

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

.. doxygenstruct:: rocm_axiio_vram_req
   :members:
   :undoc-members:

.. doxygenstruct:: rocm_axiio_register_queue_addr_req
   :members:
   :undoc-members:

.. doxygenstruct:: rocm_axiio_register_buffer_req
   :members:
   :undoc-members:

.. doxygenstruct:: rocm_axiio_mmio_bridge_shadow_req
   :members:
   :undoc-members:
