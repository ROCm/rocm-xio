# Quick Start Guide

## 🚀 Run Your First Benchmark

```bash
cd /home/stebates/Projects/rocm-axiio/benchmark
sudo ./nvme_benchmark.py
```

This will:
1. Write random data to first 64 GiB of both NVMe devices
2. Run fio benchmarks (7 tests × 60 seconds)
3. Run GPU-direct axiio-tester benchmarks
4. Generate performance report

**Total Time**: ~20-30 minutes

---

## 📊 Common Usage Patterns

### Quick Test (Smaller Region, Faster)
```bash
sudo ./nvme_benchmark.py --test-size 8 --runtime 30
```
*8 GiB region, 30 second fio tests (~5-10 minutes total)*

### Large Comprehensive Test
```bash
sudo ./nvme_benchmark.py --test-size 128 --runtime 120
```
*128 GiB region, 2 minute fio tests (~40-60 minutes total)*

### Different Block Sizes

**8 KiB blocks** (common database workload):
```bash
sudo ./nvme_benchmark.py --block-size 8192
```

**16 KiB blocks** (large I/O):
```bash
sudo ./nvme_benchmark.py --block-size 16384
```

### Skip Data Preparation
If you've already prepared data and just want to re-run tests:
```bash
sudo ./nvme_benchmark.py --skip-prep
```

### Only Baseline (fio) Testing
To only test with inbox nvme driver (no GPU-direct):
```bash
sudo ./nvme_benchmark.py --fio-only
```

### Only GPU-Direct Testing
To only test axiio-tester (assumes data already prepared):
```bash
sudo ./nvme_benchmark.py --axiio-only --skip-prep
```

---

## 📁 Where Are My Results?

Results are saved to timestamped directories:
```
results_20251104_153045/
├── PERFORMANCE_REPORT.md    ← Start here!
├── fio_results.txt
├── fio_results.json
└── axiio_*.log
```

View the report:
```bash
cat results_*/PERFORMANCE_REPORT.md
```

---

## 🔧 Customize for Your Needs

### Edit Test Parameters Directly

The Python script is designed to be easily modified:

**Add more queue depths** (lines 280-300):
```python
# In FioBenchmark.create_benchmark_config()
# Add:
[wd-qd256]
filename={config.wd_device}
stonewall
iodepth=256
```

**Change fio parameters** (line 270):
```python
# Modify global section:
numjobs=4  # Run 4 parallel jobs
```

**Add custom metrics** (lines 450-480):
```python
# In ReportGenerator.parse_fio_results()
# Add new regex patterns
```

### Create Custom Test Script

```python
#!/usr/bin/env python3
from nvme_benchmark import *

config = BenchmarkConfig(
    test_size_gb=32,
    block_size=4096,
    runtime_sec=30,
    iterations=5000
)

# Run only what you need
DataPreparation.prepare_data(config)
FioBenchmark.run_benchmark(config)
```

---

## 🎯 Interpreting Results

### IOPS (I/O Operations Per Second)
- **Higher is better**
- QD1: Single-threaded performance (~3,000-50,000 IOPS typical)
- QD32+: Saturated throughput (~100,000-500,000+ IOPS possible)

### Latency
- **Lower is better**
- QD1: ~1-100 μs typical for fast NVMe
- P99: 99% of operations complete within this time
- P99.9: Tail latency (important for consistent performance)

### GPU-Direct Metrics
- Current results show **doorbell write latency**
- Sub-microsecond doorbell writes = working infrastructure
- Full I/O latency coming after completion reception fix

---

## 🐛 Troubleshooting

### "Device not found"
Check devices exist:
```bash
ls -l /dev/nvme0n1 /dev/nvme1n1
```

### "Module not loaded"
Load kernel module:
```bash
cd ../kernel-module
sudo insmod nvme_axiio.ko
```

### "Permission denied"
Must run with sudo:
```bash
sudo ./nvme_benchmark.py
```

### Script hangs during fio
Press Ctrl+C to interrupt. Results up to that point are saved.

---

## 📈 Example Output

```
================================================================================
                   ROCm-AXIIO NVMe Benchmark Suite
================================================================================

Benchmark Configuration:
  Test Size: 64 GiB
  Block Size: 4096 bytes (4 KiB)
  Runtime: 60 seconds (fio tests)
  Iterations: 10000 (axiio-tester tests)
  Output Directory: results_20251104_153045

╔══════════════════════════════════════════════════════════════╗
║              PHASE 1: DATA PREPARATION                        ║
╚══════════════════════════════════════════════════════════════╝

Writing random data to first 64 GiB of both devices...
✓ Data preparation complete!

╔══════════════════════════════════════════════════════════════╗
║        PHASE 2: INBOX NVME DRIVER TESTING (fio)              ║
╚══════════════════════════════════════════════════════════════╝

Running fio benchmarks (7 tests × 60s = ~7 minutes)...
✓ Inbox driver testing complete!

╔══════════════════════════════════════════════════════════════╗
║          PHASE 3: GPU-DIRECT TESTING (axiio-tester)          ║
╚══════════════════════════════════════════════════════════════╝

Running axiio-tester benchmarks...
✓ GPU-direct testing complete!

╔══════════════════════════════════════════════════════════════╗
║                 PHASE 4: RESULTS ANALYSIS                     ║
╚══════════════════════════════════════════════════════════════╝

✓ Report generated: results_20251104_153045/PERFORMANCE_REPORT.md

================================================================================
                         BENCHMARK COMPLETE!
================================================================================

Results saved to: results_20251104_153045/
```

---

## 🔬 Advanced: Extending the Benchmark

### Add New Test Configurations

Edit `nvme_benchmark.py` and add to the tests list:

```python
# In AxiioBenchmark.run_benchmark()
tests = [
    # ... existing tests ...
    ("wd_custom", [
        "--endpoint", "nvme-ep",
        "--use-kernel-module",
        "--nvme-queue-id", "5",
        "--iterations", "20000",
        "--use-data-buffers",  # Test with real I/O
        "--transfer-size", "8192",  # 8 KiB transfers
        "--histogram",
        "--verbose"
    ])
]
```

### Parse Custom Metrics

```python
# In ReportGenerator class
@staticmethod
def parse_custom_metric(log_file: Path) -> float:
    content = log_file.read_text()
    match = re.search(r'Custom Metric: ([0-9.]+)', content)
    return float(match.group(1)) if match else 0.0
```

### Export to CSV

```python
# Add to ReportGenerator
@staticmethod
def export_csv(results: Dict, output_file: Path):
    import csv
    with open(output_file, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=results[0].keys())
        writer.writeheader()
        writer.writerows(results.values())
```

---

## 📚 Next Steps

1. **Run baseline benchmark**: `sudo ./nvme_benchmark.py`
2. **Review PERFORMANCE_REPORT.md**: Check inbox driver performance
3. **Debug GPU completions**: Once working, re-run for full comparison
4. **Experiment with parameters**: Try different block sizes and queue depths
5. **Add custom tests**: Extend the Python script for your workload

---

*Questions? See README.md or main project documentation*

