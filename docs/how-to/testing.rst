.. meta::
  :description: ROCm-XIO documentation
  :keywords: ROCm, documentation

.. _testing:

******************
Run ROCm-XIO tests
******************

rocm-xio uses `CTest`_ with CMake presets, label-based filtering,
hardware fixture setup, and runtime skip detection.  This page
documents how to run tests, what labels and presets exist, and how
hardware-gated tests behave when the required NIC or GPU is absent.

Prerequisites
=============

Build with testing enabled (the ``default`` preset does this automatically):

.. code-block:: bash

   cmake --preset default
   cmake --build --preset default

CMake test presets
==================

The project provides six test presets in ``CMakePresets.json``:

=================  ==============================  ================
Preset             Description                     Hardware needed
=================  ==============================  ================
``unit``           CPU-only unit tests             None
``system``         System tests (emulation)        HIP-capable GPU
``hardware``       Hardware integration tests      GPU + RDMA NIC
``sweep``          Multi-seed loopback sweep       GPU + RDMA NIC
``integration``    Install-integration examples    None
``all``            All tests                       Varies
=================  ==============================  ================

Run a preset:

.. code-block:: bash

   ctest --preset unit
   ctest --preset hardware
   ctest --preset sweep

Or equivalently without presets:

.. code-block:: bash

   ctest --test-dir build -V -L "unit" \
     --parallel --output-on-failure

Test labels
===========

Every test carries one or more CTest labels for filtering with
``ctest -L <label>``:

============  =========================================
Label         Meaning
============  =========================================
``unit``      CPU-only, no GPU or NIC (runs in CI)
``system``    Needs a HIP-capable GPU
``hardware``  Needs a GPU and a specific RDMA NIC
``sweep``     Parameterized multi-seed loopback runs
``stress``    Long-running (timeout: 600 s)
``rdma``      RDMA-related test
``common``    Common library utilities
``fixture``   CTest fixture (setup/teardown)
============  =========================================

Combine labels to narrow the scope:

.. code-block:: bash

   ctest --test-dir build -L "unit" -L "rdma"

Test inventory
==============

Unit tests (CPU-only)
---------------------

These run in CI without hardware:

- ``test-data-pattern`` -- LFSR data pattern generation and verification
- ``test-rdma-config`` -- ``RdmaEpConfig`` validation, ``Provider``
  enum, ``provider_name()``, ``provider_from_string()`` (all vendors
  including ROCM_ERNIC)
- ``test-rdma-vendors`` -- Vendor ID constants, ``RmaDescriptor``,
  ``AmoDescriptor`` struct layout
- ``test-rdma-endian`` -- Endian byte-swap helpers (host and
  optional device)
- ``test-bnxt-sizing`` -- BNXT DV queue sizing math:
  ``roundup_pow2``, ``align_up``, ``calc_wqe_sz``, ``compute_sq``,
  ``compute_rq``, ``cqe_size``
- ``test-rdma-topology`` -- PCIe address parsing:
  ``ExtractBusNumber``, ``GetBusIdDistance``, ``GetLcaDepth``
- ``test-extract-endpoint`` -- CLI argument parser:
  ``extractEndpointName()``
- ``test-ep-config`` -- test-ep configuration defaults

System tests
------------

- ``test-ep-emulate`` -- Full SQE/CQE round-trip in emulation mode
  (GPU required)

Hardware tests
--------------

These require a GPU and the corresponding RDMA NIC. When hardware
is absent, tests report ``Skipped`` rather than ``Failed`` (see
below).

- ``test-rdma-loopback`` -- GPU-initiated RDMA WRITE loopback with
  LFSR verification (BNXT, MLX5, or Ionic)
- ``test-rdma-loopback-seed1`` through
  ``test-rdma-loopback-seed5`` -- Parameterized seed sweep (label:
  ``sweep``)
- ``test-rdma-2node`` -- Two-node RDMA test (BNXT, MLX5, Ionic, or
  ERNIC)
- ``test-rdma-ernic-loopback`` -- ERNIC loopback

Hardware skip detection
=======================

Hardware tests use a three-layer gating strategy:

