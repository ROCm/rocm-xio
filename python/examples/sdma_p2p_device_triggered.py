#!/usr/bin/env python3
"""
PyTorch Symmetric Memory + Device-Triggered SDMA P2P Transfer Example

Demonstrates GPU-initiated data transfer using:
- Triton kernels to fill data and trigger SDMA
- Host-initiated SDMA with wait_flag_then_put (GPU kernel triggers transfer)
- Triton kernel on destination GPU to poll for completion and process data

Key difference from host-initiated example:
- GPU kernels drive the communication via flags
- Lower latency (GPU directly controls timing)
- Demonstrates device-triggered SDMA pattern

Requirements:
- 2+ AMD Instinct GPUs with XGMI/Infinity Fabric
- PyTorch nightly with symmetric memory support
- Triton
- rocm-xio Python bindings installed

Usage:
    torchrun --nproc-per-node=2 sdma_p2p_device_triggered.py

Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
SPDX-License-Identifier: MIT
"""

import argparse
import os
import sys

import torch
import torch.distributed as dist
import torch.distributed._symmetric_memory as symm_mem
import triton
import triton.language as tl

try:
    import xio.sdma_ep as sdma
except ImportError:
    print("ERROR: xio.sdma_ep module not found.")
    print("Please install rocm-xio Python bindings.")
    sys.exit(1)


# GPU 0 kernel: Fill data tensor and write trigger flag
@triton.jit
def fill_and_trigger_kernel(
    data_ptr,
    trigger_flag_ptr,
    numel,
    fill_value,
    BLOCK_SIZE: tl.constexpr,
):
    pid = tl.program_id(0)
    idx = pid * BLOCK_SIZE + tl.arange(0, BLOCK_SIZE)
    mask = idx < numel

    # Fill data with pattern
    # Convert data_ptr to bfloat16 pointer type
    data_ptr_bf16 = data_ptr.to(tl.pointer_type(tl.bfloat16))
    tl.store(data_ptr_bf16 + idx, fill_value, mask=mask)

    # First thread of first block writes trigger flag
    trigger_flag_ptr_i32 = trigger_flag_ptr.to(tl.pointer_type(tl.int32))
    tl.atomic_add(trigger_flag_ptr_i32, 1, sem="release", scope="sys")


# GPU 1 kernel: Poll for completion signal (64-bit), then add +1 to data
@triton.jit
def wait_and_add_kernel(
    data_ptr,
    completion_flag_ptr,
    numel,
    BLOCK_SIZE: tl.constexpr,
):
    pid = tl.program_id(0)

    # First thread of first block polls for completion signal (64-bit)
    completion_flag_ptr_i64 = completion_flag_ptr.to(tl.pointer_type(tl.int64))
    while tl.load(completion_flag_ptr_i64, cache_modifier=".cv", volatile=True) == 0:
        pass

    # Memory fence to ensure data transfer is visible after signal
    tl.atomic_add(completion_flag_ptr_i64, 0, sem="acquire", scope="sys")

    # Process data: add +1 to all elements
    idx = pid * BLOCK_SIZE + tl.arange(0, BLOCK_SIZE)
    mask = idx < numel
    data_ptr_bf16 = data_ptr.to(tl.pointer_type(tl.bfloat16))
    data = tl.load(data_ptr_bf16 + idx, mask=mask)
    result = data + 1.0
    tl.store(data_ptr_bf16 + idx, result, mask=mask)


