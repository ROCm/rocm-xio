.. meta::
  :description: Learn how to run ROCm XIO tests in a virtual machine
  :keywords: ROCm, documentation, XIO, virtual machine, hardware tests

********************************
Run ROCm XIO VM-isolated testing
********************************

Hardware tests (RDMA loopback, NVMe passthrough) touch low-level
kernel and device state that can trigger kernel panics on the
host. Running these tests inside a QEMU VM isolates the failure
domain: if the guest kernel panics, the host stays up and the VM
can be restarted.

The VM infrastructure provides CMake targets for image creation,
provisioning, launching, and testing, plus a ``launch-vm``
wrapper script with four passthrough modes.

Prerequisites
=============

==================  ===================================
Tool                Install
==================  ===================================
QEMU >= 10.1        ``apt install qemu-system-x86``
                    or a PCI/MMIO-capable build (for example
                    ``/opt/qemu-mmio-bridge-submit/bin/`` or
                    ``/opt/qemu-pci*/bin/``) preferred for
                    passthrough and MMIO bridge tests
``driverctl``       ``apt install driverctl``
``cloud-localds``   ``apt install cloud-image-utils``
``qemu-minimal``    Clone
                    ``github.com/sbates130272/``
                    ``qemu-minimal``
Ansible             ``pip install ansible``
``sshpass``         ``apt install sshpass`` (needed
                    by Ansible for SSH passwords)
``rocm-ernic``      Only needed for ``ernic`` and
                    ``full`` modes
==================  ===================================

CMake detects all of these at configure time and prints
actionable messages when something is missing.

Quick start
===========

.. code-block:: bash

   # 1. Configure (detects QEMU, GPU, tools)
   cmake -S . -B build

   # 2. Create the base VM image
   cmake --build build --target gen-test-vm

   # 3. Boot the VM (default: rdma mode)
   cmake --build build --target launch-test-vm

   # 4. In another terminal, provision ROCm
   cmake --build build --target setup-test-vm

   # 5. Subsequent boots -- just launch and test
   cmake --build build --target launch-test-vm

CMake targets
=============

``gen-test-vm``
---------------

Creates the ``rocm-xio-vm.qcow2`` base image using
``qemu-minimal``'s ``gen-vm`` script and ``cloud-init``.
The image includes a user account and a minimal set of
bootstrap packages (defined in
``cmake/XIOVirtualMachine.cmake``).

.. code-block:: bash

   cmake --build build --target gen-test-vm

   # Custom credentials
   cmake -DXIO_VM_USERNAME=stebates \
         -DXIO_VM_PASS=mypass .. \
   && cmake --build build --target gen-test-vm

``setup-test-vm``
-----------------

Provisions a *running* VM by installing the
``sbates130272.batesste`` Ansible Galaxy collection and
running its ``setup-amd`` playbook via SSH. This installs
ROCm, ``amdgpu-dkms``, ``driverctl``, and development
tools inside the guest.

.. code-block:: bash

   # VM must already be running (launch-test-vm)
   cmake --build build --target setup-test-vm

``launch-test-vm``
------------------

Boots the VM. The mode is selected via the ``VM_MODE``
environment variable (defaults to ``rdma``):

.. code-block:: bash

   # RDMA NIC passthrough (default)
   cmake --build build --target launch-test-vm

   # NVMe controller passthrough
   VM_MODE=nvme cmake --build build --target launch-test-vm

   # Emulated RDMA NIC (rocm-ernic)
   VM_MODE=ernic cmake --build build --target launch-test-vm

   # All devices combined
   VM_MODE=full cmake --build build --target launch-test-vm

All modes pass the GPU through via VFIO and include an
emulated 1 TB NVMe drive so ``nvme-ep`` testing is always
available.

Launch modes
============

``rdma``
--------

Passes the GPU and a Broadcom BNXT NIC through to the VM
via ``vfio-pci``. Both devices must be bound to
``vfio-pci`` on the host before launch:

.. code-block:: bash

   sudo driverctl set-override 0000:10:00.0 vfio-pci
   sudo driverctl set-override 0000:c3:00.1 vfio-pci

``nvme``
--------

Passes the GPU and an NVMe controller through. Enables the
PCI MMIO bridge for GPU-direct NVMe access. The NVMe
controller must be bound to ``vfio-pci``.

``ernic``
---------

Passes only the GPU through as a real device. The RDMA NIC
is emulated by ``rocm-ernic``, which runs as a VFIO-user
server on the host and connects to QEMU via Unix sockets.
This is the safest mode because no physical NIC is
involved.

The script automatically starts and stops the
``rocm-ernic`` server(s). Configure with:

