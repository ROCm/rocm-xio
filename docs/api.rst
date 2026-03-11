API Reference
=============

This page documents the rocm-xio public C++ API, extracted from annotated
source headers by Doxygen and rendered via Breathe.

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

.. doxygenstruct:: sdma_ep::SdmaEpConfig
   :members:
   :undoc-members:

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
