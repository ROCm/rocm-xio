# SDMA bandwidth scripts

These scripts are adapted from the bandwidth drivers in the
`shader_sdma` prototype. They run the installed or standalone
`sdma-ep-bw` executable and collect timestamped CSV result sets.

Set `BENCHMARK` when the executable is not in the example's default
`build/` directory:

```bash
export BENCHMARK=/tmp/sdma-ep-bw-build/sdma-ep-bw
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