====================  ================================
Variable              Default
====================  ================================
``ERNIC_BIN``         Auto-detected from common paths
``ERNIC_INSTANCES``   ``1``
``ERNIC_BACKEND``     ``loopback``
====================  ================================

``full``
--------

Combines all device types: GPU, BNXT NIC, and NVMe
controller passthrough via ``vfio-pci``, plus an emulated
RDMA NIC via ``rocm-ernic`` (VFIO-user). All four PCI
devices and the emulated NVMe are available inside the
guest simultaneously. This is useful for testing scenarios
that span both RDMA and NVMe-EP paths in a single VM.

All three passthrough devices must be bound to ``vfio-pci``
on the host before launch:

.. code-block:: bash

   sudo driverctl set-override 0000:10:00.0 vfio-pci
   sudo driverctl set-override 0000:c3:00.1 vfio-pci
   sudo driverctl set-override 0000:85:00.0 vfio-pci

The ``rocm-ernic`` server is started and stopped
automatically, just as in ``ernic`` mode.

CMake cache variables
=====================

These can be set with ``cmake -D<VAR>=<value> ..`` at
configure time.

======================  ================================
Variable                Description
======================  ================================
``QEMU_PATH``           QEMU binary directory prefix
                        (must include a trailing ``/`` when
                        passed to ``run-vm``; CMake and
                        ``launch-vm`` normalize this). Prefer a
                        PCI/MMIO-capable build under
                        ``/opt/qemu-mmio-bridge-submit/bin/`` or
                        ``/opt/qemu-pci*/bin/`` (>= 10.1) over the
                        distro ``qemu-system-x86_64`` alone.
``XIO_VM_GPU``          GPU BDF for passthrough
                        (for example, ``10:00.0``); auto-
                        detected if not set
``XIO_VM_USERNAME``     VM user (default: ``$USER``)
``XIO_VM_PASS``         VM password (default:
                        ``password``)
``RUN_VM``              Path to ``qemu-minimal``
                        ``run-vm`` script (CMake searches next
                        to this checkout:
                        ``<repo>/../qemu-minimal/qemu``)
``GEN_VM``              Path to ``qemu-minimal``
                        ``gen-vm`` script
======================  ================================

Environment variable overrides
==============================

These override settings at run time (passed to
``launch-vm`` or the CMake target):

======================  ========  =====================
Variable                Default   Notes
======================  ========  =====================
``SSH_PORT``            2222      Host port forwarded
                                  to guest SSH
``GPU_BDF``             10:00.0   GPU PCI address
``RDMA_NIC_BDF``        c3:00.1   BNXT NIC (rdma mode)
``NVME_DEV_BDF``        85:00.0   NVMe ctrl (nvme mode)
``VCPUS``               16        Guest vCPU count
``VMEM``                16384     Guest RAM (MB); lower if VFIO
                                  hits ENOMEM, higher only with
                                  memlock limits raised
``VM_MODE``             rdma      ``rdma``, ``nvme``,
                                  ``ernic``, or ``full``
``NVME``                1         Emulated qcow2 NVMe count
                                  for ``run-vm`` (``2`` for
                                  two devices)
``NVME_TRACE``          none      ``doorbell``, ``all``, or a
                                  QEMU event name; see
                                  ``qemu-minimal`` ``run-vm``
                                  header
``NVME_TRACE_FILE``     (empty)   Host path for ``-trace
                                  file=...`` when tracing
``NVME_RECREATE``       false     When ``true``, delete and
                                  recreate emulated NVMe
                                  qcow2 images before boot
``DRY_RUN``             none      Any value other than
                                  ``none`` prints the QEMU
                                  argv without running QEMU
``QMP_SOCKET``          false     ``true``, ``false``, or a
                                  custom Unix socket path; see
                                  ``run-vm``
======================  ========  =====================

The ``launch-test-vm`` target passes ``RUN_VM``, ``GPU_BDF``,
and ``QEMU_PATH`` via ``cmake -E env``; other variables in the
table are inherited from the environment of the tool that runs
the build (for example ``ninja``), so export them in the same
shell before ``cmake --build`` when you need tracing or a dry
run.

QEMU path, dual NVMe topology, and tracing
==========================================

``run-vm`` builds the QEMU command by concatenating
``QEMU_PATH`` with ``qemu-system-x86_64`` (plus arguments).
``QEMU_PATH`` must therefore be a directory prefix, normally
ending in ``bin/``. ``launch-vm`` adds the trailing slash when
it is missing and, when ``QEMU_PATH`` is unset or empty, picks
``/opt/qemu-mmio-bridge-submit/bin/`` when that install exists,
otherwise the newest matching ``/opt/qemu-pci*/bin/`` directory
that contains a usable ``qemu-system-x86_64`` (or
``qemu-system-amd64``), so routine VM launches align with the
PCI/MMIO-capable QEMU builds used for ``gen-test-vm`` when you
configure with ``-DQEMU_PATH=`` under that tree.

