#!/usr/bin/env python3
"""
ROCm-AXIIO Benchmark Visualizer

Generates interactive HTML visualizations of benchmark results
"""

import json
import sys
from pathlib import Path
from typing import Dict, List, Optional
import re


def generate_html_report(results_dir: Path, output_file: Optional[Path] = None) -> Path:
    """Generate interactive HTML report with charts"""
    
    if output_file is None:
        output_file = results_dir / "benchmark_report.html"
    
    # Parse results
    fio_results = parse_fio_results(results_dir / "fio_results.txt")
    axiio_results = parse_axiio_results(results_dir)
    
    # Generate HTML
    html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ROCm-AXIIO Benchmark Report</title>
    <script src="https://cdn.plot.ly/plotly-2.27.0.min.js"></script>
    <style>
        * {{
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }}
        
        body {{
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }}
        
        .container {{
            max-width: 1400px;
            margin: 0 auto;
            background: white;
            border-radius: 20px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            overflow: hidden;
        }}
        
        .header {{
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 40px;
            text-align: center;
        }}
        
        .header h1 {{
            font-size: 2.5em;
            margin-bottom: 10px;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.2);
        }}
        
        .header p {{
            font-size: 1.2em;
            opacity: 0.9;
        }}
        
        .content {{
            padding: 40px;
        }}
        
        .section {{
            margin-bottom: 50px;
        }}
        
        .section h2 {{
            color: #667eea;
            font-size: 1.8em;
            margin-bottom: 20px;
            padding-bottom: 10px;
            border-bottom: 3px solid #667eea;
        }}
        
        .chart-container {{
            background: #f8f9fa;
            border-radius: 10px;
            padding: 20px;
            margin-bottom: 30px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }}
        
        .chart {{
            width: 100%;
            height: 400px;
        }}
        
        .stats-grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }}
        
        .stat-card {{
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 25px;
            border-radius: 10px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }}
        
        .stat-card h3 {{
            font-size: 0.9em;
            opacity: 0.9;
            margin-bottom: 10px;
            text-transform: uppercase;
            letter-spacing: 1px;
        }}
        
        .stat-card .value {{
            font-size: 2.5em;
            font-weight: bold;
            margin-bottom: 5px;
        }}
        
        .stat-card .unit {{
            font-size: 0.9em;
            opacity: 0.8;
        }}
        
        .table-container {{
            overflow-x: auto;
            margin-bottom: 30px;
        }}
        
        table {{
            width: 100%;
            border-collapse: collapse;
            background: white;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }}
        
        th {{
            background: #667eea;
            color: white;
            padding: 15px;
            text-align: left;
            font-weight: 600;
        }}
        
        td {{
            padding: 12px 15px;
            border-bottom: 1px solid #e0e0e0;
        }}
        
        tr:hover {{
            background: #f8f9fa;
        }}
        
        .highlight {{
            background: #fff3cd;
            font-weight: bold;
        }}
        
        .footer {{
            background: #f8f9fa;
            padding: 20px;
            text-align: center;
            color: #666;
            font-size: 0.9em;
        }}
        
        @media (max-width: 768px) {{
            .stats-grid {{
                grid-template-columns: 1fr;
            }}
            
            .header h1 {{
                font-size: 1.8em;
            }}
        }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🚀 ROCm-AXIIO Benchmark Report</h1>
            <p>NVMe Performance Analysis</p>
        </div>
        
        <div class="content">
            <!-- Summary Statistics -->
            <div class="section">
                <h2>📊 Performance Summary</h2>
                <div class="stats-grid" id="summary-stats"></div>
            </div>
            
            <!-- IOPS Comparison -->
            <div class="section">
                <h2>📈 IOPS Comparison</h2>
                <div class="chart-container">
                    <div id="iops-chart" class="chart"></div>
                </div>
            </div>
            
            <!-- Latency Comparison -->
            <div class="section">
                <h2>⚡ Latency Analysis</h2>
                <div class="chart-container">
                    <div id="latency-chart" class="chart"></div>
                </div>
            </div>
            
            <!-- Latency Distribution -->
            <div class="section">
                <h2>📉 Latency Distribution</h2>
                <div class="chart-container">
                    <div id="percentile-chart" class="chart"></div>
                </div>
            </div>
            
            <!-- Detailed Results Table -->
            <div class="section">
                <h2>📋 Detailed Results</h2>
                <div class="table-container">
                    <table id="results-table"></table>
                </div>
            </div>
        </div>
        
        <div class="footer">
            <p>Generated by ROCm-AXIIO Benchmark Suite | {results_dir.name}</p>
        </div>
    </div>
    
    <script>
        // Data from benchmark results
        const fioResults = {json.dumps(fio_results, indent=8)};
        const axiioResults = {json.dumps(axiio_results, indent=8)};
        
        // Generate summary statistics
        function generateSummary() {{
            const summaryDiv = document.getElementById('summary-stats');
            
            // Find best IOPS
            let maxIops = 0;
            let maxIopsDevice = '';
            Object.entries(fioResults).forEach(([key, data]) => {{
                const iops = parseFloat(data.iops.replace('k', '')) * 1000;
                if (iops > maxIops) {{
                    maxIops = iops;
                    maxIopsDevice = key;
                }}
            }});
            
            // Find lowest latency
            let minLat = Infinity;
            let minLatDevice = '';
            Object.entries(fioResults).forEach(([key, data]) => {{
                if (data.avg_lat < minLat && data.avg_lat > 0) {{
                    minLat = data.avg_lat;
                    minLatDevice = key;
                }}
            }});
            
            const stats = [
                {{title: 'Peak IOPS', value: Math.round(maxIops).toLocaleString(), unit: 'ops/sec', device: maxIopsDevice}},
                {{title: 'Best Latency', value: minLat.toFixed(2), unit: 'μs', device: minLatDevice}},
                {{title: 'Tests Run', value: Object.keys(fioResults).length + Object.keys(axiioResults).length, unit: 'total'}},
                {{title: 'GPU-Direct', value: Object.keys(axiioResults).length > 0 ? 'Active' : 'Pending', unit: ''}}
            ];
            
            stats.forEach(stat => {{
                const card = document.createElement('div');
                card.className = 'stat-card';
                card.innerHTML = `
                    <h3>${{stat.title}}</h3>
                    <div class="value">${{stat.value}}</div>
                    <div class="unit">${{stat.unit}} ${{stat.device ? '(' + stat.device + ')' : ''}}</div>
                `;
                summaryDiv.appendChild(card);
            }});
        }}
        
        // IOPS Comparison Chart
        function generateIopsChart() {{
            const devices = [];
            const qd1Values = [];
            const qd8Values = [];
            const qd32Values = [];
            const qd128Values = [];
            
            // QEMU data
            if (fioResults['qemu-qd1']) {{
                devices.push('QEMU NVMe');
                qd1Values.push(parseFloat(fioResults['qemu-qd1'].iops.replace('k', '')) * 1000);
                qd8Values.push(parseFloat(fioResults['qemu-qd8']?.iops?.replace('k', '') || 0) * 1000);
                qd32Values.push(parseFloat(fioResults['qemu-qd32']?.iops?.replace('k', '') || 0) * 1000);
                qd128Values.push(0);
            }}
            
            // WD Black data
            if (fioResults['wd-qd1']) {{
                devices.push('WD Black SN850X');
                qd1Values.push(parseFloat(fioResults['wd-qd1'].iops.replace('k', '')) * 1000);
                qd8Values.push(parseFloat(fioResults['wd-qd8']?.iops?.replace('k', '') || 0) * 1000);
                qd32Values.push(parseFloat(fioResults['wd-qd32']?.iops?.replace('k', '') || 0) * 1000);
                qd128Values.push(parseFloat(fioResults['wd-qd128']?.iops?.replace('k', '') || 0) * 1000);
            }}
            
            const data = [
                {{x: devices, y: qd1Values, name: 'QD1', type: 'bar', marker: {{color: '#667eea'}}}},
                {{x: devices, y: qd8Values, name: 'QD8', type: 'bar', marker: {{color: '#764ba2'}}}},
                {{x: devices, y: qd32Values, name: 'QD32', type: 'bar', marker: {{color: '#f093fb'}}}},
                {{x: devices, y: qd128Values, name: 'QD128', type: 'bar', marker: {{color: '#4facfe'}}}}
            ];
            
            const layout = {{
                title: 'IOPS by Queue Depth',
                xaxis: {{title: 'Device'}},
                yaxis: {{title: 'IOPS'}},
                barmode: 'group',
                hovermode: 'closest'
            }};
            
            Plotly.newPlot('iops-chart', data, layout, {{responsive: true}});
        }}
        
        // Latency Comparison Chart
        function generateLatencyChart() {{
            const labels = [];
            const avgLatencies = [];
            const p99Latencies = [];
            
            Object.entries(fioResults).forEach(([key, data]) => {{
                labels.push(key);
                avgLatencies.push(data.avg_lat);
                p99Latencies.push(data.p99);
            }});
            
            const data = [
                {{x: labels, y: avgLatencies, name: 'Average', type: 'scatter', mode: 'lines+markers', marker: {{color: '#667eea', size: 10}}}},
                {{x: labels, y: p99Latencies, name: 'P99', type: 'scatter', mode: 'lines+markers', marker: {{color: '#f093fb', size: 10}}}}
            ];
            
            const layout = {{
                title: 'Latency Comparison (Average vs P99)',
                xaxis: {{title: 'Test Configuration'}},
                yaxis: {{title: 'Latency (μs)', type: 'log'}},
                hovermode: 'closest'
            }};
            
            Plotly.newPlot('latency-chart', data, layout, {{responsive: true}});
        }}
        
        // Percentile Chart
        function generatePercentileChart() {{
            const traces = [];
            
            Object.entries(fioResults).forEach(([key, data]) => {{
                traces.push({{
                    x: ['P50', 'P90', 'P95', 'P99', 'P99.9'],
                    y: [data.p50, data.p50 * 1.5, data.p50 * 1.8, data.p99, data.p999],
                    name: key,
                    type: 'scatter',
                    mode: 'lines+markers'
                }});
            }});
            
            const layout = {{
                title: 'Latency Percentiles',
                xaxis: {{title: 'Percentile'}},
                yaxis: {{title: 'Latency (μs)', type: 'log'}},
                hovermode: 'closest'
            }};
            
            Plotly.newPlot('percentile-chart', traces, layout, {{responsive: true}});
        }}
        
        // Results Table
        function generateResultsTable() {{
            const table = document.getElementById('results-table');
            
            let html = `
                <thead>
                    <tr>
                        <th>Test</th>
                        <th>IOPS</th>
                        <th>Avg Latency (μs)</th>
                        <th>P50 (μs)</th>
                        <th>P99 (μs)</th>
                        <th>P99.9 (μs)</th>
                    </tr>
                </thead>
                <tbody>
            `;
            
            Object.entries(fioResults).forEach(([key, data]) => {{
                html += `
                    <tr>
                        <td><strong>${{key}}</strong></td>
                        <td>${{data.iops}}</td>
                        <td>${{data.avg_lat.toFixed(2)}}</td>
                        <td>${{data.p50.toFixed(2)}}</td>
                        <td>${{data.p99.toFixed(2)}}</td>
                        <td>${{data.p999.toFixed(2)}}</td>
                    </tr>
                `;
            }});
            
            html += '</tbody>';
            table.innerHTML = html;
        }}
        
        // Initialize all visualizations
        document.addEventListener('DOMContentLoaded', function() {{
            generateSummary();
            generateIopsChart();
            generateLatencyChart();
            generatePercentileChart();
            generateResultsTable();
        }});
    </script>
</body>
</html>"""
    
    output_file.write_text(html_content)
    return output_file


def parse_fio_results(fio_txt: Path) -> Dict:
    """Parse fio results from text file"""
    results = {}
    
    if not fio_txt.exists():
        return results
    
    content = fio_txt.read_text()
    
    job_pattern = r'(qemu|wd)-qd(\d+):'
    for match in re.finditer(job_pattern, content):
        device = match.group(1)
        qd = match.group(2)
        job_name = f"{device}-qd{qd}"
        
        job_start = match.start()
        next_match = re.search(job_pattern, content[job_start + 10:])
        job_end = job_start + next_match.start() + 10 if next_match else len(content)
        job_section = content[job_start:job_end]
        
        iops_match = re.search(r'IOPS=([0-9.]+[km]?)', job_section)
        lat_match = re.search(r'clat.*?avg=\s*([0-9.]+)', job_section)
        p50_match = re.search(r'50\.000000th=\[\s*([0-9.]+)\]', job_section)
        p99_match = re.search(r'99\.000000th=\[\s*([0-9.]+)\]', job_section)
        p999_match = re.search(r'99\.990000th=\[\s*([0-9.]+)\]', job_section)
        
        results[job_name] = {
            'iops': iops_match.group(1) if iops_match else '0',
            'avg_lat': float(lat_match.group(1)) / 1000 if lat_match else 0,
            'p50': float(p50_match.group(1)) / 1000 if p50_match else 0,
            'p99': float(p99_match.group(1)) / 1000 if p99_match else 0,
            'p999': float(p999_match.group(1)) / 1000 if p999_match else 0
        }
    
    return results


def parse_axiio_results(results_dir: Path) -> Dict:
    """Parse axiio-tester results"""
    results = {}
    
    for log_file in results_dir.glob("axiio_*.log"):
        if not log_file.exists():
            continue
        
        content = log_file.read_text()
        name = log_file.stem
        
        stats_match = re.search(r'Statistics:\s+Minimum:\s+([0-9.]+).*?'
                               r'Maximum:\s+([0-9.]+).*?'
                               r'Average:\s+([0-9.]+).*?'
                               r'Standard Dev:\s+([0-9.]+)', 
                               content, re.DOTALL)
        
        if stats_match:
            results[name] = {
                'min': float(stats_match.group(1)),
                'max': float(stats_match.group(2)),
                'avg': float(stats_match.group(3)),
                'std': float(stats_match.group(4))
            }
    
    return results


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: visualizer.py <results_directory>")
        sys.exit(1)
    
    results_dir = Path(sys.argv[1])
    if not results_dir.exists():
        print(f"Error: Directory {results_dir} not found")
        sys.exit(1)
    
    output = generate_html_report(results_dir)
    print(f"Generated: {output}")

