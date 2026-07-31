#!/usr/bin/env python3
#
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

"""Compare regular and device-triggered SDMA bandwidth runs."""

import argparse
import csv
from pathlib import Path

import matplotlib.pyplot as plt


REQUIRED_COLUMNS = {
    "#Destinations",
    "#Queues",
    "Copy Size [B]",
    "Bandwidth [GB/s] (Device)",
    "Bandwidth [GB/s] (Host)",
}


def format_size(size):
    """Convert a byte count to a compact binary-unit label."""
    if size < 1024:
        return f"{size}B"
    if size < 1024**2:
        return f"{size / 1024:.0f}KiB"
    if size < 1024**3:
        return f"{size / 1024**2:.0f}MiB"
    return f"{size / 1024**3:.0f}GiB"


def load_run(path):
    """Load and validate one single-queue, single-destination run."""
    with path.open(newline="") as stream:
        reader = csv.DictReader(stream)
        columns = set(reader.fieldnames or [])
        missing = REQUIRED_COLUMNS.difference(columns)
        if missing:
            missing_text = ", ".join(sorted(missing))
            raise ValueError(f"{path}: missing columns: {missing_text}")
        rows = list(reader)

    destinations = {int(row["#Destinations"]) for row in rows}
    queues = {int(row["#Queues"]) for row in rows}
    if destinations != {1}:
        raise ValueError(f"{path}: expected exactly one destination")
    if queues != {1}:
        raise ValueError(f"{path}: expected exactly one queue")

    data = {}
    for row in rows:
        size = int(row["Copy Size [B]"])
        data[size] = {
            column: float(row[column])
            for column in REQUIRED_COLUMNS
            if column not in {"#Destinations", "#Queues", "Copy Size [B]"}
        }
    return data


def plot_comparison(regular_path, triggered_path, output_path):
    """Plot bandwidth from regular and device-triggered runs."""
    regular = load_run(regular_path)
    triggered = load_run(triggered_path)
    sizes = sorted(set(regular).intersection(triggered))
    if not sizes:
        raise ValueError("the two runs have no copy sizes in common")

    labels = {
        "Bandwidth [GB/s] (Device)": "Device wall clock",
        "Bandwidth [GB/s] (Host)": "CPU observed",
    }
    colors = {"Regular": "tab:blue", "Device-triggered": "tab:orange"}

    figure, axes = plt.subplots(1, 2, figsize=(13, 5.5), sharex=True)
    for axis, (column, metric) in zip(axes, labels.items()):
        axis.plot(
            sizes,
            [regular[size][column] for size in sizes],
            marker="o",
            color=colors["Regular"],
            label="Regular",
        )
        axis.plot(
            sizes,
            [triggered[size][column] for size in sizes],
            marker="o",
            color=colors["Device-triggered"],
            label="Device-triggered",
        )
        axis.set_xscale("log", base=2)
        axis.set_ylim(bottom=0)
        axis.set_xticks(sizes)
        axis.set_xticklabels([format_size(size) for size in sizes], rotation=45)
        axis.set_xlabel("Copy size")
        axis.set_ylabel("Bandwidth (GB/s)")
        axis.set_title(metric)
        axis.grid(axis="both", linewidth=0.3)
        axis.legend()

    figure.suptitle("SDMA bandwidth: regular vs device-triggered")
    figure.tight_layout()
    figure.savefig(output_path, dpi=300)
    plt.close(figure)
    print(f"Compared {len(sizes)} common copy sizes")
    print(f"Wrote {output_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Compare regular and device-triggered SDMA bandwidth CSVs."
    )
    parser.add_argument("regular", type=Path, help="regular-mode CSV")
    parser.add_argument("device_triggered", type=Path,
                        help="device-triggered CSV")
    parser.add_argument("-o", "--output", type=Path, required=True,
                        help="output PNG path")
    args = parser.parse_args()

    plot_comparison(args.regular, args.device_triggered, args.output)


if __name__ == "__main__":
    main()
