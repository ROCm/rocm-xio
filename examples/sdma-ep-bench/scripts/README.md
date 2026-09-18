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
- `bench-latency.sh`: sweep GPU-initiated SDMA latency and optional fine-grained
  queue-management timing.
- `bench-packet-rate.sh`: measure one packet-rate mode while varying queues.
- `bench-packet-rate-isolated.sh`: run all six packet-rate modes with one
  queue, including local and remote atomic targets.

The bandwidth benchmark now enables cached `SdmaQueueState` by default for
queue read-pointer checks. Pass `--no-queue-state` to `sdma-ep-bw` to reproduce
the uncached/original path.

The packet-rate script uses `RATE_BENCHMARK` instead of `BENCHMARK` and
accepts `SRC_GPU`, `DST_GPU`, `MIN_COPY_SIZE`, `MAX_COPY_SIZE`,
`NUM_COPY_COMMANDS`, `MIN_QUEUES`, `MAX_QUEUES`, `WARMUP`, `ITERATIONS`,
`MODE`, and `OUTPUT_ROOT` overrides.
The rate executable selects one device-generated packet sequence with `--mode`:

```bash
sdma-ep-rate --mode copy
sdma-ep-rate --mode poll-copy
sdma-ep-rate --mode copy-atomic --atomic-memory local
sdma-ep-rate --mode poll-copy-atomic --atomic-memory remote
sdma-ep-rate --mode poll-only
sdma-ep-rate --mode atomic-only --atomic-memory local
```

These measure poll packets and local/remote atomic-add packets without copy
traffic.
For a queue sweep, select the mode with `MODE`:

```bash
MODE=poll-copy scripts/bench-packet-rate.sh
```

For a one-queue run covering every mode:

```bash
scripts/bench-packet-rate-isolated.sh
```

Common environment variables include `SRC_GPU`, `WARMUP`, `ITERATIONS`,
`OUTPUT_ROOT`, and `BENCHMARK`. Each driver also exposes its sweep values
as uppercase environment variables near the top of the script.

Each run creates a timestamped directory containing:

- One CSV file for each tested configuration.
- `summary.tsv`, containing command MPPS, time per command, and device latency
  for every isolated mode.
- `summary.md`, containing the same results as a Markdown table.
- `benchmark.log`, containing commands and console output.

The queue-sweep script additionally writes `summary.csv` containing all queue
configurations.

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