1. **Compile-time gating** -- Tests are only registered with CTest
   when the corresponding ``GDA_BNXT``, ``GDA_MLX5``,
   ``GDA_IONIC``, or ``GDA_ERNIC`` CMake variable is enabled at
   configure time.

2. **Runtime detection** -- Each hardware test probes for the
   required NIC and GPU at startup.  If hardware is absent the test
   prints ``SKIP: ...`` and exits with code 77.  CTest recognises
   this via ``SKIP_RETURN_CODE 77`` and
   ``SKIP_REGULAR_EXPRESSION "SKIP:"`` properties set by
   ``xio_add_test()``.

3. **GPU resource allocation** -- Tests with the ``GPU`` flag
   declare ``RESOURCE_GROUPS "gpus:1"`` so CTest can schedule
   parallel tests without oversubscribing GPUs.  The resource
   specification is auto-generated at configure time by
   ``cmake/XIODetectGPUs.cmake`` using ``rocm_agent_enumerator``.

CTest fixtures
--------------

Hardware tests depend on a ``RDMA_HW`` fixture that runs
``scripts/test/setup-rdma-loopback.sh`` via ``sudo`` before any
hardware test executes.  This fixture handles:

- Kernel module reload (``modprobe bnxt_re`` / ``ionic_rdma``)
- Ionic sysfs loopback mode configuration
- RDMA device renaming (udev fallback)
- IP address and static ARP neighbor setup
- GID table readiness polling

When you run ``ctest -L hardware``, CTest automatically runs the fixture
first in dependency order.

GPU resource spec
=================

At configure time, ``cmake/XIODetectGPUs.cmake`` runs ``rocm_agent_enumerator``
and writes ``build/ctest-resources.json`` with the detected GPU count.  When
``rocm_agent_enumerator`` is unavailable the module defaults to a
single GPU.  Use the generated file for parallel GPU-aware test
scheduling:

.. code-block:: bash

   ctest --test-dir build \
     --resource-spec-file build/ctest-resources.json \
     --parallel 4

Environment
===========

Hardware tests automatically set ``LD_LIBRARY_PATH`` to include the
rdma-core build tree via the CTest ``ENVIRONMENT`` property.  No
manual ``export`` is needed when running through ``ctest``.

Shell script runner
===================

The convenience script ``scripts/test/test-rdma-ep-xio-loopback.sh``
wraps the compiled ``test-rdma-loopback`` binary with additional
features:

- Provider selection (``PROVIDER=bnxt|mlx5|ionic|auto``)
- Transfer size configuration (``TRANSFER_SIZE=256``)
- LFSR data-pattern seed (``LFSR_SEED=1``)
- Iteration count (``ITERATIONS=1``)
- RDMA device override (``ROCXIO_RDMA_DEVICE``)
- Auto-detection of build directory, test binary (``TEST_BIN``),
  and rdma-core library (``RDMA_CORE_LIB``)

.. code-block:: bash

   # Loopback with BNXT provider, 128 iterations
   PROVIDER=bnxt ITERATIONS=128 \
     scripts/test/test-rdma-ep-xio-loopback.sh

   # Ionic provider, 4 KiB transfers
   PROVIDER=ionic TRANSFER_SIZE=4096 \
     scripts/test/test-rdma-ep-xio-loopback.sh

   # Quick CTest-only run
   ctest --preset sweep

``xio-tester rdma-ep``
======================

``xio-tester rdma-ep`` runs GPU-initiated RDMA WRITEs with per-iteration
timing statistics and histogram support.  It honours ``--memory-mode``
for queue and data buffer placement (see :ref:`memory-modes`).

.. code-block:: bash

   LIB=build/_deps/rdma-core/install/lib:/opt/rocm/lib

   # BNXT loopback (128 iterations, 4 KiB)
   sudo LD_LIBRARY_PATH="${LIB}" \
     HSA_FORCE_FINE_GRAIN_PCIE=1 \
     ./build/xio-tester rdma-ep \
     --provider bnxt \
     --device rocm-rdma-bnxt0 \
     --loopback --iterations 128 \
     --transfer-size 4096

   # Ionic loopback
   sudo LD_LIBRARY_PATH="${LIB}" \
     HSA_FORCE_FINE_GRAIN_PCIE=1 \
     ./build/xio-tester rdma-ep \
     --provider ionic \
     --device rocm-rdma-ionic0 \
     --loopback --iterations 128 \
     --transfer-size 4096

   # With data buffer in VRAM (memory-mode bit 3)
   sudo LD_LIBRARY_PATH="${LIB}" \
     HSA_FORCE_FINE_GRAIN_PCIE=1 \
     ./build/xio-tester rdma-ep \
     --provider bnxt \
     --device rocm-rdma-bnxt0 \
     --loopback --iterations 128 \
     --transfer-size 4096 \
     --memory-mode 8

