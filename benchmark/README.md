# ROCm-AXIIO Benchmark Suite

Comprehensive NVMe performance testing comparing inbox NVMe driver (fio) with GPU-direct axiio-tester.

## Features

- ✅ **Configurable Test Parameters**: Customize test size, block size, runtime
- ✅ **Data Preparation**: Writes random data to test region before testing
- ✅ **Inbox Driver Testing**: Uses fio with standard nvme driver
- ✅ **GPU-Direct Testing**: Uses axiio-tester with nvme_axiio driver
- ✅ **Comprehensive Metrics**: IOPS, latency, percentiles, histograms
- ✅ **Automated Reporting**: Generates markdown performance report

## Requirements

- Python 3.6+
- fio (Flexible I/O Tester)
- ROCm-AXIIO axiio-tester (built)
- nvme_axiio kernel module (loaded)
- Root/sudo access

## Quick Start

```bash
# Default configuration (64 GiB, 4 KiB blocks)
cd /path/to/rocm-axiio/benchmark
sudo ./nvme_benchmark.py

# Custom test size
sudo ./nvme_benchmark.py --test-size 128

# Different block size (8 KiB)
sudo ./nvme_benchmark.py --block-size 8192

# Skip data preparation (if already prepared)
sudo ./nvme_benchmark.py --skip-prep

# Only run fio tests
sudo ./nvme_benchmark.py --fio-only

# Only run axiio-tester
sudo ./nvme_benchmark.py --axiio-only
```

## Command-Line Options

```
usage: nvme_benchmark.py [-h] [--test-size GB] [--block-size BYTES]
                        [--runtime SEC] [--iterations N] [--output-dir DIR]
                        [--skip-prep] [--fio-only] [--axiio-only]

optional arguments:
  -h, --help           show this help message and exit
  --test-size GB       Test region size in GiB (default: 64)
  --block-size BYTES   Block size in bytes (default: 4096)
  --runtime SEC        Runtime per fio test in seconds (default: 60)
  --iterations N       Iterations for axiio-tester (default: 10000)
  --output-dir DIR     Output directory (default: results_<timestamp>)
  --skip-prep          Skip data preparation phase
  --fio-only           Only run fio tests, skip GPU-direct
  --axiio-only         Only run axiio-tester, skip fio
```

## Test Phases

### Phase 1: Data Preparation (~5-10 minutes)

Writes random data to the first N GiB of both NVMe devices to ensure realistic read testing.

```
- QEMU NVMe (/dev/nvme0n1)
- WD Black SN850X (/dev/nvme1n1)
```

### Phase 2: Inbox NVMe Driver Testing (~7-8 minutes)

Tests with standard Linux NVMe driver using fio at various queue depths:

**QEMU NVMe**: QD1, QD8, QD32  
**WD Black**: QD1, QD8, QD32, QD128

Metrics collected:
- IOPS
- Average latency
- Latency percentiles (P50, P90, P95, P99, P99.9, P99.99)

### Phase 3: GPU-Direct Testing (~5-10 minutes)

Tests with axiio-tester using nvme_axiio driver:

- Emulated baseline (10,000 iterations)
- WD Black QD1, QD2, QD3 (5,000 iterations each)

Metrics collected:
- Min/Max/Average latency
- Standard deviation
- Latency histograms

### Phase 4: Report Generation

Parses all results and generates comprehensive markdown report with:
- Configuration details
- Performance tables
- IOPS calculations
- Latency analysis

## Output Files

All results are saved to a timestamped directory (e.g., `results_20251104_153000/`):

```
results_<timestamp>/
├── PERFORMANCE_REPORT.md    # Human-readable summary
├── fio_results.txt          # Detailed fio output
├── fio_results.json         # Machine-readable fio data
├── axiio_emulated.log       # Emulated test log
├── axiio_wd_qd1.log         # GPU-direct QD1 log
├── axiio_wd_qd2.log         # GPU-direct QD2 log
├── axiio_wd_qd3.log         # GPU-direct QD3 log
├── prep_data.fio            # Data prep config
├── prep_output.txt          # Data prep output
└── benchmark_inbox.fio      # Fio benchmark config
```

## Example Results

```
=== Inbox NVMe Driver (fio) ===
WD Black SN850X - QD1:
  IOPS: 285k
  Avg Latency: 3.5 μs
  P99: 12.3 μs
  P99.9: 45.2 μs

=== GPU-Direct (axiio-tester) ===
WD Black - QD1:
  Average: 450 ns
  Std Dev: 120 ns
  (Doorbell write latency)
```

## Extensibility

The Python implementation is designed for easy extension:

### Adding New Test Configurations

```python
# In FioBenchmark.create_benchmark_config()
# Add new job sections to fio config
```

### Adding New Metrics

```python
# In ReportGenerator.parse_fio_results()
# Add new regex patterns and parsing logic
```

### Adding Custom Analysis

```python
# In ReportGenerator.generate_report()
# Add custom sections to markdown report
```

## Troubleshooting

### Device Not Found

Ensure both NVMe devices exist:
```bash
ls -l /dev/nvme0n1 /dev/nvme1n1
```

### Driver Binding Fails

Check kernel module is loaded:
```bash
lsmod | grep nvme
```

Load nvme_axiio if needed:
```bash
sudo insmod ../kernel-module/nvme_axiio.ko
```

### Permission Denied

Script requires root access:
```bash
sudo ./nvme_benchmark.py
```

## Performance Notes

- **Test Duration**: ~20-30 minutes for full benchmark
- **Disk Space**: Requires free space equal to test size on both devices
- **CPU Load**: Moderate during fio tests, low otherwise
- **I/O Impact**: Writes to test region during prep, reads during testing

## License

Part of ROCm-AXIIO project.

---

*For questions or issues, see main project README*

