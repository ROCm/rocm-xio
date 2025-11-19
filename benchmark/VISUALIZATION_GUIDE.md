# Interactive Visualization Guide

## Overview

The ROCm-AXIIO benchmark suite now includes interactive web-based visualizations using Plotly.js for analyzing performance results.

## Features

✅ **Interactive Charts**
- IOPS comparison across devices and queue depths
- Latency analysis with log-scale visualization
- Percentile distributions (P50, P90, P95, P99, P99.9)
- Hover for detailed metrics

✅ **Beautiful Web Interface**
- Modern gradient design
- Responsive layout (mobile-friendly)
- Summary statistics cards
- Detailed results tables

✅ **Built-in Web Server**
- One-command serving
- Auto-open in browser
- No external dependencies

## Usage

### Method 1: Automatic (Recommended)

Run benchmark with `--serve` flag to automatically start web server:

```bash
sudo ./nvme_benchmark.py --test-size 64 --serve
```

This will:
1. Run the complete benchmark
2. Generate HTML visualization
3. Start web server on port 8000
4. Open browser automatically

### Method 2: Manual

Generate HTML after running benchmark:

```bash
# Run benchmark
sudo ./nvme_benchmark.py --test-size 64

# Generate HTML visualization
./visualizer.py results_<timestamp>/

# Serve with web server
./serve.py results_<timestamp>/
```

### Method 3: Custom Port

If port 8000 is in use:

```bash
sudo ./nvme_benchmark.py --test-size 64 --serve --port 8080
```

Or for existing results:

```bash
./serve.py results_<timestamp>/ --port 8080
```

## Interactive Features

### 1. IOPS Comparison Chart

**Bar chart** showing IOPS across different queue depths:
- Hover over bars to see exact IOPS values
- Click legend items to show/hide specific queue depths
- Compare QEMU vs WD Black performance

### 2. Latency Analysis Chart

**Line chart** with markers showing:
- Average latency trend
- P99 latency trend  
- Log scale for better visibility of ranges
- Hover for exact latency values

### 3. Latency Percentile Chart

**Multi-line chart** showing latency percentiles:
- P50 (median)
- P90, P95, P99, P99.9
- Identify tail latency issues
- Compare percentiles across configurations

### 4. Summary Statistics Cards

**Gradient cards** displaying:
- Peak IOPS achieved
- Best latency recorded
- Number of tests run
- GPU-Direct status

### 5. Detailed Results Table

**Sortable table** with:
- All test configurations
- IOPS, average latency
- Percentiles (P50, P99, P99.9)
- Highlight on hover

## Chart Interactions

### Zoom and Pan
- **Zoom**: Click and drag to select region
- **Pan**: Hold shift and drag
- **Reset**: Double-click chart

### Show/Hide Data
- Click legend items to toggle data series
- Double-click legend to isolate single series

### Download
- Hover over chart
- Click camera icon in top-right
- Save as PNG

### Hover Details
- Hover over any data point
- See detailed tooltip with all metrics
- Compare multiple series simultaneously

## Customizing Visualizations

### Edit Color Scheme

In `visualizer.py`, modify the marker colors:

```python
data = [
    {x: devices, y: qd1Values, name: 'QD1', 
     marker: {color: '#667eea'}},  # Change this
    {x: devices, y: qd8Values, name: 'QD8',
     marker: {color: '#764ba2'}},  # Change this
]
```

### Add Custom Charts

In `visualizer.py`, add new chart generation:

```python
def generate_custom_chart():
    # Your chart logic
    data = [...]
    layout = {...}
    Plotly.newPlot('custom-chart', data, layout)
```

Then call it in the HTML template:

```javascript
document.addEventListener('DOMContentLoaded', function() {
    // ...existing charts...
    generateCustomChart();
});
```

### Modify Layout

Edit the CSS in the HTML template:

```html
<style>
    .container {
        max-width: 1400px;  /* Change width */
        /* ... */
    }
    
    .chart {
        height: 400px;  /* Change chart height */
    }
</style>
```

## Exporting Results

### Save Charts as Images

1. Open HTML report in browser
2. Hover over chart
3. Click camera icon
4. PNG saved to Downloads

