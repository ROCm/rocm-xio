#!/usr/bin/env python3
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT

"""Split a rocm-xio shared library into per-architecture kpack archives.

This script extracts device code (HSACO) from a fat-binary
librocm-xio.so, creates one .kpack archive per GPU architecture,
and optionally strips the device code from the host library.

Usage:
    python3 kpack-split.py \
        --lib build/librocm-xio.so.0.1.0 \
        --output-dir build/kpack \
        [--strip] [--verbose]

Requires the rocm_kpack Python package (pip install rocm-kpack).
"""

import argparse
import sys
from pathlib import Path

try:
    from rocm_kpack.binutils import BundledBinary, Toolchain
    from rocm_kpack.kpack import PackedKernelArchive
    from rocm_kpack.compression import ZstdCompressor
    from rocm_kpack.artifact_utils import extract_architecture_from_target
except ImportError:
    print(
        "ERROR: rocm_kpack package not found.\n"
        "Install it with: pip install rocm-kpack\n"
        "Or from source: pip install -e /path/to/rocm-kpack",
        file=sys.stderr,
    )
    sys.exit(1)


def split_library(lib_path: Path, output_dir: Path, strip: bool, verbose: bool):
    """Extract per-arch HSACO from a fat-binary .so and create kpack archives."""
    if not lib_path.exists():
        raise FileNotFoundError(f"Library not found: {lib_path}")

    output_dir.mkdir(parents=True, exist_ok=True)
    toolchain = Toolchain()

    if verbose:
        print(f"Processing: {lib_path}")
        print(f"Output dir: {output_dir}")

    bb = BundledBinary(lib_path, toolchain=toolchain)
    kernels_by_arch: dict[str, list[tuple[str, bytes, int]]] = {}

    with bb.unbundle() as unbundled:
        if not unbundled.target_list:
            print(f"No bundled targets found in {lib_path}", file=sys.stderr)
            sys.exit(1)

        if verbose:
            print(f"Found {len(unbundled.target_list)} bundled target(s):")
            for target_name, filename in unbundled.target_list:
                print(f"  {target_name} -> {filename}")

        for (target_name, filename) in unbundled.target_list:
            arch = extract_architecture_from_target(target_name)
            if arch is None:
                if verbose:
                    print(f"  Skipping non-device target: {target_name}")
                continue

            out_path = unbundled.dest_dir / filename
            data = out_path.read_bytes()
            idx = kernels_by_arch.setdefault(arch, [])
            idx.append((target_name, data, len(idx)))

            if verbose:
                print(f"  Extracted {arch}: {len(data)} bytes")

    if not kernels_by_arch:
        print("No device code objects found in library", file=sys.stderr)
        sys.exit(1)

    lib_relpath = lib_path.name
    created = []

    for arch, kernels in sorted(kernels_by_arch.items()):
        archive_name = f"xio_{arch}.kpack"
        archive_path = output_dir / archive_name

        kpack = PackedKernelArchive(
            group_name="xio",
            gfx_arch_family=arch,
            gfx_arches=[arch],
            compressor=ZstdCompressor(),
        )

        for target_name, data, idx in kernels:
            binary_key = (
                f"{lib_relpath}#{idx}" if len(kernels) > 1 else lib_relpath
            )
            prepared = kpack.prepare_kernel(
                relative_path=binary_key,
                gfx_arch=arch,
                hsaco_data=data,
            )
            kpack.add_kernel(prepared)

        kpack.finalize_archive()
        kpack.write(archive_path)
        created.append((archive_path, arch, len(kernels)))

        if verbose:
            size_kb = archive_path.stat().st_size / 1024
            print(
                f"  Created {archive_name}: "
                f"{len(kernels)} kernel(s), {size_kb:.1f} KB"
            )

    if strip:
        try:
            from rocm_kpack.elf import kpack_offload_binary

            search_pattern = f".kpack/xio_@GFXARCH@.kpack"
            kpack_offload_binary(lib_path, lib_path, [search_pattern])
            if verbose:
                print(f"  Stripped device code from {lib_path}")
                print(f"  Injected kpack ref: {search_pattern}")
        except Exception as e:
            print(
                f"WARNING: Could not strip device code: {e}",
                file=sys.stderr,
            )

    print(f"\nkpack split complete: {len(created)} archive(s) created")
    for path, arch, count in created:
        print(f"  {path.name}  ({arch}, {count} kernel(s))")

    if strip:
        print(f"\nHost library stripped: {lib_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Split rocm-xio shared library into per-arch kpack archives"
    )
    parser.add_argument(
        "--lib",
        type=Path,
        required=True,
        help="Path to librocm-xio.so (the real file, not symlink)",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        required=True,
        help="Output directory for .kpack files",
    )
    parser.add_argument(
        "--strip",
        action="store_true",
        help="Strip device code from the library and inject kpack refs",
    )
    parser.add_argument(
        "--verbose", action="store_true", help="Verbose output"
    )
    args = parser.parse_args()

    try:
        split_library(args.lib, args.output_dir, args.strip, args.verbose)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
