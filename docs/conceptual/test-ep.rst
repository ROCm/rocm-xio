.. meta::
  :description: Learn how the test-ep software endpoint works, where it
    adds value to the rocm-xio test pyramid, and how to extend its
    CTest coverage
  :keywords: ROCm, documentation, test-ep, endpoints, CTest, XIO

.. _test-ep:

******************************
The test-ep software endpoint
******************************

``test-ep`` is the only rocm-xio endpoint that does **not** drive real
hardware. It implements the same SQE/CQE round-trip protocol that
``nvme-ep`` and ``rdma-ep`` use against silicon, but the "device" is
a pool of CPU polling threads in the same process. This page
explains why that matters for the project, what the endpoint can
already exercise today, and how its CTest coverage is structured
to take advantage of that.

Why test-ep exists
==================

The other endpoints all hit physical state -- an NVMe controller, an
RDMA NIC, an SDMA engine -- which means their tests skip when the
hardware is absent and they can crash a host on a buggy doorbell
write. ``test-ep`` exists to keep the GPU-side framework testable
when none of that is available:

- **CI without hardware.** ``test-ep`` runs on any HIP-capable host
  and, in ``--emulate`` mode, on any host that can build the
  library at all. The GitHub Actions ``test-emulate`` job uses it
  as the smoke test for the whole endpoint dispatch path.
- **Coherence and ordering baseline.** ``test-ep`` reuses the same
  ``XioComEnqueue`` / ``XioComDequeue`` 8-byte wide load/store
  helpers, the same ``__threadfence_system()`` discipline, and the
  same doorbell coordinator pattern that the production endpoints
  use. A regression in any of those is visible in ``test-ep`` long
  before it shows up on a NIC.
- **Reference CPU "device".** The CPU polling thread is small
  enough to read end to end. When a real endpoint is misbehaving it
  is often easier to swap in ``test-ep`` to confirm that the
  GPU-side kernel still issues legal SQE traffic.
- **Timing harness exerciser.** ``test-ep`` is the simplest user of
  ``startTimes`` / ``endTimes`` / ``XioTimingStats`` /
  ``XioSubstepStats``, so it doubles as a self-test for the
  rocm-xio timing infrastructure.

What the endpoint already supports
==================================

The on-disk implementation lives in ``src/endpoints/test-ep/`` and
covers four orthogonal axes:

``--iterations N`` and ``--threads T``
   ``T`` GPU work-items each post ``N`` SQEs and wait for a CQE per
   iteration. CPU threads are launched 1:1 with GPU threads in the
   non-doorbell mode.

``--doorbell Q``
   Switches to a circular submission queue of length ``Q`` with a
   single CPU polling thread driven by a doorbell tail pointer.
   Memory-mode bit 2 selects host or device placement for the
   doorbell itself.

``--emulate``
   Runs the GPU kernel logic on CPU threads. Memory mode is forced
   to 0 (host only) and ``hipInit`` is skipped. This is what makes
   the "no-GPU CI" path work.

``--verify`` and ``--seed S``
   The GPU kernel writes an LFSR pattern derived from a per-
   iteration seed into ``sqe.data[1..4]``, the CPU thread echoes a
   CQE, and the GPU re-reads ``sqe.data[1..4]`` and verifies the
   pattern. ``verifyPass`` / ``verifyFail`` counters are propagated
   back to the host through host-mapped scratch buffers. **Verify
   is currently only honoured on the GPU path** -- the CPU
   emulation kernel does not yet check the pattern.

Common ``XioEndpointConfig`` fields the endpoint consumes:

- ``numThreads``: GPU work-items / CPU pollers
- ``delayNs``: negative = fixed CPU response delay, positive =
  random delay in ``[0, delayNs]``, zero = respond immediately
- ``memoryMode``: bits 0/1 control SQ/CQ placement, bit 2 controls
  doorbell placement
- ``startTimes`` / ``endTimes``: per-iteration timestamps
- ``timingStats``: aggregate min/max/sum/count
- ``substepStats``: per-substep cycle counts (GPU only)
- ``stopRequested``: SIGINT flag, polled every 100 iterations

Where test-ep is still rough
============================

Useful gaps that are worth closing, roughly ordered by how much
they would improve the test pyramid:

CPU-side payload verification
   The CPU polling thread reads ``sqe.data[0]`` only (to compute
   the response delay) and ignores ``data[1..4]``. A CPU-side LFSR
   verifier would catch SQE-write data corruption even when no GPU
   is present, which the current ``--emulate --verify`` does not.

Emulate path does not honour ``verify``
   ``endpoint_kernel_cpu_emulate`` does not call ``dataPattern`` at
   all. ``--emulate --verify`` therefore silently runs without
   pattern checks. The fix is mechanical: gate the same
   ``dataPattern(false, ...)`` and ``dataPattern(true, ...)`` calls
   already in ``endpoint_kernel`` on ``doVerify`` in the emulation
   path too.

Emulate path does not honour ``stopRequested``
   The GPU kernel polls ``stopRequested`` every 100 iterations; the
   CPU emulation path does not. ``--emulate --iterations 0``
   therefore cannot be stopped with SIGINT.

CQE round-trip identity
   In polling mode the CQE only carries ``magic`` and a
   ``cpuTime``. Doorbell mode already encodes a sequence number in
   the upper half of ``cpuTime`` for cross-checking. Extending the
   polling-mode CQE the same way (or echoing the SQE iteration
   number) makes it possible to detect out-of-order completions on
   the GPU side.

