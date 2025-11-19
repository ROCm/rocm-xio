#!/usr/bin/env python3
"""
Simple HTTP server to view benchmark results
"""

import http.server
import socketserver
import webbrowser
import sys
from pathlib import Path
import argparse


def serve_results(results_dir: Path, port: int = 8000, open_browser: bool = True):
    """Start HTTP server to serve benchmark results"""
    
    if not results_dir.exists():
        print(f"Error: Results directory {results_dir} not found")
        sys.exit(1)
    
    # Check if HTML report exists
    html_report = results_dir / "benchmark_report.html"
    if not html_report.exists():
        print(f"Generating HTML report...")
        from visualizer import generate_html_report
        generate_html_report(results_dir)
    
    # Change to results directory
    import os
    os.chdir(results_dir)
    
    # Create server
    Handler = http.server.SimpleHTTPRequestHandler
    
    try:
        with socketserver.TCPServer(("", port), Handler) as httpd:
            url = f"http://localhost:{port}/benchmark_report.html"
            print(f"\n" + "="*70)
            print(f"🚀 Benchmark Results Server")
            print(f"="*70)
            print(f"\nServing at: {url}")
            print(f"Results directory: {results_dir}")
            print(f"\nPress Ctrl+C to stop the server")
            print(f"="*70 + "\n")
            
            if open_browser:
                print(f"Opening browser...")
                webbrowser.open(url)
            
            httpd.serve_forever()
    except KeyboardInterrupt:
        print(f"\n\nServer stopped.")
        sys.exit(0)
    except OSError as e:
        if "Address already in use" in str(e):
            print(f"\nError: Port {port} is already in use.")
            print(f"Try a different port with: --port <number>")
        else:
            print(f"\nError: {e}")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="Serve ROCm-AXIIO benchmark results via HTTP",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Serve latest results
  %(prog)s results_20251104_153000/
  
  # Custom port
  %(prog)s results_20251104_153000/ --port 8080
  
  # Don't open browser automatically
  %(prog)s results_20251104_153000/ --no-browser
        """
    )
    
    parser.add_argument('results_dir', type=Path,
                        help='Results directory to serve')
    parser.add_argument('--port', type=int, default=8000,
                        help='Port to serve on (default: 8000)')
    parser.add_argument('--no-browser', action='store_true',
                        help="Don't open browser automatically")
    
    args = parser.parse_args()
    
    serve_results(args.results_dir, args.port, not args.no_browser)


if __name__ == "__main__":
    main()

