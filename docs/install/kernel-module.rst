.. meta::
  :description: Learn how to build and install the ROCm XIO kernel module 
  :keywords: ROCm, documentation, XIO, kernel module

********************************************
Build and install the ROCm XIO kernel module
********************************************

The ``rocm-xio`` kernel module (``kernel/rocm-xio/``) provides
low-level hardware access for queue registration and doorbell
mapping. It uses the standard Linux kernel build system (Kbuild)
and must be built separately from the CMake build.

Building
========

.. code-block:: bash

   cd kernel/rocm-xio
   make

Installing
==========

.. code-block:: bash

   sudo make install
   sudo modprobe rocm-xio

Device-node setup
=================

The module calls ``device_create()`` during initialization, so
``/dev/rocm-xio`` is normally created automatically by
``devtmpfs/udev``. Manual device-node creation is only needed on
systems where ``devtmpfs`` is disabled or udev rules prevent
automatic creation.

.. code-block:: bash

   sudo mknod /dev/rocm-xio c \
     $(grep rocm-xio /proc/devices | awk '{print $1}') 0
   sudo chmod 666 /dev/rocm-xio

.. note::

  - The kernel module build is independent of the CMake build
    system and uses its own Makefile following Linux kernel
    conventions.
  - The module must be loaded before running endpoints that
    require hardware queue registration (e.g., ``nvme-ep``).
