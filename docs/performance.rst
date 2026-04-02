Performance
===========

This page documents RDMA-EP loopback performance
measurements collected on a single-node system. All
results are from GPU-initiated RDMA WRITE operations
with LFSR data verification, measured end-to-end from
the GPU kernel (post WQE to CQE completion).

Test Environment
----------------

.. list-table::
   :widths: 30 70
   :header-rows: 0

   * - **GPU**
     - AMD Radeon RX 9070 XT
   * - **CPU**
     - AMD Ryzen Threadripper PRO 7955WX 16-Cores
   * - **Broadcom NIC**
     - BCM57608 NetXtreme 25G/50G/100G/200G/400G
   * - **Pensando NIC**
     - AMD Pensando DSC Ethernet Controller
   * - **OS**
     - Ubuntu 24.04.4 LTS
   * - **Kernel**
     - 6.17.0-19-generic
   * - **ROCm**
     - 7.2.0
   * - **Commit**
     - ``3411d80``

Test Methodology
----------------

Each measurement runs ``test-rdma-loopback`` in a
single-QP loopback configuration: the NIC sends an RDMA
WRITE to itself over a QP connected to its own GID. The
GPU kernel posts a single WQE, rings the doorbell from
device code, then spin-polls the CQ for completion. The
GPU wall clock measures the elapsed time from WQE post
to CQE arrival.

Ten iterations are run per (vendor, transfer size) pair,
each with a distinct LFSR seed for data verification.
Statistics are computed over the ten successful
iterations:

- **Min** -- fastest observed operation
- **Mean** -- arithmetic mean of all iterations
- **Std** -- population standard deviation
- **Max** -- slowest observed operation

Throughput and IOPS are derived from the per-operation
latency:

- **Throughput** = transfer size / latency (MB/s, where
  1 MB = 10\ :sup:`6` bytes)
- **IOPS** = 10\ :sup:`6` / latency (ops/s)

Because these are single-operation measurements (not
pipelined), the IOPS figures represent the serial
round-trip rate. Pipelined or multi-queue workloads
will achieve higher aggregate IOPS.

.. note::

   Transfer sizes below 32 bytes cause the GPU kernel
   to hang on both BNXT and IONIC hardware. The
   minimum working transfer size for loopback RDMA
   WRITE is 32 bytes.

RDMA-EP Loopback Results
------------------------

Broadcom (BNXT)
^^^^^^^^^^^^^^^

Latency
"""""""

.. list-table::
   :widths: 15 17 17 17 17
   :header-rows: 1

   * - Size
     - Min (us)
     - Mean (us)
     - Std (us)
     - Max (us)
   * - 32 B
     - 35.9
     - 38.6
     - 3.1
     - 43.6
   * - 64 B
     - 35.9
     - 36.9
     - 1.7
     - 41.9
   * - 128 B
     - 35.8
     - 37.1
     - 1.9
     - 42.5
   * - 256 B
     - 21.4
     - 34.9
     - 4.9
     - 42.2
   * - 1 KiB
     - 34.9
     - 36.0
     - 2.3
     - 43.0
   * - 4 KiB
     - 33.9
     - 36.9
     - 2.7
     - 42.4
   * - 64 KiB
     - 49.9
     - 53.8
     - 2.9
     - 59.8
   * - 1 MiB
     - 163.9
     - 166.4
     - 1.6
     - 168.8

Throughput
""""""""""

.. list-table::
   :widths: 15 17 17 17 17
   :header-rows: 1

   * - Size
     - Min (MB/s)
     - Mean (MB/s)
     - Std (MB/s)
     - Max (MB/s)
   * - 32 B
     - 0.7
     - 0.8
     - 0.1
     - 0.9
   * - 64 B
     - 1.5
     - 1.7
     - 0.1
     - 1.8
   * - 128 B
     - 3.0
     - 3.5
     - 0.2
     - 3.6
   * - 256 B
     - 6.1
     - 7.3
     - 1.0
     - 12.0
   * - 1 KiB
     - 23.8
     - 28.4
     - 1.8
     - 29.3
   * - 4 KiB
     - 96.6
     - 111.0
     - 8.1
     - 120.8
   * - 64 KiB
     - 1,095.9
     - 1,218.1
     - 65.7
     - 1,313.3
   * - 1 MiB
     - 6,211.9
     - 6,301.5
     - 60.6
     - 6,397.7

IOPS
""""

.. list-table::
   :widths: 15 17 17 17 17
   :header-rows: 1

   * - Size
     - Min
     - Mean
     - Std
     - Max
   * - 32 B
     - 22,936
     - 25,907
     - 2,081
     - 27,855
   * - 64 B
     - 23,866
     - 27,100
     - 1,249
     - 27,855
   * - 128 B
     - 23,529
     - 26,954
     - 1,380
     - 27,933
   * - 256 B
     - 23,697
     - 28,653
     - 4,023
     - 46,729
   * - 1 KiB
     - 23,256
     - 27,778
     - 1,775
     - 28,653
   * - 4 KiB
     - 23,585
     - 27,100
     - 1,983
     - 29,499
   * - 64 KiB
     - 16,722
     - 18,587
     - 1,002
     - 20,040
   * - 1 MiB
     - 5,924
     - 6,010
     - 58
     - 6,101

Pensando (IONIC)
^^^^^^^^^^^^^^^^

Latency
"""""""

