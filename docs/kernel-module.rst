Kernel Module
=============

The ``rocm-xio`` kernel module (``kernel/rocm-xio/``) provides low-level
hardware access for queue registration and doorbell mapping. It uses the
standard Linux kernel build system (Kbuild) and must be built separately from
the CMake build.

Building
--------

.. code-block:: bash

   cd kernel/rocm-xio
   make

Installing
----------

.. code-block:: bash

   sudo make install
   sudo modprobe rocm-xio

Device Node Setup
-----------------

After loading the module, create the device node:

.. code-block:: bash

   sudo mknod /dev/rocm-xio c \
     $(grep rocm-xio /proc/devices | awk '{print $1}') 0
   sudo chmod 666 /dev/rocm-xio

Notes
-----

- The kernel module build is independent of the CMake build system and uses its
  own Makefile following Linux kernel conventions.
- The module must be loaded before running endpoints that require hardware queue
  registration (e.g. ``nvme-ep``).
