#!/usr/bin/env python3
"""
ROCm-AXIIO NVMe Benchmark Suite

Comprehensive performance testing comparing:
- Inbox NVMe driver (fio)
- GPU-direct axiio-tester

Features:
- Configurable test size and block size
- Automatic data preparation
- Latency histograms and percentiles
- IOPS calculations
- Markdown report generation
"""

import argparse
import json
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple
import re


class Colors:
    """ANSI color codes for terminal output"""
    HEADER = '\033[95m'
    OKBLUE = '\033[94m'
    OKCYAN = '\033[96m'
    OKGREEN = '\033[92m'
    WARNING = '\033[93m'
    FAIL = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'
    UNDERLINE = '\033[4m'


class BenchmarkConfig:
    """Configuration for benchmark execution"""
    
    def __init__(self, 
                 test_size_gb: int = 64,
                 block_size: int = 4096,
                 runtime_sec: int = 60,
                 iterations: int = 10000,
                 output_dir: Optional[Path] = None):
        self.test_size_gb = test_size_gb
        self.block_size = block_size
        self.runtime_sec = runtime_sec
        self.iterations = iterations
        self.output_dir = output_dir or Path(f"results_{datetime.now().strftime('%Y%m%d_%H%M%S')}")
        self.output_dir.mkdir(exist_ok=True)
        
        # Device paths
        self.qemu_device = "/dev/nvme0n1"
        self.wd_device = "/dev/nvme1n1"
        self.qemu_pci = "0000:01:00.0"
        self.wd_pci = "0000:03:00.0"
        
        # Axiio-tester path
        self.axiio_tester = Path("./bin/axiio-tester")
        
    def __str__(self):
        return f"""Benchmark Configuration:
  Test Size: {self.test_size_gb} GiB
  Block Size: {self.block_size} bytes ({self.block_size//1024} KiB)
  Runtime: {self.runtime_sec} seconds (fio tests)
  Iterations: {self.iterations} (axiio-tester tests)
  Output Directory: {self.output_dir}
"""


class DeviceManager:
    """Manages NVMe device driver binding"""
    
    @staticmethod
    def run_cmd(cmd: List[str], check=True, capture=True) -> subprocess.CompletedProcess:
        """Run shell command with sudo"""
        full_cmd = ['sudo'] + cmd
        if capture:
            return subprocess.run(full_cmd, check=check, capture_output=True, text=True)
        else:
            return subprocess.run(full_cmd, check=check)
    
    @staticmethod
    def unbind_device(pci_addr: str, driver: str) -> bool:
        """Unbind device from driver"""
        try:
            DeviceManager.run_cmd(
                ['sh', '-c', f'echo "{pci_addr}" > /sys/bus/pci/drivers/{driver}/unbind']
            )
            return True
        except subprocess.CalledProcessError:
            return False
    
    @staticmethod
    def bind_device(pci_addr: str, driver: str) -> bool:
        """Bind device to driver"""
        try:
            DeviceManager.run_cmd(
                ['sh', '-c', f'echo "{pci_addr}" > /sys/bus/pci/drivers/{driver}/bind']
            )
            time.sleep(2)  # Wait for device initialization
            return True
        except subprocess.CalledProcessError:
            return False
    
    @staticmethod
    def setup_inbox_driver(qemu_pci: str, wd_pci: str):
        """Setup both devices with inbox nvme driver"""
        print(f"{Colors.OKBLUE}Setting up devices with inbox nvme driver...{Colors.ENDC}")
        
        # Unbind from nvme_axiio if needed
        DeviceManager.unbind_device(qemu_pci, 'nvme_axiio')
        DeviceManager.unbind_device(wd_pci, 'nvme_axiio')
        
        # Bind to nvme
        DeviceManager.bind_device(qemu_pci, 'nvme')
        DeviceManager.bind_device(wd_pci, 'nvme')
        
        time.sleep(2)
        print(f"{Colors.OKGREEN}✓ Inbox driver setup complete{Colors.ENDC}\n")
    
    @staticmethod
    def setup_axiio_driver(wd_pci: str):
        """Setup WD device with nvme_axiio driver"""
        print(f"{Colors.OKBLUE}Setting up WD Black with nvme_axiio driver...{Colors.ENDC}")
        
        DeviceManager.unbind_device(wd_pci, 'nvme')
        DeviceManager.bind_device(wd_pci, 'nvme_axiio')
        
        time.sleep(2)
        print(f"{Colors.OKGREEN}✓ nvme_axiio driver setup complete{Colors.ENDC}\n")


