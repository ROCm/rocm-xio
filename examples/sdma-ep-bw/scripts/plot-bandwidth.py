#!/usr/bin/env python3
#
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

"""Plot device and host bandwidth from sdma-ep-bw CSV files."""

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd


def format_size(size):
    """Convert a byte count to a compact binary-unit label."""
    if size < 1024:
        return f"{size}B"
    if size < 1024**2:
        return f"{size / 1024:.0f}KiB"
    if size < 1024**3:
        return f"{size / 1024**2:.0f}MiB"
    return f"{size / 1024**3:.0f}GiB"


def plot_csv(csv_path, output_path=None):
    """Plot one benchmark CSV."""
    data = pd.read_csv(csv_path)
    required = {
        "Copy Size [B]",
        "Bandwidth [GB/s] (Device)",
        "Bandwidth [GB/s] (Host)",
        "#Destinations",
    }
    missing = required.difference(data.columns)
    if missing:
        missing_text = ", ".join(sorted(missing))
        raise ValueError(f"{csv_path}: missing columns: {missing_text}")

    figure, axis = plt.subplots(figsize=(10, 6))
    sizes = data["Copy Size [B]"]
    axis.plot(
        sizes,
        data["Bandwidth [GB/s] (Device)"],
        marker="o",
        label="Device wall clock",
    )
    axis.plot(
        sizes,
        data["Bandwidth [GB/s] (Host)"],
        marker="x",
        label="CPU observed",
    )
    axis.set_xscale("log", base=2)
    axis.set_xticks(sizes)
    axis.set_xticklabels([format_size(size) for size in sizes], rotation=45)
    axis.set_xlabel("Copy size")
    axis.set_ylabel(
        "Aggregate bandwidth (GB/s)"
        if int(data["#Destinations"].max()) > 1
        else "Bandwidth (GB/s)"
    )
    axis.set_title(f"SDMA bandwidth: {csv_path.stem}")
    axis.grid(axis="both", linewidth=0.3)
    axis.legend()
    figure.tight_layout()

    destination = output_path or csv_path.with_suffix(".png")
    figure.savefig(destination, dpi=300)
    plt.close(figure)
    print(f"Wrote {destination}")


def input_csvs(path):
    """Return individual CSV inputs for a file or result directory."""
    if path.is_file():
        return [path]
    if not path.is_dir():
        raise FileNotFoundError(path)
    return sorted(item for item in path.glob("*.csv") if item.name != "summary.csv")


def main():
    parser = argparse.ArgumentParser(
        description="Plot sdma-ep-bw bandwidth CSV files."
    )
    parser.add_argument("input", type=Path, help="CSV file or result directory")
    parser.add_argument(
        "--output",
        type=Path,
        help="output PNG path; valid only when input is one CSV",
    )
    args = parser.parse_args()

    csv_files = input_csvs(args.input)
    if not csv_files:
        parser.error(f"no benchmark CSV files found in {args.input}")
    if args.output and len(csv_files) != 1:
        parser.error("--output requires a single CSV input")

    for csv_path in csv_files:
        plot_csv(csv_path, args.output)


if __name__ == "__main__":
    main()
