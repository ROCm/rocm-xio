.. meta::
  :description: ROCm-XIO documentation
  :keywords: ROCm, documentation

********************************
Run ROCm-XIO VM-isolated testing
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
                    or build from source under
                    ``/opt/qemu-<version>``
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
``QEMU_PATH``           QEMU binary prefix (empty =
                        system ``qemu-system-x86_64``)
``XIO_VM_GPU``          GPU BDF for passthrough
                        (e.g. ``10:00.0``); auto-
                        detected if not set
``XIO_VM_USERNAME``     VM user (default: ``$USER``)
``XIO_VM_PASS``         VM password (default:
                        ``password``)
``RUN_VM``              Path to ``qemu-minimal``
                        ``run-vm`` script
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
``VMEM``                32768     Guest RAM (MB)
``VM_MODE``             rdma      ``rdma``, ``nvme``,
                                  ``ernic``, or ``full``
======================  ========  =====================

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