The ``--device`` flag selects the RDMA device by name (as shown by
``rdma link show``).  When omitted, topology-based selection picks
the NIC closest to the GPU.

Infinite mode and SIGINT
------------------------

Pass ``--iterations 0`` to run indefinitely.  Press **Ctrl-C** to stop
gracefully; the GPU kernel polls a host-mapped ``stopRequested``
flag after each RDMA WRITE completion and exits cleanly.

.. code-block:: bash

   # Infinite loopback with --less-timing stats
   sudo LD_LIBRARY_PATH="${LIB}" \
     HSA_FORCE_FINE_GRAIN_PCIE=1 \
     ./build/xio-tester rdma-ep \
     --provider bnxt \
     --device rocm-rdma-bnxt0 \
     --loopback --iterations 0 \
     --less-timing

SIGINT handling is supported by all endpoints: ``nvme-ep``, ``rdma-ep``,
``test-ep``, and ``sdma-ep``.

Per-iteration data verification
-------------------------------

``--verify`` checks the LFSR data pattern after *each* RDMA WRITE
completion, not just at the end. Verification runs outside the
timing window so it doesn't inflate latency measurements. On
mismatch the kernel prints the iteration number and byte offset.

.. code-block:: bash

   sudo LD_LIBRARY_PATH="${LIB}" \
     HSA_FORCE_FINE_GRAIN_PCIE=1 \
     ./build/xio-tester rdma-ep \
     --provider bnxt \
     --device rocm-rdma-bnxt0 \
     --loopback --iterations 128 \
     --transfer-size 256 --verify

GPU configuration for multi-wavefront kernels
=============================================

Any endpoint kernel that spans multiple wavefronts (i.e., the thread
block contains more threads than the hardware wavefront size) uses
``__syncthreads()`` barriers to coordinate work across wavefronts.
These barriers prevent the GPU scheduler from preempting the workgroup
mid-execution.  Two amdgpu driver behaviours interact badly with
non-preemptible workgroups and must be configured before running long
or infinite multi-wavefront kernels.

For ``nvme-ep`` this applies when ``--batch-size`` exceeds the
wavefront size (typically 32 on RDNA or 64 on CDNA). Other
endpoints are similarly affected whenever their GPU kernels launch
thread blocks larger than one wavefront.

Background on GPU preemption and reset is documented in the
`amdgpu module parameters`_ section of the Linux kernel
documentation. The ``cwsr_enable`` parameter (Compute Wave Store
and Resume) controls mid-wave preemption support. When a workgroup
holds a ``__syncthreads()`` barrier, CWSR cannot save and restore
individual waves, so the entire workgroup becomes non-preemptible.
See also the `ROCm system debugging guide`_ for related environment
variables.

.. _amdgpu module parameters:
   https://www.kernel.org/doc/html/next/gpu/amdgpu/module-parameters.html
.. _ROCm system debugging guide:
   https://rocm.docs.amd.com/en/latest/how-to/system-debugging.html

Disable GPU power management
----------------------------

On headless systems the amdgpu driver periodically suspends and resumes
the GPU (every ~20 seconds) via two independent mechanisms: DPM (Dynamic
Power Management) level switching and PCI runtime power management
(``runpm``). Both are described in the `amdgpu module parameters`_
documentation.

Single-wavefront kernels survive these suspend/resume cycles because
CWSR can preempt and restore them. Multi-wavefront kernels
that hold ``__syncthreads()`` barriers can't be preempted, so a
power-gate cycle terminates the kernel and resets the GPU. A GPU
reset can cause system-wide instability including crashes in
unrelated processes.

