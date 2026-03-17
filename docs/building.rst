Building rocm-xio
=================

Dependencies
------------

.. code-block:: bash

   sudo apt install rocm-hip-sdk rocminfo libcli11-dev cmake \
     libdrm-dev libhsa-runtime-dev

Quick Start
-----------

.. code-block:: bash

   mkdir -p build
   cmake -S . -B build
   cmake --build build --target all

Output locations:

- Library: ``build/librocm-xio.a``
- Tester: ``build/xio-tester``

CMake Configuration Options
----------------------------

.. code-block:: bash

   # Specify GPU architecture (auto-detected if not specified)
   cmake -S . -B build -DOFFLOAD_ARCH=gfx942:xnack+

   # Specify ROCm installation path (default: /opt/rocm)
   cmake -S . -B build -DROCM_PATH=/opt/rocm-7.1.0

   # Build documentation (Sphinx + Breathe + Doxygen)
   cmake -S . -B build -DXIO_BUILD_DOCS=ON

CMake Build Targets
-------------------

Primary targets
^^^^^^^^^^^^^^^

.. code-block:: bash

   cmake --build build --target rocm-xio   # Library only
   cmake --build build --target xio-tester  # Tester only
   cmake --build build --target all         # Both (default)

Code generation targets
^^^^^^^^^^^^^^^^^^^^^^^

.. code-block:: bash

   cmake --build build --target endpoint-registry-generated
   cmake --build build --target nvme-ep-generated
   cmake --build build --target rdma-vendor-headers-generated
   cmake --build build --target fetch-nvme-headers
   cmake --build build --target fetch-rdma-headers
   cmake --build build --target fetch-external-headers

Testing targets
^^^^^^^^^^^^^^^

.. code-block:: bash

   ctest --preset unit       # CPU-only tests (CI)
   ctest --preset system     # GPU emulation tests
   ctest --preset hardware   # NIC + GPU tests
   ctest --preset sweep      # Multi-seed loopback
   ctest --preset all        # Everything

See :doc:`testing` for details on labels, hardware
skip detection, and fixtures.

Utility targets
^^^^^^^^^^^^^^^

.. code-block:: bash

   cmake --build build --target list           # Supported GPUs
   cmake --build build --target asm            # Dump assembly
   cmake --build build --target lint-format    # Check formatting
   cmake --build build --target format         # Fix formatting
   cmake --build build --target lint-spell     # Spell-check docs
   cmake --build build --target lint-codespell # codespell check
   cmake --build build --target lint-all       # All linting
   cmake --build build --target doxygen        # Doxygen XML
   cmake --build build --target sphinx-html    # Full HTML docs
   cmake --build build --target clean-all      # Remove artifacts
   cmake --build build --target clean-external # Remove headers

Build Output Structure
----------------------

::

   build/
   ├── xio-tester              # Test application
   ├── librocm-xio.a           # Static library
   ├── docs/                   # (if XIO_BUILD_DOCS=ON)
   │   ├── html/               # Sphinx HTML output
   │   └── xml/                # Doxygen XML (intermediate)
   └── CMakeFiles/

Build System Details
--------------------

- **HIP compilation**: Uses ``hipcc`` with ``-fgpu-rdc`` for relocatable
  device code
- **Device code extraction**: Tester links with ``hipcc`` to extract device
  code from the static library
- **Code generation**: Automatic generation of the endpoint registry and
  external headers
- **GPU architecture detection**: Auto-detects via ``rocminfo`` or can be
  specified via ``OFFLOAD_ARCH``

Requirements
^^^^^^^^^^^^

- CMake 3.21 or later
- ROCm HIP SDK
- HSA runtime libraries
- libdrm and libdrm_amdgpu development packages

Installation
------------

Default location (typically ``/opt/rocm``)
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

.. code-block:: bash

   cmake --install build

Custom location
^^^^^^^^^^^^^^^

.. code-block:: bash

   cmake --install build --prefix /tmp/rocm-xio-test

   export CMAKE_PREFIX_PATH=/tmp/rocm-xio-test:$CMAKE_PREFIX_PATH
   cd /tmp
   cat > test-find-package.cmake << 'EOF'
   cmake_minimum_required(VERSION 3.21)
   project(test)
   find_package(rocm-xio REQUIRED)
   message(STATUS "Found rocm-xio: ${rocm-xio_VERSION}")
   EOF
   cmake -P test-find-package.cmake

Install with tester
^^^^^^^^^^^^^^^^^^^

.. code-block:: bash

   cmake -S . -B build -DINSTALL_TESTER=ON
   cmake --install build --prefix /tmp/rocm-xio-test

Install layout
^^^^^^^^^^^^^^

::

   <prefix>/                         # /opt/rocm by default
   ├── bin/
   │   └── xio-tester                # (INSTALL_TESTER=ON only)
   ├── include/rocm-xio/
   │   ├── xio.h
   │   ├── xio-endpoint-registry.h
   │   └── endpoints/
   │       ├── nvme-ep/
   │       │   └── nvme-ep.h
   │       ├── rdma-ep/
   │       │   └── rdma-ep.h
   │       ├── sdma-ep/
   │       │   ├── sdma-ep.h
   │       │   └── sdma_pkt_struct.h
   │       └── test-ep/
   │           └── test-ep.h
   └── lib/
       ├── librocm-xio.a
       └── cmake/rocm-xio/
           ├── rocm-xio-config.cmake
           ├── rocm-xio-config-version.cmake
           └── rocm-xio-targets.cmake