class DataPreparation:
    """Handles initial data writing to test region"""
    
    @staticmethod
    def create_fio_config(config: BenchmarkConfig) -> Path:
        """Create fio config for data preparation"""
        fio_config = config.output_dir / "prep_data.fio"
        
        content = f"""[global]
ioengine=libaio
direct=1
bs=128k
rw=randwrite
numjobs=1
time_based=0
group_reporting=1
iodepth=32

[prep-nvme0]
filename={config.qemu_device}
size={config.test_size_gb}G

[prep-nvme1]
filename={config.wd_device}
size={config.test_size_gb}G
"""
        fio_config.write_text(content)
        return fio_config
    
    @staticmethod
    def prepare_data(config: BenchmarkConfig):
        """Write random data to test region"""
        print("=" * 80)
        print(f"{Colors.HEADER}{Colors.BOLD}PHASE 1: DATA PREPARATION{Colors.ENDC}")
        print("=" * 80)
        print(f"\nWriting random data to first {config.test_size_gb} GiB of both devices...")
        print("This ensures we're reading real data, not uninitialized blocks.\n")
        
        fio_config = DataPreparation.create_fio_config(config)
        output_file = config.output_dir / "prep_output.txt"
        
        try:
            with open(output_file, 'w') as f:
                subprocess.run(
                    ['sudo', 'fio', str(fio_config)],
                    stdout=f,
                    stderr=subprocess.STDOUT,
                    check=True
                )
            print(f"{Colors.OKGREEN}✓ Data preparation complete!{Colors.ENDC}\n")
            time.sleep(2)
        except subprocess.CalledProcessError as e:
            print(f"{Colors.FAIL}✗ Data preparation failed: {e}{Colors.ENDC}")
            sys.exit(1)


class FioBenchmark:
    """Handles fio benchmark execution"""
    
    @staticmethod
    def create_benchmark_config(config: BenchmarkConfig) -> Path:
        """Create fio benchmark config"""
        fio_config = config.output_dir / "benchmark_inbox.fio"
        
        content = f"""# 4KiB Random Read Benchmark - Inbox NVMe Driver

[global]
ioengine=libaio
direct=1
bs={config.block_size}
rw=randread
numjobs=1
runtime={config.runtime_sec}
time_based=1
group_reporting=1
size={config.test_size_gb}G
lat_percentiles=1
clat_percentiles=1
percentile_list=50:90:95:99:99.9:99.99

# QEMU NVMe - QD1
[qemu-qd1]
filename={config.qemu_device}
stonewall
iodepth=1

# QEMU NVMe - QD8
[qemu-qd8]
filename={config.qemu_device}
stonewall
iodepth=8

# QEMU NVMe - QD32
[qemu-qd32]
filename={config.qemu_device}
stonewall
iodepth=32

# WD Black - QD1
[wd-qd1]
filename={config.wd_device}
stonewall
iodepth=1

# WD Black - QD8
[wd-qd8]
filename={config.wd_device}
stonewall
iodepth=8

# WD Black - QD32
[wd-qd32]
filename={config.wd_device}
stonewall
iodepth=32

# WD Black - QD128
[wd-qd128]
filename={config.wd_device}
stonewall
iodepth=128
"""
        fio_config.write_text(content)
        return fio_config
    
    @staticmethod
    def run_benchmark(config: BenchmarkConfig):
        """Execute fio benchmark"""
        print("=" * 80)
        print(f"{Colors.HEADER}{Colors.BOLD}PHASE 2: INBOX NVME DRIVER TESTING (fio){Colors.ENDC}")
        print("=" * 80)
        print("\nTesting with standard Linux NVMe driver using fio...")
        print("This establishes baseline performance with proven driver stack.\n")
        
        fio_config = FioBenchmark.create_benchmark_config(config)
        txt_output = config.output_dir / "fio_results.txt"
        json_output = config.output_dir / "fio_results.json"
        
        num_tests = 7
        estimated_time = num_tests * config.runtime_sec // 60
        print(f"Running fio benchmarks ({num_tests} tests × {config.runtime_sec}s = ~{estimated_time} minutes)...\n")
        
        try:
            subprocess.run(
                ['sudo', 'fio', str(fio_config),
                 '--output-format=normal,json',
                 f'--output={txt_output}',
                 f'--output={json_output}'],
                check=True
            )
            print(f"\n{Colors.OKGREEN}✓ Inbox driver testing complete!{Colors.ENDC}\n")
            time.sleep(2)
        except subprocess.CalledProcessError as e:
            print(f"{Colors.FAIL}✗ Fio benchmark failed: {e}{Colors.ENDC}")
            sys.exit(1)


