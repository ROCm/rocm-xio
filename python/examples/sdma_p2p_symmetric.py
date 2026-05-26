#!/usr/bin/env python3
"""
PyTorch Symmetric Memory + Host-Initiated SDMA P2P Transfer Example

Demonstrates GPU-to-GPU data transfer using:
- PyTorch symmetric memory for tensor allocation
- Host-initiated SDMA transfers via rocm-xio Python bindings

Key difference from device-initiated (C++) examples:
- Host calls sdma.put() and sdma.quiet() to initiate and wait for transfers
- No GPU-side signal polling needed (host blocks in quiet() until complete)
- Simpler than device-initiated, but higher latency

Requirements:
- 2+ AMD Instinct GPUs with XGMI/Infinity Fabric
- PyTorch nightly with symmetric memory support
- rocm-xio Python bindings installed

Usage:
    torchrun --nproc-per-node=2 sdma_p2p_symmetric.py

Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
SPDX-License-Identifier: MIT
"""

import argparse
import os
import sys

import torch
import torch.distributed as dist
import torch.distributed._symmetric_memory as symm_mem

try:
    import xio.sdma_ep as sdma
except ImportError:
    print("ERROR: xio.sdma_ep module not found.")
    print("Please install rocm-xio Python bindings.")
    sys.exit(1)


def get_peer_ptr(symm_mem_handle, peer_rank, tensor):
    """
    Get the device pointer for a specific peer rank from symmetric memory handle.

    Args:
        symm_mem_handle: Handle returned by symm_mem.rendezvous()
        peer_rank: Rank of the peer GPU
        tensor: The original tensor (for shape/dtype)

    Returns:
        Device pointer (uintptr_t) for the peer's buffer
    """
    # Use get_buffer() to get a tensor view of the peer's memory
    peer_buffer = symm_mem_handle.get_buffer(
        peer_rank, tensor.shape, tensor.dtype, storage_offset=0
    )
    return peer_buffer.data_ptr()


def main():
    parser = argparse.ArgumentParser(
        description="PyTorch symmetric memory + SDMA P2P transfer example"
    )
    parser.add_argument(
        "--size",
        type=int,
        default=4096,
        help="Transfer size in bytes (default: 4096)",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="Verify data after transfer (default: False)",
    )
    args = parser.parse_args()

    # Distributed setup
    if "LOCAL_RANK" not in os.environ:
        print("ERROR: Must be run with torchrun")
        print("Example: torchrun --nproc-per-node=2 sdma_p2p_symmetric.py")
        sys.exit(1)

    local_rank = int(os.environ["LOCAL_RANK"])
    device = torch.device(f"cuda:{local_rank}")
    torch.cuda.set_device(device)

    dist.init_process_group("nccl", device_id=device)
    rank = dist.get_rank()
    world_size = dist.get_world_size()

    # Enable symmetric memory for the process group
    # This handles peer access setup automatically
    symm_mem.enable_symm_mem_for_group(dist.group.WORLD.group_name)

    if world_size < 2:
        if rank == 0:
            print("ERROR: Need at least 2 GPUs")
        dist.destroy_process_group()
        sys.exit(1)

    # Print GPU info
    if rank == 0:
        gpu_props = torch.cuda.get_device_properties(0)
        print(f"GPU 0: {gpu_props.name}")
        gpu_props = torch.cuda.get_device_properties(1)
        print(f"GPU 1: {gpu_props.name}")
        print(f"Transfer size: {args.size} bytes")
        print(f"Verify: {args.verify}")
        print()

    # Allocate symmetric memory tensor
    # Use bfloat16 to match the reference symm-mem-recipes
    numel = args.size // torch.bfloat16.itemsize

    data_tensor = symm_mem.empty(numel, dtype=torch.bfloat16, device=device)
    data_tensor.zero_()

    # Rendezvous to share addresses across ranks
    # Returns a handle with buffer_ptrs_dev containing all peer addresses
    data_handle = symm_mem.rendezvous(data_tensor, group=dist.group.WORLD)

    if rank == 0:
        local_data_ptr = data_tensor.data_ptr()
        peer_data_ptr = get_peer_ptr(data_handle, 1, data_tensor)

        print(f"[Rank {rank}] Data tensor at: 0x{local_data_ptr:x}")
        print(f"[Rank {rank}] Peer data tensor (rank 1) at: 0x{peer_data_ptr:x}")
        print()

    # Initialize SDMA endpoint
    rc = sdma.init()
    if rc != 0:
        print(f"[Rank {rank}] ERROR: sdma.init() failed with code {rc}")
        dist.destroy_process_group()
        sys.exit(1)

    # Synchronize before starting transfers
    dist.barrier()

    if rank == 0:
        # Rank 0: Send data to Rank 1

        # Fill tensor with pattern (0xAB in bfloat16 representation)
        fill_value = torch.tensor(0xAB, dtype=torch.bfloat16)
        data_tensor.fill_(fill_value)

        # Ensure data is written before SDMA transfer
        torch.cuda.synchronize()

        # Create host-initiated SDMA queue
        sdma.create_host_queue(src_device=0, dst_device=1)

        print(f"[Rank {rank}] Initiating SDMA transfer to Rank 1...")

        # Initiate SDMA transfer (no signal needed for host-initiated)
        sdma.put(
            src_device=0,
            dst_device=1,
            channel_idx=0,
            dst=peer_data_ptr,  # Destination: rank 1's data buffer
            src=data_tensor.data_ptr(),  # Source: rank 0's data buffer
            size=args.size,
        )

        # Wait for SDMA operation to complete (blocks until done)
        sdma.quiet(src_device=0, dst_device=1, channel_idx=0)

        print(f"[Rank {rank}] Transfer complete")

    # Synchronize all ranks before verification
    dist.barrier()

    if rank == 1:
        # Rank 1: Verify received data

        # Verify data if requested
        if args.verify:
            fill_value = torch.tensor(0xAB, dtype=torch.bfloat16)
            expected = torch.full((numel,), fill_value, dtype=torch.bfloat16, device=device)

            if torch.equal(data_tensor, expected):
                print(f"[Rank {rank}] Data verification: PASS")
            else:
                # Find first mismatch for debugging
                mismatch = (data_tensor != expected).nonzero(as_tuple=True)[0]
                if len(mismatch) > 0:
                    idx = mismatch[0].item()
                    print(f"[Rank {rank}] Data verification: FAIL")
                    print(f"  First mismatch at index {idx}:")
                    print(f"    Expected: {expected[idx].item()}")
                    print(f"    Got: {data_tensor[idx].item()}")
                else:
                    print(f"[Rank {rank}] Data verification: PASS")

    # Synchronize before cleanup
    dist.barrier()

    # Cleanup
    sdma.shutdown()
    dist.destroy_process_group()

    if rank == 0:
        print()
        print("SUCCESS: PyTorch symmetric memory + SDMA P2P transfer completed!")


if __name__ == "__main__":
    main()