def main():
    parser = argparse.ArgumentParser(
        description="PyTorch symmetric memory + device-triggered SDMA P2P example"
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
        print("Example: torchrun --nproc-per-node=2 sdma_p2p_device_triggered.py")
        sys.exit(1)

    local_rank = int(os.environ["LOCAL_RANK"])
    device = torch.device(f"cuda:{local_rank}")
    torch.cuda.set_device(device)

    dist.init_process_group("nccl", device_id=device)
    rank = dist.get_rank()
    world_size = dist.get_world_size()

    # Enable symmetric memory for the process group
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
    numel = args.size // torch.bfloat16.itemsize
    data_tensor = symm_mem.empty(numel, dtype=torch.bfloat16, device=device)
    data_tensor.zero_()

    # Rendezvous to get peer addresses and signal pads
    data_handle = symm_mem.rendezvous(data_tensor, group=dist.group.WORLD)

    # Zero out our signal pad before starting
    # Signal pads are accessed as device memory locations
    signal_pad_tensor = torch.zeros(1, dtype=torch.int64, device=device)
    signal_pad_ptr = data_handle.signal_pad_ptrs[rank]
    torch.cuda.memcpy_async(signal_pad_ptr, signal_pad_tensor.data_ptr(), 8)
    torch.cuda.synchronize()

    # Allocate trigger signal as regular device memory (only used locally on GPU 0)
    trigger_signal = torch.zeros(1, dtype=torch.int32, device=device)

    # Use signal pad from symmetric memory handle for GPU 1 completion polling
    # Signal pads are 64-bit and already part of the symmetric memory allocation

    # Initialize SDMA endpoint
    rc = sdma.init()
    if rc != 0:
        print(f"[Rank {rank}] ERROR: sdma.init() failed with code {rc}")
        dist.destroy_process_group()
        sys.exit(1)

    # Synchronize before starting
    dist.barrier()

    BLOCK_SIZE = 256

    if rank == 0:
        # Rank 0: Set up SDMA and launch GPU kernel

        # Access buffer and signal pad pointers from host-accessible arrays
        local_data_ptr = data_handle.buffer_ptrs[0]
        peer_data_ptr = data_handle.buffer_ptrs[1]
        peer_signal_pad_ptr = data_handle.signal_pad_ptrs[1]

        print(f"[Rank {rank}] Data tensor at: 0x{local_data_ptr:x}")
        print(f"[Rank {rank}] Peer data tensor (rank 1) at: 0x{peer_data_ptr:x}")
        print(f"[Rank {rank}] Trigger signal at: 0x{trigger_signal.data_ptr():x}")
        print(f"[Rank {rank}] Peer signal pad (rank 1) at: 0x{peer_signal_pad_ptr:x}")
        print(f"[Rank {rank}] data_tensor.data_ptr() = 0x{data_tensor.data_ptr():x}")
        print(f"[Rank {rank}] buffer_ptrs[0] = 0x{data_handle.buffer_ptrs[0]:x}")
        print(f"[Rank {rank}] Match: {local_data_ptr == data_tensor.data_ptr()}")
        print()

        # Create host-initiated SDMA queue
        sdma.create_host_queue(src_device=0, dst_device=1)

        # Set up wait_flag_then_put: waits for GPU 0 kernel to write trigger
        print(f"[Rank {rank}] Setting up SDMA wait_flag_then_put...")
        sdma.wait_flag_then_put(
            src_device=0,
            dst_device=1,
            channel_idx=0,
            flag_ptr=trigger_signal.data_ptr(),
            expected_value=1,
            src=local_data_ptr,
            dst=peer_data_ptr,
            size=args.size,
            flag_bits=32,
        )

        # Queue signal operation to notify GPU 1 (64-bit signal pad)
        print(f"[Rank {rank}] Queueing signal to GPU 1 signal pad...")
        sdma.signal(
            src_device=0,
            dst_device=1,
            channel_idx=0,
            flag_ptr=peer_signal_pad_ptr,
            value=1,
            flag_bits=64,
        )

        # Launch GPU 0 kernel (fills data and triggers SDMA)
        fill_value = 42.0
        grid = (triton.cdiv(numel, BLOCK_SIZE),)
        print(f"[Rank {rank}] Launching GPU 0 kernel (fill={fill_value})...")
        fill_and_trigger_kernel[grid](
            data_tensor.data_ptr(),
            trigger_signal.data_ptr(),
            numel,
            fill_value,
            BLOCK_SIZE=BLOCK_SIZE,
        )

        # Notify rank 1 that SDMA is set up and ready
        dist.barrier()

        # Wait for SDMA completion
        sdma.quiet(src_device=0, dst_device=1, channel_idx=0)
        print(f"[Rank {rank}] SDMA transfer complete")

    elif rank == 1:
        # Wait for rank 0 to queue SDMA operations
        dist.barrier()
        # Rank 1: Launch kernel to poll for SDMA completion and process data

        # Get our own signal pad pointer from host-accessible array
        my_signal_pad_ptr = data_handle.signal_pad_ptrs[1]

        # Launch GPU 1 kernel (waits for signal and adds +1)
        grid = (triton.cdiv(numel, BLOCK_SIZE),)
        print(f"[Rank {rank}] Launching GPU 1 kernel (wait + add +1)...")
        wait_and_add_kernel[grid](
            data_tensor.data_ptr(),
            my_signal_pad_ptr,
            numel,
            BLOCK_SIZE=BLOCK_SIZE,
        )

        # Wait for kernel completion
        torch.cuda.synchronize()
        print(f"[Rank {rank}] Kernel complete")

        # Verify data if requested
        if args.verify:
            expected = torch.full((numel,), 43.0, dtype=torch.bfloat16, device=device)

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
        print("SUCCESS: Device-triggered SDMA P2P transfer completed!")


if __name__ == "__main__":
    main()