.. list-table::
   :widths: 15 17 17 17 17
   :header-rows: 1

   * - Size
     - Min (us)
     - Mean (us)
     - Std (us)
     - Max (us)
   * - 32 B
     - 22.2
     - 26.4
     - 1.5
     - 27.4
   * - 64 B
     - 26.2
     - 26.8
     - 0.5
     - 27.7
   * - 128 B
     - 25.3
     - 26.4
     - 0.6
     - 27.4
   * - 256 B
     - 15.1
     - 19.7
     - 4.8
     - 26.9
   * - 1 KiB
     - 23.2
     - 26.5
     - 1.2
     - 27.7
   * - 4 KiB
     - 23.8
     - 28.2
     - 1.6
     - 29.7
   * - 64 KiB
     - 29.4
     - 33.1
     - 2.1
     - 35.1
   * - 1 MiB
     - 104.4
     - 107.8
     - 1.5
     - 109.3

Throughput
""""""""""

.. list-table::
   :widths: 15 17 17 17 17
   :header-rows: 1

   * - Size
     - Min (MB/s)
     - Mean (MB/s)
     - Std (MB/s)
     - Max (MB/s)
   * - 32 B
     - 1.2
     - 1.2
     - 0.1
     - 1.4
   * - 64 B
     - 2.3
     - 2.4
     - 0.0
     - 2.4
   * - 128 B
     - 4.7
     - 4.8
     - 0.1
     - 5.1
   * - 256 B
     - 9.5
     - 13.0
     - 3.2
     - 17.0
   * - 1 KiB
     - 37.0
     - 38.6
     - 1.7
     - 44.1
   * - 4 KiB
     - 137.9
     - 145.2
     - 8.2
     - 172.1
   * - 64 KiB
     - 1,867.1
     - 1,979.9
     - 125.6
     - 2,229.1
   * - 1 MiB
     - 9,593.6
     - 9,727.1
     - 135.3
     - 10,043.8

IOPS
""""

.. list-table::
   :widths: 15 17 17 17 17
   :header-rows: 1

   * - Size
     - Min
     - Mean
     - Std
     - Max
   * - 32 B
     - 36,496
     - 37,879
     - 2,152
     - 45,045
   * - 64 B
     - 36,101
     - 37,313
     - 696
     - 38,168
   * - 128 B
     - 36,496
     - 37,879
     - 861
     - 39,526
   * - 256 B
     - 37,175
     - 50,761
     - 12,368
     - 66,225
   * - 1 KiB
     - 36,101
     - 37,736
     - 1,709
     - 43,103
   * - 4 KiB
     - 33,670
     - 35,461
     - 2,012
     - 42,017
   * - 64 KiB
     - 28,490
     - 30,211
     - 1,917
     - 34,014
   * - 1 MiB
     - 9,149
     - 9,276
     - 129
     - 9,579

RDMA WRITE with Immediate
-------------------------

The ``QueuePair`` API now includes ``put_nbi_imm()`` and
``put_nbi_imm_single()`` for RDMA WRITE with Immediate
Data (``IBV_WR_RDMA_WRITE_WITH_IMM``). Opcode support
is wired for all four vendors (BNXT, IONIC, MLX5, ERNIC)
and the ``--write-imm`` flag is available in
``test-rdma-loopback``.

Per the InfiniBand specification (section 9.3.3.3),
WRITE_IMM is commonly used as a **zero-length
notification**: the 32-bit immediate value is the entire
payload, posted with ``num_sge = 0``. The NIC delivers
the immediate value by consuming a receive WQE from the
responder's RQ and generating a completion with the
immediate data.

Current limitations:

- **BNXT**: The DV-created QP does not expose
  ``ibv_post_recv``. Posting receive WQEs (required for
  WRITE_IMM) is not supported through the current DV
  path. WRITE_IMM is skipped on BNXT (exit code 77).

- **IONIC**: The GDA mode sets ``recv=false`` in
  ``ionic_dv_qp_set_gda()``, so ``ibv_post_recv``
  should use the standard verbs doorbell path. However,
  loopback WRITE_IMM completions are unreliable in
  testing -- the send CQE is not consistently generated,
  likely due to a firmware interaction between the RQ
  receive WQE delivery and the GDA send CQ polling in
  loopback configuration.

WRITE_IMM performance results will be added once these
receive-side limitations are resolved. The send-side
WQE construction (opcode, immediate data field) is
verified correct for both vendors.

Reproducing These Results
-------------------------

Build with both BNXT and IONIC providers enabled:

.. code-block:: bash

   cmake -S . -B build \
     -DCMAKE_BUILD_TYPE=Release \
     -DGDA_BNXT=ON -DGDA_IONIC=ON \
     -DBUILD_TESTING=ON
   cmake --build build \
     --target test-rdma-loopback \
     --target install-rdma-core \
     --parallel

Run the hardware setup fixture, then execute the sweep
for each vendor and transfer size:

.. code-block:: bash

   # Setup loopback interfaces
   sudo VENDOR=all \
     scripts/test/setup-rdma-loopback.sh

   # Run BNXT sweep (example: 4 KiB, 10 iters)
   LIB="build/_deps/rdma-core/install/lib"
   LIB="${LIB}:/opt/rocm/lib"
   sudo env LD_LIBRARY_PATH="${LIB}" \
     build/tests/unit/rdma-ep/test-rdma-loopback \
     --provider bnxt \
     --device rocm-rdma-bnxt0 \
     --size 4096 --seed 1

   # Run IONIC sweep (example: 4 KiB, 10 iters)
   sudo env LD_LIBRARY_PATH="${LIB}" \
     build/tests/unit/rdma-ep/test-rdma-loopback \
     --provider ionic \
     --device rocm-rdma-ionic0 \
     --size 4096 --seed 1

Or use the convenience script which iterates over
multiple seeds and computes statistics automatically:

.. code-block:: bash

   VENDOR=bnxt TEST_SIZE=4096 ITERATIONS=10 \
     ./run-test-rdma-loopback.sh