### Export to PDF

Browser print function:
1. Open HTML report
2. Press Ctrl+P (Cmd+P on Mac)
3. Select "Save as PDF"
4. Adjust settings
5. Save

### Share Results

**Method 1: Copy HTML file**
```bash
cp results_*/benchmark_report.html ~/shared_folder/
```

**Method 2: Start server and share URL**
```bash
./serve.py results_*/ --port 8000
# Share: http://your-server-ip:8000/benchmark_report.html
```

**Method 3: Email**
- HTML file is self-contained
- Includes all JavaScript (Plotly CDN)
- Can be opened offline
- ~20KB file size

## Advanced: Programmatic Access

### Generate HTML from Python

```python
from visualizer import generate_html_report
from pathlib import Path

results_dir = Path("results_20251104_153000")
html_file = generate_html_report(results_dir)
print(f"Generated: {html_file}")
```

### Parse Results Only

```python
from visualizer import parse_fio_results, parse_axiio_results
from pathlib import Path

results_dir = Path("results_20251104_153000")

# Get fio results as dict
fio_data = parse_fio_results(results_dir / "fio_results.txt")

# Get axiio results as dict  
axiio_data = parse_axiio_results(results_dir)

# Process data
for test_name, metrics in fio_data.items():
    print(f"{test_name}: {metrics['iops']} IOPS")
```

### Custom Visualization

```python
from visualizer import parse_fio_results
import matplotlib.pyplot as plt

fio_data = parse_fio_results(Path("results_*/fio_results.txt"))

# Extract data
devices = []
latencies = []
for name, data in fio_data.items():
    devices.append(name)
    latencies.append(data['avg_lat'])

# Create custom matplotlib chart
plt.bar(devices, latencies)
plt.ylabel('Latency (μs)')
plt.title('Average Latency Comparison')
plt.xticks(rotation=45)
plt.tight_layout()
plt.savefig('custom_chart.png')
```

## Troubleshooting

### Port Already in Use

```bash
# Try different port
./serve.py results_*/ --port 8080

# Or kill existing process
lsof -ti:8000 | xargs kill -9
```

### Browser Doesn't Open

```bash
# Manually open URL
./serve.py results_*/ --no-browser
# Then navigate to: http://localhost:8000/benchmark_report.html
```

### Charts Not Rendering

1. Check browser console (F12)
2. Ensure internet connection (Plotly CDN)
3. Try different browser
4. Check JavaScript is enabled

### Missing Data in Charts

- Ensure fio completed successfully
- Check `fio_results.txt` exists and has data
- Verify parsing regex in `visualizer.py`
- Run benchmark with longer `--runtime`

## Performance Notes

- **HTML Generation**: < 1 second
- **File Size**: ~20-50 KB (self-contained)
- **Browser Load**: Instant (JavaScript rendering)
- **Server Overhead**: Minimal (Python HTTP server)

## Security

### Local Use Only

Default server binds to localhost (127.0.0.1):
- Not accessible from network
- Safe for local viewing
- No authentication needed

### Network Sharing

To expose on network (use with caution):

```python
# In serve.py, change:
with socketserver.TCPServer(("", port), Handler) as httpd:
# To:
with socketserver.TCPServer(("0.0.0.0", port), Handler) as httpd:
```

**Warning**: Only do this on trusted networks!

## Examples

### Quick Visualization of Existing Results

```bash
./visualizer.py results_20251104_153000/
# Opens: results_20251104_153000/benchmark_report.html
```

### Run Benchmark with Auto-Serve

```bash
sudo ./nvme_benchmark.py --test-size 32 --serve
# Benchmark runs, then web server starts automatically
```

### Share Results with Team

```bash
# Generate HTML
./visualizer.py results_*/

# Start server accessible from network
# (Edit serve.py first - see Security section)
./serve.py results_*/ --port 8080

# Share URL: http://your-ip:8080/benchmark_report.html
```

---

## Next Steps

1. Run your first benchmark with visualization
2. Explore the interactive charts
3. Customize colors and layout to your preference
4. Export and share results
5. Integrate into your CI/CD pipeline

**Happy benchmarking!** 📊🚀

