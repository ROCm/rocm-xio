.. meta::
  :description: ROCm XIO documentation
  :keywords: ROCm, documentation

************************
ROCm XIO documentation
************************

ROCm XIO provides an API for Accelerator-Initiated IO (XIO)
for an AMD GPU ``__device__`` code.
It enables AMD GPUs to perform direct
IO operations to hardware devices without CPU intervention.

.. grid:: 2
  :gutter: 3

  .. grid-item-card:: Install

    * :doc:`Build and install ROCm XIO </install/building>`
    * :doc:`Install the kernel module </install/kernel-module>`

  .. grid-item-card:: How to

    * :doc:`Run tests <how-to/testing>`
    * :doc:`Run VM-isolated tests <how-to/vm-testing>`

  .. grid-item-card:: Conceptual

    * :doc:`Memory modes, allocation, and coherence <conceptual/memory-modes>`

  .. grid-item-card:: Reference

    * :doc:`Examples <reference/examples>`
    * :doc:`Performance measurements <reference/performance>`
    * :doc:`Endpoints <reference/endpoints>`
    * :doc:`Environment variables <reference/environment-variables>`
    * :doc:`API reference <reference/api>`

To contribute to the documentation, refer to the `Contributing guide in the GitHub repo <https://github.com/ROCm/rocm-xio/blob/main/CONTRIBUTING.md>`_.

You can find licensing information on the :doc:`License <license>` page.
