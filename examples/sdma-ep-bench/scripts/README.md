# SDMA bandwidth scripts

These scripts are adapted from the bandwidth drivers in the
`shader_sdma` prototype. They run the installed or standalone
`sdma-ep-bw` and `sdma-ep-rate` executables and collect timestamped CSV result
sets.

Set `BENCHMARK` when the executable is not in the example's default
`build/` directory:

```bash
export BENCHMARK=/tmp/sdma-ep-bench-build/sdma-ep-bw
export HSA_FORCE_FINE_GRAIN_PCIE=1
```

Run the scripts with the privileges required to access `/dev/kfd`.
For example:

```bash
sudo --preserve-env=BENCHMARK,HSA_FORCE_FINE_GRAIN_PCIE \
  scripts/bench-bandwidth-single.sh
```

Available sweeps:

- `bench-bandwidth-single.sh`: vary the number of destinations.
- `bench-bandwidth-single-device-triggered.sh`: vary destinations using
  device-triggered SDMA queues.
- `bench-bandwidth-multiproducer.sh`: vary queues and workgroups.
- `bench-contention-singlequeue.sh`: vary producers sharing one queue.
- `bench-contention-multiqueue.sh`: distribute a fixed workgroup count
  across multiple queues.
- `bench-packet-rate.sh`: measure packet submission rate while varying queues.
- `bench-packet-rate-compare.sh`: run regular and immediate-poll variants and
  print Markdown MPPS/time comparison tables.
- `bench-packet-rate-all-modes.sh`: run all rate modes with one queue.
- `bench-packet-rate-isolated.sh`: compare copy, poll-only, local atomic,
  remote atomic, device-initiated poll+copy, and copy+atomic local/remote modes
  plus local and remote poll+copy+atomic with one queue.

The bandwidth benchmark now enables cached `SdmaQueueState` by default for
queue read-pointer checks. Pass `--no-queue-state` to `sdma-ep-bw` to reproduce
the uncached/original path.
- `bench-latency.sh`: sweep GPU-initiated SDMA latency and optional fine-grained
  queue-management timing.

The packet-rate script uses `RATE_BENCHMARK` instead of `BENCHMARK` and
accepts `SRC_GPU`, `DST_GPU`, `MIN_COPY_SIZE`, `MAX_COPY_SIZE`,
`NUM_COPY_COMMANDS`, `MIN_QUEUES`, `MAX_QUEUES`, `WARMUP`, `ITERATIONS`,
and `OUTPUT_ROOT` overrides.
Set `DEVICE_TRIGGERED=1` to measure preprogrammed `POLL + COPY` packets whose
poll condition is released immediately by the GPU.
Set `DEVICE_TRIGGERED_COPY_ONLY=1` to measure a host-backed queue with one
initial poll followed by copy-only packets.
The rate executable also supports isolated packet modes:

```bash
sdma-ep-rate --poll-only
sdma-ep-rate --atomic-only --atomic-memory local
sdma-ep-rate --atomic-only --atomic-memory remote
```

These measure poll packets and local/remote atomic-add packets without copy
traffic.
Set `SDMA_TIMESTAMPS=1` to bracket host-triggered batches with SDMA timestamp
packets. The bracket begins after the initial poll and ends before the final
completion atomic.
The regular device-initiated variant currently falls back to GPU timestamps in
this mode because SDMA timestamp packets hang on device-created queues.

For a paired run over queues 1, 2, 4, and 8:

```bash
scripts/bench-packet-rate-compare.sh
```

The report estimates repeated-poll time as full device-triggered batch time
minus copy-only batch time. All variants submit one contiguous batch per queue,
so the estimate excludes per-copy host doorbell overhead. It remains a
batch-level estimate, not a per-packet hardware timestamp.

Common environment variables include `SRC_GPU`, `WARMUP`, `ITERATIONS`,
`OUTPUT_ROOT`, and `BENCHMARK`. Each driver also exposes its sweep values
as uppercase environment variables near the top of the script.

Each run creates a timestamped directory containing:

- One CSV file for each tested configuration.
- `summary.csv`, containing all configurations.
- `benchmark.log`, containing commands and console output.

To plot one CSV or every individual CSV in a result directory:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r scripts/requirements.txt
python scripts/plot-bandwidth.py results_bandwidth_single_2026-07-29_12h00m00s
```

To compare regular and device-triggered bandwidth for one queue and one
destination:

```bash
python scripts/plot-bandwidth-comparison.py \
  results_bandwidth_single_2026-07-29_17h49m50s/bandwidth_1dst.csv \
  /tmp/results_bandwidth_single_device_triggered_2026-07-31_01h09m42s/bandwidth_1dst.csv \
  --output bandwidth_single_queue_single_destination_comparison.png
```

The comparison plot uses the common copy-size range and has separate panels
for GPU wall-clock bandwidth and CPU-observed bandwidth.

The original defaults are intentionally large and may allocate several
gigabytes per GPU. Override copy sizes, destination counts, or producer
counts for short smoke runs.
