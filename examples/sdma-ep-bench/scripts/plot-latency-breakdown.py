#!/usr/bin/env python3
"""Plot the fine-grained SDMA latency breakdown."""

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd


def format_size(size):
    if size < 1024:
        return f"{size:g}B"
    if size < 1024**2:
        return f"{size / 1024:g}KB"
    if size < 1024**3:
        return f"{size / 1024**2:g}MB"
    return f"{size / 1024**3:g}GB"


def plot_breakdown(input_path, output_path):
    data = pd.read_csv(input_path)
    required = {
        "Copy Size [B]",
        "Reserve [us]",
        "Build [us]",
        "Submit [us]",
        "Atomic Reserve [us]",
        "Atomic Build [us]",
        "Atomic Submit [us]",
        "Transfer [us]",
    }
    missing = sorted(required.difference(data.columns))
    if missing:
        names = ", ".join(missing)
        raise ValueError(f"{input_path} is missing columns: {names}")
    breakdown_columns = sorted(required - {"Copy Size [B]"})
    if data[breakdown_columns].abs().to_numpy().max() == 0:
        raise ValueError(
            "latency breakdown columns are all zero; rerun the benchmark "
            "with --fine-grained"
        )

    labels = [format_size(size) for size in data["Copy Size [B]"]]
    components = [
        ("Copy - Reserve Space", "Reserve [us]", "yellow"),
        ("Copy - Place Packet", "Build [us]", "palegreen"),
        ("Copy - Submit Packet", "Submit [us]", "skyblue"),
        ("Fence - Reserve Space", "Atomic Reserve [us]", "orange"),
        ("Fence - Place Packet", "Atomic Build [us]", "limegreen"),
        ("Fence - Submit Packet", "Atomic Submit [us]", "royalblue"),
        ("SDMA Copy & Signal", "Transfer [us]", "deeppink"),
    ]

    figure, axes = plt.subplots(figsize=(max(8, len(labels) * 0.7), 6))
    positions = range(len(labels))
    bottom = [0.0] * len(labels)
    table_values = []

    for name, column, color in components:
        values = data[column].astype(float).tolist()
        table_values.append([f"{value:.1f}" for value in values])
        axes.bar(positions, values, bottom=bottom, color=color, label=name)
        bottom = [current + value for current, value in zip(bottom, values)]

    axes.set_title("SDMA Latency Breakdown")
    axes.set_ylabel("Latency [us]")
    axes.set_xticks(list(positions), labels)
    axes.grid(axis="y", color="grey", linewidth=0.2)
    axes.legend(loc="upper left", bbox_to_anchor=(1.0, 1.0))
    figure.tight_layout()
    figure.savefig(output_path, dpi=150, bbox_inches="tight")
    print(f"Wrote {output_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Plot the fine-grained SDMA latency breakdown."
    )
    parser.add_argument("filename", type=Path, help="Latency CSV file")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Output PNG (default: beside the input CSV)",
    )
    args = parser.parse_args()
    output = args.output or args.filename.with_name(
        f"{args.filename.stem}_breakdown.png"
    )
    plot_breakdown(args.filename, output)


if __name__ == "__main__":
    main()