class AxiioBenchmark:
    """Handles axiio-tester benchmark execution"""
    
    @staticmethod
    def run_test(config: BenchmarkConfig, test_name: str, args: List[str]) -> Path:
        """Run single axiio-tester test"""
        output_file = config.output_dir / f"axiio_{test_name}.log"
        
        cmd = ['sudo', str(config.axiio_tester)] + args
        
        try:
            with open(output_file, 'w') as f:
                subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, check=False)
            return output_file
        except Exception as e:
            print(f"{Colors.WARNING}  Warning: {e}{Colors.ENDC}")
            return output_file
    
    @staticmethod
    def run_benchmark(config: BenchmarkConfig):
        """Execute axiio-tester benchmarks"""
        print("=" * 80)
        print(f"{Colors.HEADER}{Colors.BOLD}PHASE 3: GPU-DIRECT TESTING (axiio-tester){Colors.ENDC}")
        print("=" * 80)
        print("\nRunning axiio-tester benchmarks...\n")
        
        tests = [
            ("emulated", [
                "--endpoint", "nvme-ep",
                "--iterations", str(config.iterations),
                "--histogram",
                "--verbose"
            ]),
            ("wd_qd1", [
                "--endpoint", "nvme-ep",
                "--use-kernel-module",
                "--nvme-queue-id", "1",
                "--iterations", str(config.iterations // 2),
                "--histogram",
                "--verbose"
            ]),
            ("wd_qd2", [
                "--endpoint", "nvme-ep",
                "--use-kernel-module",
                "--nvme-queue-id", "2",
                "--iterations", str(config.iterations // 2),
                "--histogram",
                "--verbose"
            ]),
            ("wd_qd3", [
                "--endpoint", "nvme-ep",
                "--use-kernel-module",
                "--nvme-queue-id", "3",
                "--iterations", str(config.iterations // 2),
                "--histogram",
                "--verbose"
            ])
        ]
        
        for i, (name, args) in enumerate(tests, 1):
            print(f"Test {i}/{len(tests)}: {name}...")
            AxiioBenchmark.run_test(config, name, args)
            print()
        
        print(f"{Colors.OKGREEN}✓ GPU-direct testing complete!{Colors.ENDC}\n")
        time.sleep(1)


class ReportGenerator:
    """Generates markdown performance report"""
    
    @staticmethod
    def parse_fio_results(fio_txt: Path) -> Dict:
        """Parse fio text output"""
        results = {}
        
        if not fio_txt.exists():
            return results
        
        content = fio_txt.read_text()
        
        # Parse each job
        job_pattern = r'(qemu|wd)-qd(\d+):'
        for match in re.finditer(job_pattern, content):
            device = match.group(1)
            qd = match.group(2)
            job_name = f"{device}-qd{qd}"
            
            # Find job section
            job_start = match.start()
            next_match = re.search(job_pattern, content[job_start + 10:])
            job_end = job_start + next_match.start() + 10 if next_match else len(content)
            job_section = content[job_start:job_end]
            
            # Extract metrics
            iops_match = re.search(r'IOPS=([0-9.]+[km]?)', job_section)
            lat_match = re.search(r'clat.*?avg=\s*([0-9.]+)', job_section)
            p50_match = re.search(r'50\.000000th=\[\s*([0-9.]+)\]', job_section)
            p99_match = re.search(r'99\.000000th=\[\s*([0-9.]+)\]', job_section)
            p999_match = re.search(r'99\.990000th=\[\s*([0-9.]+)\]', job_section)
            
            results[job_name] = {
                'iops': iops_match.group(1) if iops_match else '-',
                'avg_lat': float(lat_match.group(1)) / 1000 if lat_match else 0,  # Convert to μs
                'p50': float(p50_match.group(1)) / 1000 if p50_match else 0,
                'p99': float(p99_match.group(1)) / 1000 if p99_match else 0,
                'p999': float(p999_match.group(1)) / 1000 if p999_match else 0
            }
        
        return results
    
    @staticmethod
    def parse_axiio_results(log_file: Path) -> Dict:
        """Parse axiio-tester log"""
        if not log_file.exists():
            return {}
        
        content = log_file.read_text()
        results = {}
        
        # Extract statistics
        stats_match = re.search(r'Statistics:\s+Minimum:\s+([0-9.]+).*?'
                               r'Maximum:\s+([0-9.]+).*?'
                               r'Average:\s+([0-9.]+).*?'
                               r'Standard Dev:\s+([0-9.]+)', 
                               content, re.DOTALL)
        
        if stats_match:
            results['min'] = float(stats_match.group(1))
            results['max'] = float(stats_match.group(2))
            results['avg'] = float(stats_match.group(3))
            results['std'] = float(stats_match.group(4))
        
        return results
    
    @staticmethod
    def generate_report(config: BenchmarkConfig):
        """Generate comprehensive markdown report"""
        print("=" * 80)
        print(f"{Colors.HEADER}{Colors.BOLD}PHASE 4: RESULTS ANALYSIS{Colors.ENDC}")
        print("=" * 80)
        print("\nGenerating comprehensive performance report...\n")
        
        report_file = config.output_dir / "PERFORMANCE_REPORT.md"
        
        # Parse results
        fio_results = ReportGenerator.parse_fio_results(config.output_dir / "fio_results.txt")
        
        # Generate report
        with open(report_file, 'w') as f:
            f.write("# NVMe Performance Benchmark Report\n\n")
            f.write("## Test Configuration\n\n")
            f.write(f"- **Test Date**: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write(f"- **Test Region**: First {config.test_size_gb} GiB of each device\n")
            f.write(f"- **Block Size**: {config.block_size} bytes ({config.block_size//1024} KiB)\n")
            f.write("- **Access Pattern**: Random Read\n")
            f.write("- **Data Preparation**: Random write to test region before testing\n\n")
            
            f.write("### Devices Tested\n\n")
            f.write("1. **QEMU NVMe Controller** (`/dev/nvme0n1`)\n")
            f.write("2. **WD Black SN850X** (`/dev/nvme1n1`)\n\n")
            
            f.write("---\n\n")
            f.write("## Inbox NVMe Driver (fio) Results\n\n")
            
            # QEMU results
            f.write("### QEMU NVMe Controller\n\n")
            f.write("| Queue Depth | IOPS | Avg Latency (μs) | P50 (μs) | P99 (μs) | P99.9 (μs) |\n")
            f.write("|-------------|------|------------------|----------|----------|------------|\n")
            
            for qd in [1, 8, 32]:
                key = f"qemu-qd{qd}"
                if key in fio_results:
                    r = fio_results[key]
                    f.write(f"| {qd} | {r['iops']} | {r['avg_lat']:.2f} | {r['p50']:.2f} | {r['p99']:.2f} | {r['p999']:.2f} |\n")
                else:
                    f.write(f"| {qd} | - | - | - | - | - |\n")
            
            f.write("\n### WD Black SN850X\n\n")
            f.write("| Queue Depth | IOPS | Avg Latency (μs) | P50 (μs) | P99 (μs) | P99.9 (μs) |\n")
            f.write("|-------------|------|------------------|----------|----------|------------|\n")
            
            for qd in [1, 8, 32, 128]:
                key = f"wd-qd{qd}"
                if key in fio_results:
                    r = fio_results[key]
                    f.write(f"| {qd} | {r['iops']} | {r['avg_lat']:.2f} | {r['p50']:.2f} | {r['p99']:.2f} | {r['p999']:.2f} |\n")
                else:
                    f.write(f"| {qd} | - | - | - | - | - |\n")
            
            f.write("\n---\n\n")
            f.write("## GPU-Direct (axiio-tester) Results\n\n")
            
            # Parse axiio results
            for log_file in sorted(config.output_dir.glob("axiio_*.log")):
                name = log_file.stem
                f.write(f"### {name}\n\n")
                
                results = ReportGenerator.parse_axiio_results(log_file)
                if results:
                    f.write("```\n")
                    f.write(f"Minimum:     {results['min']:.2f} ns\n")
                    f.write(f"Maximum:     {results['max']:.2f} ns\n")
                    f.write(f"Average:     {results['avg']:.2f} ns\n")
                    f.write(f"Std Dev:     {results['std']:.2f} ns\n")
                    f.write("```\n\n")
                else:
                    f.write("*Results parsing pending*\n\n")
            
            f.write("---\n\n")
            f.write("## Files Generated\n\n")
            f.write(f"- `fio_results.txt`: Detailed fio output\n")
            f.write(f"- `fio_results.json`: Machine-readable fio results\n")
            f.write(f"- `axiio_*.log`: Individual axiio-tester test logs\n\n")
            
            f.write("---\n\n")
            f.write("*Report generated by nvme_benchmark.py*\n")
        
        print(f"{Colors.OKGREEN}✓ Report generated: {report_file}{Colors.ENDC}\n")
        
        # Generate HTML visualization
        try:
            from visualizer import generate_html_report
            html_file = generate_html_report(config.output_dir)
            print(f"{Colors.OKGREEN}✓ HTML visualization generated: {html_file}{Colors.ENDC}\n")
        except Exception as e:
            print(f"{Colors.WARNING}Warning: Could not generate HTML visualization: {e}{Colors.ENDC}\n")
        
        # Display report
        print(report_file.read_text())


def main():
    parser = argparse.ArgumentParser(
        description="ROCm-AXIIO NVMe Benchmark Suite",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Default 64 GiB test region, 4 KiB blocks
  %(prog)s
  
  # Larger test region
  %(prog)s --test-size 128
  
  # Different block size
  %(prog)s --block-size 8192
  
  # Skip data preparation
  %(prog)s --skip-prep
  
  # Only run fio tests
  %(prog)s --fio-only
        """
    )
    
    parser.add_argument('--test-size', type=int, default=64, metavar='GB',
                        help='Test region size in GiB (default: 64)')
    parser.add_argument('--block-size', type=int, default=4096, metavar='BYTES',
                        help='Block size in bytes (default: 4096)')
    parser.add_argument('--runtime', type=int, default=60, metavar='SEC',
                        help='Runtime per fio test in seconds (default: 60)')
    parser.add_argument('--iterations', type=int, default=10000, metavar='N',
                        help='Iterations for axiio-tester (default: 10000)')
    parser.add_argument('--output-dir', type=Path, metavar='DIR',
                        help='Output directory (default: results_<timestamp>)')
    parser.add_argument('--skip-prep', action='store_true',
                        help='Skip data preparation phase')
    parser.add_argument('--fio-only', action='store_true',
                        help='Only run fio tests, skip GPU-direct')
    parser.add_argument('--axiio-only', action='store_true',
                        help='Only run axiio-tester, skip fio')
    parser.add_argument('--serve', action='store_true',
                        help='Start web server to view results after benchmark')
    parser.add_argument('--port', type=int, default=8000, metavar='PORT',
                        help='Port for web server (default: 8000)')
    
    args = parser.parse_args()
    
    # Create config
    config = BenchmarkConfig(
        test_size_gb=args.test_size,
        block_size=args.block_size,
        runtime_sec=args.runtime,
        iterations=args.iterations,
        output_dir=args.output_dir
    )
    
    # Print header
    print("\n" + "=" * 80)
    print(f"{Colors.HEADER}{Colors.BOLD}ROCm-AXIIO NVMe Benchmark Suite{Colors.ENDC}")
    print("=" * 80)
    print(config)
    
    try:
        # Phase 1: Data Preparation
        if not args.skip_prep and not args.axiio_only:
            DeviceManager.setup_inbox_driver(config.qemu_pci, config.wd_pci)
            DataPreparation.prepare_data(config)
        
        # Phase 2: Fio Benchmark
        if not args.axiio_only:
            DeviceManager.setup_inbox_driver(config.qemu_pci, config.wd_pci)
            FioBenchmark.run_benchmark(config)
        
        # Phase 3: Axiio Benchmark
        if not args.fio_only:
            DeviceManager.setup_axiio_driver(config.wd_pci)
            AxiioBenchmark.run_benchmark(config)
        
        # Phase 4: Report Generation
        ReportGenerator.generate_report(config)
        
        # Summary
        print("=" * 80)
        print(f"{Colors.OKGREEN}{Colors.BOLD}BENCHMARK COMPLETE!{Colors.ENDC}")
        print("=" * 80)
        print(f"\nResults saved to: {config.output_dir}/")
        print(f"Report: {config.output_dir}/PERFORMANCE_REPORT.md")
        print(f"HTML: {config.output_dir}/benchmark_report.html")
        
        # Start web server if requested
        if args.serve:
            print(f"\n{Colors.OKCYAN}Starting web server...{Colors.ENDC}\n")
            from serve import serve_results
            serve_results(config.output_dir, args.port)
        else:
            print(f"\nTo view interactive results:")
            print(f"  cd benchmark")
            print(f"  ./serve.py {config.output_dir}\n")
        
    except KeyboardInterrupt:
        print(f"\n{Colors.WARNING}Benchmark interrupted by user{Colors.ENDC}")
        sys.exit(1)
    except Exception as e:
        print(f"\n{Colors.FAIL}Error: {e}{Colors.ENDC}")
        sys.exit(1)


if __name__ == "__main__":
    main()