In ``nvme`` and ``full`` modes the guest receives **both** the
emulated qcow2-backed NVMe device(s) controlled by ``NVME`` and
a **VFIO**-passthrough NVMe **controller** (``NVME_DEV_BDF``).
``launch-vm`` also enables ``PCI_MMIO_BRIDGE`` for GPU-direct
NVMe in those modes. QEMU wires the emulated NVMe first, then
VFIO devices. Namespace names inside the guest are not the
same as host ``/dev/disk/by-id/...`` paths; use ``lsblk`` and
``nvme list`` in the guest to pick the correct device for
``xio-tester nvme-ep`` (use ``--pci-mmio-bridge`` when the VM
was started with the MMIO bridge). Passthrough detaches the
whole PCI function from the host for the VM session; confirm
the BDF is the intended scratch or test controller before
binding it to ``vfio-pci``.

QEMU **NVMe trace** events complement rocm-xio logging on the
emulated path (for example ``ROCXIO_NVME_DUMP_PRP``). Set
``NVME_TRACE`` to ``doorbell``, ``all``, or a specific event
name, and optionally ``NVME_TRACE_FILE`` to capture trace lines
to a host file. Example inspection without booting the guest
(``DRY_RUN=1`` skips host VFIO checks in ``launch-vm`` and
``pci_check`` in ``run-vm`` so you can print the argv without
binding devices; a real boot still needs ``vfio-pci``):

.. code-block:: bash

   DRY_RUN=1 NVME_TRACE=all \
     ./scripts/test/launch-vm nvme

GPU detection
=============

At configure time CMake scans for AMD GPUs (VGA class
``0300`` and 3D class ``0302``) and checks which are bound
to ``vfio-pci``. If no GPU is bound, the configure output
prints the ``driverctl`` commands needed.

To select a specific GPU when multiple are present:

.. code-block:: bash

   cmake -DXIO_VM_GPU=c1:00.0 ..

Build and test inside the guest
===============================

After the VM boots, the host project tree is available via
9p VirtFS:

.. code-block:: bash

   sudo mount -t 9p \
     -o trans=virtio,version=9p2000.L \
     hostfs /home/$USER/Projects

   cd /home/$USER/Projects/rocm-xio/build
   cmake .. -DCMAKE_BUILD_TYPE=Debug
   cmake --build build -j$(nproc)

Then run the appropriate tests for the mode:

.. code-block:: bash

   # RDMA / ERNIC loopback
   sudo ./xio-tester rdma-ep --loopback

   # NVMe endpoint
   sudo ./xio-tester nvme-ep

Troubleshooting
===============

**Port 2222 already in use**
   Another VM or service is listening. Override with
   ``SSH_PORT=2223 cmake --build build --target launch-test-vm``.

**GPU not bound to vfio-pci**
   Run ``sudo driverctl set-override 0000:<BDF>
   vfio-pci``. The CMake configure step and ``launch-vm``
   both check this and print the exact command.

**VM image not found**
   Run ``cmake --build build --target gen-test-vm`` first.

**rocm-ernic binary not found (ernic/full mode)**
   Set ``ERNIC_BIN=/path/to/rocm-ernic`` or build
   ``rocm-ernic``:

   .. code-block:: bash

      cd ~/Projects/rocm-ernic
      cmake -B build -G Ninja
      cmake --build build

**VFIO ``vfio_container_dma_map ... Cannot allocate memory``**
   QEMU maps all guest RAM for the GPU VFIO container; with a
   large ``VMEM`` and a low **locked memory** hard limit, the
   kernel returns ENOMEM. ``ulimit -l unlimited`` only works
   after an admin raises the **hard** cap, for example under
   ``/etc/security/limits.d/`` (``memlock`` soft/hard
   ``unlimited`` for your user), then a full logout and login.
   Until then, run with less RAM, for example
   ``VMEM=8192 ./scripts/test/launch-vm nvme``.

**QEMU ``Can't add chassis slot, error -16`` on a second
   ``pcie-root-port``**
   Older ``qemu-minimal`` ``run-vm`` lines gave every
   ``pcie-root-port`` the default ACPI ``chassis``/``slot``,
   so the second VFIO passthrough root port collides (EBUSY).
   Update ``qemu-minimal`` ``run-vm`` so each host root port
   sets distinct ``chassis=``/``slot=`` (or pull the latest
   ``run-vm`` from your ``qemu-minimal`` checkout).