Both DPM and PCI runtime PM must be disabled. Set them at runtime
before launching kernels:

.. code-block:: bash

   # Set DPM to high performance
   echo high | sudo tee \
     /sys/class/drm/card1/device/\
   power_dpm_force_performance_level

   # Disable PCI runtime power management
   echo on | sudo tee \
     /sys/class/drm/card1/device/power/control

To make ``runpm`` persist across reboots, add it to the modprobe configuration
alongside ``lockup_timeout``:

.. code-block:: bash

   echo "options amdgpu lockup_timeout=-1 runpm=0" \
     | sudo tee /etc/modprobe.d/amdgpu-lockup.conf
   sudo update-initramfs -u

The ``power_dpm_force_performance_level`` can't be persisted via
modprobe and must be set each session, for example via a systemd
unit or ``rc.local`` script.

To restore automatic power management afterwards:

.. code-block:: bash

   echo auto | sudo tee \
     /sys/class/drm/card1/device/\
   power_dpm_force_performance_level
   echo auto | sudo tee \
     /sys/class/drm/card1/device/power/control

.. note::

   The ``card1`` path assumes the GPU is the second DRM device.
   Check ``ls /sys/class/drm/`` to find the correct card number
   for your system.

Set compute lockup timeout to infinity
--------------------------------------

The amdgpu driver's ``lockup_timeout`` parameter (default 2000 ms)
resets the GPU if a compute dispatch does not signal its completion
fence within the timeout window. Infinite-mode kernels never
complete by design, and long-running finite kernels may also exceed
the default. The `amdgpu module parameters`_ documentation
describes the timeout format and default values.

This parameter is read-only at runtime and must be set at module
load time.  Create a modprobe configuration file and rebuild the
initramfs so the setting takes effect when the amdgpu module loads
during boot:

.. code-block:: bash

   echo "options amdgpu lockup_timeout=-1" \
     | sudo tee /etc/modprobe.d/amdgpu-lockup.conf
   sudo update-initramfs -u
   sudo reboot

Verify after reboot:

.. code-block:: bash

   cat /sys/module/amdgpu/parameters/lockup_timeout
   # Should show: -1

Both settings are required for any endpoint kernel that uses
multi-wavefront thread blocks in infinite or long-running mode.
Single-wavefront kernels and short-duration tests don't need them.

Add new tests
=============

Use the ``xio_add_test()`` CMake function defined in
``cmake/XIOTestHelpers.cmake``:

.. code-block:: cmake

   xio_add_test(
     NAME test-my-feature
     SOURCE test-my-feature.hip
     LABELS unit rdma
     TIMEOUT 30
     INCLUDE_DIRS ${CMAKE_SOURCE_DIR}/src/my-dir
   )

Parameters:

- ``NAME`` -- Test target and CTest name (required)
- ``SOURCE`` -- HIP source file (required)
- ``LABELS`` -- CTest labels for filtering
- ``TIMEOUT`` -- Seconds (defaults by label: unit=60,
  hardware=300, stress=600, other=120)
- ``INCLUDE_DIRS`` -- Extra include directories
- ``EXTRA_ARGS`` -- Arguments passed to the test binary
- ``GPU`` -- If set, adds resource groups, skip detection, and
  ``LD_LIBRARY_PATH``

For hardware tests that need the RDMA fixture, add after registration:

.. code-block:: cmake

   set_tests_properties(test-my-feature PROPERTIES
     FIXTURES_REQUIRED RDMA_HW)

CI integration
==============

The GitHub Actions workflows run tests as follows:

- **build-check**: ``ctest -L "unit"`` -- CPU-only tests in a
  ``rocm/dev-ubuntu-24.04:7.2`` container (no GPU)
- **test-emulate**: ``ctest -L "unit"`` plus
  ``xio-tester test-ep --emulate`` (no GPU, emulation mode)

Hardware and sweep tests are not run in CI -- they require physical
NIC and GPU hardware.

VM-isolated testing
===================

Hardware and RDMA tests can trigger kernel panics on bare metal.
For a safer alternative that isolates failures inside a QEMU VM,
see :doc:`vm-testing`.

.. _CTest:
   https://cmake.org/cmake/help/latest/manual/ctest.1.html
