# SDMA Benchmark Scripts

These scripts run the SDMA benchmark executables from the example `build/`
directory and collect timestamped CSV result sets.

## Bandwidth Benchmark

The bandwidth executable is `build/sdma-ep-bw`.

Available sweeps:

- `bench-bandwidth-single.sh`: vary the number of destinations.
- `bench-bandwidth-single-device-triggered.sh`: vary destinations using
  device-triggered SDMA queues.
- `bench-bandwidth-multiproducer.sh`: vary queues and workgroups.
- `bench-contention-singlequeue.sh`: vary producers sharing one queue.
- `bench-contention-multiqueue.sh`: distribute a fixed workgroup count across
  multiple queues.

The bandwidth benchmark uses cached `SdmaQueueState` by default for queue
read-pointer checks. Pass `--no-queue-state` to `sdma-ep-bw` to reproduce the
uncached path.

Each bandwidth run creates a timestamped directory containing CSV results and
the benchmark log. The defaults are intentionally large and may allocate
several gigabytes per GPU. Override copy sizes, destination counts, or
producer counts for short smoke runs.

## Latency Benchmark

The latency executable is `build/sdma-ep-latency`.

Run a copy-size sweep:

```bash
scripts/bench-latency.sh
```

Queue-state caching is enabled by default. Pass `--no-queue-state` to measure
the uncached queue-management path.

Use `FINE_GRAINED=1` to collect queue reservation, packet construction,
submission, fence, and transfer timing:

```bash
FINE_GRAINED=1 scripts/bench-latency.sh
```

The fine-grained results can be plotted as a stacked PNG:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r scripts/requirements.txt
python3 scripts/plot-latency-breakdown.py \
  results_latency_YYYY-MM-DD_HHhMMmSSs/summary.csv
```

The latency script accepts `SRC_GPU`, `DST_GPU`, `MIN_COPY_SIZE`,
`MAX_COPY_SIZE`, `NUM_COPY_COMMANDS`, `WARMUP`, `ITERATIONS`, `FINE_GRAINED`,
and `OUTPUT_ROOT` overrides.

## Packet-Rate Benchmark

The packet-rate executable is `build/sdma-ep-rate`.

Select one device-generated packet sequence with `--mode`:

```bash
build/sdma-ep-rate --mode copy
build/sdma-ep-rate --mode poll-copy
build/sdma-ep-rate --mode copy-atomic --atomic-memory local
build/sdma-ep-rate --mode poll-copy-atomic --atomic-memory remote
build/sdma-ep-rate --mode poll-only
build/sdma-ep-rate --mode atomic-only --atomic-memory local
```

The packet-rate sweep runs one mode while varying queue counts. Select the mode
with `MODE`:

```bash
MODE=poll-copy scripts/bench-packet-rate.sh
```

The isolated runner executes all six modes with one queue, including local and
remote atomic targets:

```bash
scripts/bench-packet-rate-isolated.sh
```

The isolated runner creates one CSV per mode, `summary.tsv`, `summary.md`, and
`benchmark.log`. The queue sweep additionally writes `summary.csv` containing
all queue configurations.

The packet-rate scripts accept `SRC_GPU`, `DST_GPU`, `MIN_COPY_SIZE`,
`MAX_COPY_SIZE`, `NUM_COPY_COMMANDS`, `MIN_QUEUES`, `MAX_QUEUES`, `WARMUP`,
`ITERATIONS`, `MODE`, and `OUTPUT_ROOT` overrides.
