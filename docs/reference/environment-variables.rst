.. meta::
  :description: Learn about the environment variables used in ROCm XIO
  :keywords: ROCm, documentation, environment, variables, XIO

******************************
ROCm XIO environment variables
******************************

ROCm XIO reads several environment variables at runtime to
control library behaviour. All ROCm XIO variables use the
``ROCXIO_`` prefix, following ROCm ecosystem conventions.

Logging
-------

``ROCXIO_LOG_LEVEL``
  Controls the verbosity of library diagnostic output.
  Integer value from 0 to 5. The default is **2** (warn).

  ======  ==========  ====================================
  Value   Level       Description
  ======  ==========  ====================================
  0       None        Suppress all library output
  1       Error       Fatal errors only
  2       Warn        Errors and warnings (default)
  3       Info        Informational messages
  4       Debug       Detailed debug diagnostics
  5       Trace       Maximum verbosity
  ======  ==========  ====================================

  Example:

  .. code-block:: bash

     ROCXIO_LOG_LEVEL=3 sudo ./build/xio-tester nvme-ep \
       --controller /dev/nvme0 --read-io 10

``ROCXIO_VERBOSE``
  Boolean. Accepts ``"1"`` or ``"true"`` (case-insensitive)
  to enable verbose output from the library. The xio-tester
  ``-v`` flag also sets this internally.

  .. code-block:: bash

     ROCXIO_VERBOSE=1 sudo ./build/xio-tester test-ep

Device configuration
--------------------

``ROCXIO_NVME_DEVICE``
  Default NVMe controller device path (for example,
  ``/dev/nvme0``). Used by unit tests when no
  ``--controller`` argument is supplied. Falls back to the
  legacy ``NVME_DEVICE`` environment variable for backward
  compatibility.

  .. code-block:: bash

     ROCXIO_NVME_DEVICE=/dev/nvme2 ctest -R nvme

Interaction with ROCm variables
-------------------------------

ROCm XIO also respects standard ROCm environment variables:

``HSA_FORCE_FINE_GRAIN_PCIE``
  Must be set to ``1`` for PCIe peer-to-peer DMA operations
  with fine-grained device memory.

``ROCM_PATH``
  ROCm installation prefix. Defaults to ``/opt/rocm`` when
  not set.

``HIP_VISIBLE_DEVICES``
  Restrict visible GPU devices for the HIP runtime.