Symmetric host-callable run helper
   ``xio::test_ep::run()`` always exercises the full dispatch path
   (queue allocation lives in the tester binary, not in the
   endpoint). A thin C++ helper that allocates SQ/CQ, calls
   ``run()``, joins threads, and returns a small result struct
   would make per-test boilerplate ~5 lines instead of ~30 and
   would remove the duplication between ``tests/system/test-ep``
   and any future GoogleTest-style harness.

Exported helper visibility
   ``sqeRead`` / ``sqeWrite`` / ``sqePoll`` / ``cqePoll`` /
   ``cqeGenFromSqe`` / ``sqeEqual`` / ``cqeEqual`` are
   ``__host__ __device__`` but only declared in ``test-ep.hip``.
   Exporting them in ``test-ep.h`` would let unit tests poke the
   polling protocol directly without standing up the whole
   ``launchCpuThreads`` framework.

CTest coverage strategy
=======================

The test pyramid below is what this page proposes. Items marked
**existing** are already wired up; items marked **added** were
introduced alongside this document; items marked *future* require
small product-code changes from the list above.

Unit (``unit`` label, CPU-only, runs in CI)
-------------------------------------------

The unit tests live in ``tests/unit/test-ep/`` and never touch a
GPU. They link against the rocm-xio library so the CPU-side helper
code is the one under test.

- ``test-ep-config`` (existing) -- struct sizes, magic constants,
  default ``TestEpConfig`` field values, ``sqeType`` /
  ``cqeType`` aliases.
- ``test-ep-launch-cpu-threads`` (added) -- drives
  ``xio::test_ep::launchCpuThreads()`` directly from the test, posts
  SQEs from the test thread to simulate the GPU, and verifies the
  CQE magic / monotonic ``cpuTime`` invariants in single-thread,
  multi-thread, and doorbell modes.

HIP emulate (``test-ep`` label; ``tests/system/test-ep/`` sources)
------------------------------------------------------------------

These targets exercise ``xio::test_ep::run()`` end to end. They live
under ``tests/system/test-ep/``, but ``CMakeLists.txt`` registers them
with CTest label ``test-ep`` only (not ``system``) so no-GPU CI can run
them with ``-L test-ep`` without matching the GPU-oriented ``system``
preset described in :doc:`/how-to/testing`. They build like other HIP system
tests but run cleanly in emulate mode.

- ``test-ep-emulate`` (existing) -- minimal single-thread,
  10-iteration round trip.
- ``test-ep-emulate-multithread`` (added) -- 4-thread, 16-iteration
  round trip. Catches the per-thread buffer indexing path in
  ``endpoint_kernel_cpu_emulate``.
- ``test-ep-emulate-doorbell`` (added) -- 4-thread, doorbell-mode
  round trip with queue depth ``iterations * threads`` (no ring reuse
  across the run). Catches the shared atomic counter and barrier logic in
  the CPU emulation path.
- ``test-ep-emulate-timing`` (added) -- exercises both the full
  ``startTimes`` / ``endTimes`` arrays and the ``XioTimingStats``
  aggregate mode and asserts that they were populated.
- ``test-ep-emulate-delay`` (added) -- fixed negative ``delayNs`` to
  confirm the CPU thread honours the delay request without
  serialising completions.

CLI smoke (``test-ep`` + ``cli`` labels, ``--emulate`` only)
------------------------------------------------------------

These tests shell out to ``xio-tester`` so the CLI wiring and the
test-ep CLI option set are validated alongside the library API.
They skip with exit 77 when ``xio-tester`` is not present, which
keeps them harmless in tree-only checkouts.

- ``test-ep-cli-emulate`` (added) -- baseline ``--emulate -n 16``.
- ``test-ep-cli-emulate-threads`` (added) --
  ``--emulate -n 8 --threads 4``.
- ``test-ep-cli-emulate-doorbell`` (added) --
  ``--emulate --doorbell 32 --threads 4 -n 8``.
- ``test-ep-cli-emulate-less-timing`` (added) --
  ``--emulate -n 64 --less-timing``.

Future tests (blocked on the product-code gaps above)
-----------------------------------------------------

These need one of the small product changes listed in the previous
section. They are listed here so that a reader has a single place
to look when those changes land.

- ``test-ep-emulate-verify`` -- requires the CPU emulation kernel
  to call ``dataPattern`` for ``--verify``.
- ``test-ep-emulate-cpu-payload-verify`` -- requires the CPU
  polling thread to LFSR-check ``sqe.data[1..4]``.
- ``test-ep-emulate-sigint`` -- requires
  ``endpoint_kernel_cpu_emulate`` to poll ``stopRequested``.

How to run the new tests
========================

:doc:`/how-to/testing` defines the ``system`` label for GPU-oriented
tests; the HIP emulate targets above omit it on purpose. The most
useful invocations are:

.. code-block:: bash

   ctest --preset unit -L test-ep
   ctest --test-dir build -L test-ep --output-on-failure

The CLI smoke entries additionally carry the ``cli`` label so they
can be selected or filtered separately:

.. code-block:: bash

   ctest --test-dir build -L "test-ep" -L "cli"

All of the new tests are short (each timeouts under 60 seconds) and
deterministic, so they are safe to run in parallel.
