/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include "nvme-ep.h"
#include "xio-endpoint-registry.h"
#include "xio.h"
#include "xio-kmod.h"
#include "xio-mmio-bridge.h"

// Host-only includes for IOCTL and file operations
#ifndef __HIP_DEVICE_COMPILE__
#include <errno.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <drm/amdgpu_drm.h>
#include <drm/drm.h>
#include <fcntl.h>
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <linux/ioctl.h>
#include <linux/nvme_ioctl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#endif // __HIP_DEVICE_COMPILE__

// Namespace all nvme-ep implementation to avoid conflicts
namespace nvme_ep {

// Types (sqeType, cqeType) are defined in nvme-ep.h

// Verify that the queue entry sizes match nvme-ep expectations
static_assert(sizeof(sqeType) == NVME_EP_SQE_SIZE, "nvme-ep SQE size mismatch");
static_assert(sizeof(cqeType) == NVME_EP_CQE_SIZE, "nvme-ep CQE size mismatch");

//
// NVMe-specific helper functions
//

// Compare two NVMe SQEs by command ID
__host__ __device__ bool nvme_sqe_equal(const sqeType* a, const sqeType* b) {
  return (a->command_id == b->command_id && a->opcode == b->opcode);
}

// Compare two NVMe CQEs by command ID
__host__ __device__ bool nvme_cqe_equal(const cqeType* a, const cqeType* b) {
  return (a->command_id == b->command_id);
}

// Read SQE - copies entire NVMe command structure
__host__ __device__ sqeType sqeRead(volatile sqeType* sqeAddress) {
  sqeType result;
  // Copy the entire structure byte-by-byte to handle volatile correctly
  const volatile uint8_t* src = reinterpret_cast<const volatile uint8_t*>(
    sqeAddress);
  uint8_t* dst = reinterpret_cast<uint8_t*>(&result);
  for (size_t i = 0; i < sizeof(sqeType); i++) {
    dst[i] = src[i];
  }
  return result;
}

// Read CQE - copies entire NVMe completion structure
// Uses atomic loads with acquire semantics to ensure CPU/DMA writes are visible
// to GPU cores. Critical for GPU-PCIe coherency when controller writes via DMA.
__host__ __device__ cqeType cqeRead(volatile cqeType* cqeAddress) {
  cqeType result = {};
  
#ifdef __HIP_DEVICE_COMPILE__
  // On GPU: Ensure memory visibility before reading. Use system-level memory
  // fence to ensure CPU/DMA writes are visible to GPU cores.
  __threadfence_system();
  
  // Wait for all memory operations to complete before reading
  // This ensures we don't read stale cached values
  __builtin_amdgcn_s_waitcnt(0);
  
  // Use atomic loads with acquire semantics for critical fields to ensure
  // CPU/DMA writes are visible. The status field (which contains phase bit) is
  // written LAST by the controller, so reading it LAST with acquire semantics
  // ensures all previous writes to other fields are visible.
  // Read command_id with acquire semantics
  volatile uint16_t* cmd_id_ptr = 
    reinterpret_cast<volatile uint16_t*>(&cqeAddress->command_id);
  result.command_id = __hip_atomic_load(cmd_id_ptr, __ATOMIC_ACQUIRE,
                                        __HIP_MEMORY_SCOPE_SYSTEM);
  
  // Read sq_head with acquire semantics
  volatile uint16_t* sq_head_ptr = 
    reinterpret_cast<volatile uint16_t*>(&cqeAddress->sq_head);
  result.sq_head = __hip_atomic_load(sq_head_ptr, __ATOMIC_ACQUIRE,
                                      __HIP_MEMORY_SCOPE_SYSTEM);
  
  // Read sq_id with acquire semantics
  volatile uint16_t* sq_id_ptr = 
    reinterpret_cast<volatile uint16_t*>(&cqeAddress->sq_id);
  result.sq_id = __hip_atomic_load(sq_id_ptr, __ATOMIC_ACQUIRE,
                                    __HIP_MEMORY_SCOPE_SYSTEM);
  
  // Read result and rsvd with acquire semantics (use 32-bit atomic loads)
  volatile uint32_t* result_ptr = 
    reinterpret_cast<volatile uint32_t*>(&cqeAddress->result);
  result.result = __hip_atomic_load(result_ptr, __ATOMIC_ACQUIRE,
                                     __HIP_MEMORY_SCOPE_SYSTEM);
  
  volatile uint32_t* rsvd_ptr = 
    reinterpret_cast<volatile uint32_t*>(&cqeAddress->rsvd);
  result.rsvd = __hip_atomic_load(rsvd_ptr, __ATOMIC_ACQUIRE,
                                   __HIP_MEMORY_SCOPE_SYSTEM);
  
  // Read status LAST (last field written by controller) with acquire semantics.
  // This acts as a synchronization point - reading status with acquire ensures
  // all previous writes by the controller are visible.
  volatile uint16_t* status_ptr = 
    reinterpret_cast<volatile uint16_t*>(&cqeAddress->status);
  result.status = __hip_atomic_load(status_ptr, __ATOMIC_ACQUIRE,
                                     __HIP_MEMORY_SCOPE_SYSTEM);
  
  // Wait for all loads to complete before returning
  __builtin_amdgcn_s_waitcnt(0);
#else
  // On CPU: Use regular memory barrier
  __sync_synchronize();
  // Copy the entire structure byte-by-byte to handle volatile correctly
  const volatile uint8_t* src = reinterpret_cast<const volatile uint8_t*>(
    cqeAddress);
  uint8_t* dst = reinterpret_cast<uint8_t*>(&result);
  for (size_t i = 0; i < sizeof(cqeType); i++) {
    dst[i] = src[i];
  }
#endif
  return result;
}

// Write SQE - copies entire NVMe command structure with memory fence
__host__ __device__ void sqeWrite(sqeType sqeData,
                                  volatile sqeType* sqeAddress) {
  // Copy entire structure byte-by-byte to handle volatile correctly
  // Uses volatile pointer to ensure writes are not optimized away and are
  // visible to PCIe devices (critical for GPU-PCIe coherency)
  const uint8_t* src = reinterpret_cast<const uint8_t*>(&sqeData);
  volatile uint8_t* dst = reinterpret_cast<volatile uint8_t*>(sqeAddress);
  for (size_t i = 0; i < sizeof(sqeType); i++) {
    dst[i] = src[i];
  }
#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
#endif // __HIP_DEVICE_COMPILE__
}

// Write CQE - copies entire NVMe completion structure with memory fence
// Uses volatile pointer to ensure writes are not optimized away
__host__ __device__ void cqeWrite(cqeType cqeData,
                                  volatile cqeType* cqeAddress) {
  // Copy entire structure byte-by-byte to handle volatile correctly
  const uint8_t* src = reinterpret_cast<const uint8_t*>(&cqeData);
  volatile uint8_t* dst = reinterpret_cast<volatile uint8_t*>(cqeAddress);
  for (size_t i = 0; i < sizeof(cqeType); i++) {
    dst[i] = src[i];
  }
#ifdef __HIP_DEVICE_COMPILE__
  __threadfence_system();
#endif // __HIP_DEVICE_COMPILE__
}

// Poll for new SQE - waits for command ID to change
__host__ __device__ sqeType sqePoll(sqeType sqeLast,
                                    volatile sqeType* sqeAddress) {
  sqeType sqeNew;
  while (true) {
    sqeNew = sqeRead(sqeAddress);
    // Check if we got a new command (different command ID or different opcode)
    if (sqeNew.command_id != sqeLast.command_id ||
        sqeNew.opcode != sqeLast.opcode) {
      return sqeNew;
    }
  }
}

// Poll for new CQE - waits for command ID to change or sq_head progression
// Improved implementation with command ID verification, stale completion
// handling, and queue size-aware wrap-around detection
__host__ __device__ cqeType cqePoll(cqeType cqeLast,
                                    volatile cqeType* cqeAddress,
                                    uint16_t last_sq_head,
                                    uint16_t* sq_head_out,
                                    uint16_t expected_cid,
                                    uint16_t queue_size,
                                    uint16_t* cq_head_inout,
                                    bool* cqe_advanced_out,
                                    uint8_t* expected_phase_inout) {
  cqeType cqeNew;
  uint16_t effective_last_sq_head = last_sq_head;
  
  // Timeout mechanism: break after 1 second of polling without progress
  // Use both iteration-based and time-based timeouts for reliability
  // Very aggressive timeout to prevent infinite stalls
  // Max iterations before timeout (very aggressive)
  const uint32_t max_iterations = 100000;
  uint32_t iteration_count = 0;
  
#ifdef __HIP_DEVICE_COMPILE__
  const uint64_t timeout_ns = 1000000000ULL; // 1 second in nanoseconds
  uint64_t start_time = wall_clock64();
  uint64_t last_progress_time = start_time;
#endif
  
  while (true) {
    iteration_count++;
    
    // Read CQE first (before timeout check) so we always return valid data
    cqeNew = cqeRead(cqeAddress);
    
    // Check timeout VERY frequently to catch stalls immediately
    // Check every 10 iterations, or every iteration after 1000
    bool check_timeout = (iteration_count % 10 == 0) || (iteration_count > 1000);
    
    if (check_timeout) {
      // Check iteration-based timeout (most reliable - doesn't depend on wall_clock64)
      if (iteration_count > max_iterations) {
        // Timeout exceeded - ALWAYS advance cq_head and return to make progress
        // This prevents infinite loops even if CID logic fails
        if (cq_head_inout != nullptr && queue_size > 0) {
          *cq_head_inout = (*cq_head_inout + 1) % queue_size;
          if (cqe_advanced_out != nullptr) {
            *cqe_advanced_out = true;
          }
        }
        if (sq_head_out != nullptr) {
          *sq_head_out = effective_last_sq_head;
        }
        return cqeNew;
      }
      
      // Check time-based timeout (secondary check)
#ifdef __HIP_DEVICE_COMPILE__
      uint64_t current_time = wall_clock64();
      if (current_time - last_progress_time > timeout_ns) {
        // Timeout exceeded - ALWAYS advance cq_head to make progress
        if (cq_head_inout != nullptr && queue_size > 0) {
          *cq_head_inout = (*cq_head_inout + 1) % queue_size;
          if (cqe_advanced_out != nullptr) {
            *cqe_advanced_out = true;
          }
        }
        if (sq_head_out != nullptr) {
          *sq_head_out = effective_last_sq_head;
        }
        return cqeNew;
      }
#endif
    }
    uint16_t sq_head = cqeNew.sq_head;

    // Primary check: sq_head progression (definitive indicator of completion)
    // sq_head is updated by the controller when commands complete
    bool sq_head_progressed = false;
    
    if (sq_head > effective_last_sq_head) {
      // Normal case: sq_head increased without wrapping
      sq_head_progressed = true;
    } else if (sq_head < effective_last_sq_head) {
      // Wrap-around detected - but verify phase bit to avoid false positives
      // from stale data (e.g., sq_head=0 in uninitialized CQE)
      bool phase_validates_wrap = true;
      if (expected_phase_inout != nullptr && queue_size > 0) {
        uint8_t phase = NVME_CQE_STATUS_PHASE(cqeNew.status);
        // If phase doesn't match expected, this might be stale data, not real wrap
        if (phase != *expected_phase_inout) {
          // Phase doesn't match - likely stale data, don't trust sq_head
          phase_validates_wrap = false;
        }
      }
      
      if (phase_validates_wrap) {
        if (queue_size > 0) {
          // Verify wrap is reasonable (difference <= queue_size)
          // For queue_size=8 (entries 0-7), max wrap diff is 8 (from 7 to 0)
          uint16_t diff = effective_last_sq_head - sq_head;
          if (diff <= queue_size) {
            sq_head_progressed = true;
          }
        } else {
          // No queue_size provided - assume wrap is valid
          sq_head_progressed = true;
        }
      }
    }
    
    if (sq_head_progressed) {
      // sq_head progressed - a command completed
      
      // Phase bit verification (if enabled)
      // Skip phase check if expected_phase is 0xFF (first operation)
      bool phase_ok = true;
      if (expected_phase_inout != nullptr && *expected_phase_inout != 0xFF) {
        uint8_t phase = NVME_CQE_STATUS_PHASE(cqeNew.status);
        phase_ok = (phase == *expected_phase_inout);
      }
      
      // Command ID verification (if enabled)
      if (expected_cid != 0) {
        if (cqeNew.command_id == expected_cid) {
          // CID matches - check phase if enabled
          // However, if sq_head progressed, that's definitive - accept the
          // completion even if phase doesn't match (phase might be wrong due to
          // initialization or wrap-around timing)
          if (expected_phase_inout != nullptr && !phase_ok) {
            // CID matches but phase doesn't - however, sq_head progression is
            // definitive, so accept it anyway. Phase might be wrong due to:
            // 1. Initial CQE being uninitialized
            // 2. Phase bit timing around wrap-around
            // Update expected_phase to match what we actually saw
            uint8_t phase = NVME_CQE_STATUS_PHASE(cqeNew.status);
            if (cq_head_inout != nullptr && queue_size > 0) {
              uint16_t next_cq_head = (*cq_head_inout + 1) % queue_size;
              if (next_cq_head == 0) {
                *expected_phase_inout = phase ^ 1;
              } else {
                *expected_phase_inout = phase;
              }
            } else {
              *expected_phase_inout = phase;
            }
            // Continue to return this completion (sq_head progression is definitive)
          }
          // Our command completed - success (CID matches and phase OK if checked)
          if (sq_head_out != nullptr) {
            *sq_head_out = sq_head;
          }
          if (cqe_advanced_out != nullptr) {
            *cqe_advanced_out = false;
          }
          // Update expected phase for next completion
          // Phase flips only when controller wraps CQ (from entry N-1 to 0), not
          // per completion. All entries in same loop have same phase.
          if (expected_phase_inout != nullptr && cq_head_inout != nullptr &&
              queue_size > 0) {
            uint8_t phase = NVME_CQE_STATUS_PHASE(cqeNew.status);
            uint16_t next_cq_head = (*cq_head_inout + 1) % queue_size;
            if (next_cq_head == 0) {
              // cq_head will wrap - phase flips on next loop
              *expected_phase_inout = phase ^ 1;
            } else {
              // Same loop - phase stays the same
              *expected_phase_inout = phase;
            }
          } else if (expected_phase_inout != nullptr) {
            // Fallback: flip phase if we can't check wrap (shouldn't happen)
            uint8_t phase = NVME_CQE_STATUS_PHASE(cqeNew.status);
            *expected_phase_inout = phase;
          }
          return cqeNew;
        } else {
          // Wrong command ID - this is a stale completion
          // Also check phase if enabled - if phase doesn't match, definitely stale
          if (expected_phase_inout != nullptr && !phase_ok) {
            // Phase doesn't match - definitely stale, advance cq_head
            if (cq_head_inout != nullptr && queue_size > 0) {
              *cq_head_inout = (*cq_head_inout + 1) % queue_size;
              if (cqe_advanced_out != nullptr) {
                *cqe_advanced_out = true;
              }
            } else if (cqe_advanced_out != nullptr) {
              *cqe_advanced_out = true;
            }
            // Continue polling for next CQE
            iteration_count = 0; // Reset on progress
#ifdef __HIP_DEVICE_COMPILE__
            last_progress_time = wall_clock64();
#endif
            continue;
          }
          
          // Always advance cq_head when CID doesn't match to prevent infinite loops
          if (cq_head_inout != nullptr && queue_size > 0) {
            *cq_head_inout = (*cq_head_inout + 1) % queue_size;
            if (cqe_advanced_out != nullptr) {
              *cqe_advanced_out = true;
            }
          } else if (cqe_advanced_out != nullptr) {
            *cqe_advanced_out = true;
          }
          
          // Update sq_head tracking
          effective_last_sq_head = sq_head;
          if (sq_head_out != nullptr) {
            *sq_head_out = sq_head;
          }
          // Return this CQE - caller should check cqe_advanced_out and
          // if true, use updated cq_head_inout to get next CQE address
          iteration_count = 0; // Reset on progress
#ifdef __HIP_DEVICE_COMPILE__
          last_progress_time = wall_clock64();
#endif
          return cqeNew;
        }
      } else {
        // No CID verification - check phase if enabled
        // Skip phase check if expected_phase is 0xFF (first operation)
        if (expected_phase_inout != nullptr && *expected_phase_inout != 0xFF) {
          uint8_t phase = NVME_CQE_STATUS_PHASE(cqeNew.status);
          if (phase != *expected_phase_inout) {
            // Phase doesn't match - this is a stale completion, continue polling
            iteration_count = 0; // Reset on progress
#ifdef __HIP_DEVICE_COMPILE__
            last_progress_time = wall_clock64();
#endif
            continue;
          }
          // Phase matches - update for next completion
          // Phase flips only when controller wraps CQ (from entry N-1 to 0), not
          // per completion. All entries in same loop have same phase.
          if (cq_head_inout != nullptr && queue_size > 0) {
            uint16_t next_cq_head = (*cq_head_inout + 1) % queue_size;
            if (next_cq_head == 0) {
              // cq_head will wrap - phase flips on next loop
              *expected_phase_inout = phase ^ 1;
            } else {
              // Same loop - phase stays the same
              *expected_phase_inout = phase;
            }
          } else {
            // Fallback: keep same phase if we can't check wrap
            *expected_phase_inout = phase;
          }
        }
        // Return immediately
        if (sq_head_out != nullptr) {
          *sq_head_out = sq_head;
        }
        if (cqe_advanced_out != nullptr) {
          *cqe_advanced_out = false;
        }
        return cqeNew;
      }
    }

    // Don't advance cq_head when sq_head hasn't progressed - we're just waiting
    // for a completion. Only advance when we detect actual progress or timeout.

    // Check phase bit even when sq_head hasn't progressed - this detects when
    // controller overwrites stale CQE entries (e.g., when cq_head wraps to 0)
    // Skip phase check if expected_phase is 0xFF (first operation)
    if (expected_phase_inout != nullptr && *expected_phase_inout != 0xFF) {
      uint8_t phase = NVME_CQE_STATUS_PHASE(cqeNew.status);
      if (phase == *expected_phase_inout) {
        // Phase matches expected - controller has written new completion
        // Now check CID if provided
        if (expected_cid != 0) {
          if (cqeNew.command_id == expected_cid) {
            // CID matches and phase matches - this is our completion
            if (sq_head_out != nullptr) {
              *sq_head_out = sq_head;
            }
            if (cqe_advanced_out != nullptr) {
              *cqe_advanced_out = false;
            }
            // Update expected phase for next completion
            // Phase flips only when controller wraps CQ (from entry N-1 to 0), not
            // per completion. All entries in same loop have same phase.
            if (cq_head_inout != nullptr && queue_size > 0) {
              uint16_t next_cq_head = (*cq_head_inout + 1) % queue_size;
              if (next_cq_head == 0) {
                // cq_head will wrap - phase flips on next loop
                *expected_phase_inout = phase ^ 1;
              } else {
                // Same loop - phase stays the same
                *expected_phase_inout = phase;
              }
            } else {
              // Fallback: keep same phase if we can't check wrap
              *expected_phase_inout = phase;
            }
            return cqeNew;
          }
          // Phase matches but CID doesn't - continue polling
          iteration_count = 0; // Reset on progress
#ifdef __HIP_DEVICE_COMPILE__
          last_progress_time = wall_clock64();
#endif
          continue;
        } else {
          // Phase matches but no CID check - return it
          if (sq_head_out != nullptr) {
            *sq_head_out = sq_head;
          }
          if (cqe_advanced_out != nullptr) {
            *cqe_advanced_out = false;
          }
          // Update expected phase for next completion
          // Phase flips only when controller wraps CQ (from entry N-1 to 0), not
          // per completion. All entries in same loop have same phase.
          if (cq_head_inout != nullptr && queue_size > 0) {
            uint16_t next_cq_head = (*cq_head_inout + 1) % queue_size;
            if (next_cq_head == 0) {
              // cq_head will wrap - phase flips on next loop
              *expected_phase_inout = phase ^ 1;
            } else {
              // Same loop - phase stays the same
              *expected_phase_inout = phase;
            }
          } else {
            // Fallback: keep same phase if we can't check wrap
            *expected_phase_inout = phase;
          }
          return cqeNew;
        }
      }
      // Phase doesn't match - but check if sq_head progressed anyway
      // (controller might update sq_head before phase, or phase might be stale)
      if (sq_head != effective_last_sq_head) {
        // sq_head changed - check if it's a valid progression
        if (sq_head > effective_last_sq_head ||
            (sq_head < effective_last_sq_head && queue_size > 0 &&
             (effective_last_sq_head - sq_head) < queue_size)) {
          // sq_head progressed - this is a real completion, accept it
          // (even if phase doesn't match - phase might be stale or updating)
          if (expected_cid != 0 && cqeNew.command_id == expected_cid) {
            // CID matches - this is our completion
            if (sq_head_out != nullptr) {
              *sq_head_out = sq_head;
            }
            if (cqe_advanced_out != nullptr) {
              *cqe_advanced_out = false;
            }
            // Update expected phase from actual completion
            if (expected_phase_inout != nullptr) {
              uint8_t phase = NVME_CQE_STATUS_PHASE(cqeNew.status);
              if (cq_head_inout != nullptr && queue_size > 0) {
                uint16_t next_cq_head = (*cq_head_inout + 1) % queue_size;
                if (next_cq_head == 0) {
                  *expected_phase_inout = phase ^ 1;
                } else {
                  *expected_phase_inout = phase;
                }
              } else {
                *expected_phase_inout = phase;
              }
            }
            return cqeNew;
          }
          // CID doesn't match but sq_head progressed - might be a different
          // completion, continue polling
          iteration_count = 0;
#ifdef __HIP_DEVICE_COMPILE__
          last_progress_time = wall_clock64();
#endif
          continue;
        }
      }
      // Phase doesn't match and sq_head hasn't progressed - stale completion,
      // continue polling
      iteration_count = 0; // Reset on progress
#ifdef __HIP_DEVICE_COMPILE__
      last_progress_time = wall_clock64();
#endif
      continue;
    }

    // Secondary check: command ID change (for backward compatibility)
    // Only used if sq_head hasn't progressed and phase check not enabled
    if (expected_cid == 0 && cqeNew.command_id != cqeLast.command_id) {
      if (sq_head_out != nullptr) {
        *sq_head_out = sq_head;
      }
      if (cqe_advanced_out != nullptr) {
        *cqe_advanced_out = false;
      }
      return cqeNew;
    }
  }
}

// Generate a completion entry from a submission entry
// This simulates NVMe controller behavior for testing
__host__ __device__ cqeType cqeGenFromSqe(const sqeType* sqeData) {
  cqeType result = {}; // Zero initialize

  // Set command ID to match the SQE
  result.command_id = sqeData->command_id;

  // Set result based on command type (simulated behavior)
  switch (sqeData->opcode) {
    case nvme_cmd_read:
    case nvme_cmd_write:
      // For read/write, result could be number of blocks transferred
      result.result = sqeData->cdw12 + 1; // NLB is 0-based
      break;
    case nvme_cmd_flush:
      result.result = 0;
      break;
    default:
      result.result = 0;
      break;
  }

  // Set status to success (Phase=1, SC=0, SCT=0)
  result.status = NVME_STATUS_MAKE(1, NVME_SC_SUCCESS, NVME_SCT_GENERIC);

  // Set SQ head/ID (for testing, just mirror command ID)
  result.sq_head = sqeData->command_id;
  result.sq_id = 0;

  return result;
}

// Use HIP's built-in wall_clock64() function directly - no wrapper needed

// Ring NVMe doorbell - use common implementation
__host__ __device__ void ringDoorbell(
  uint16_t sq_tail, uint32_t doorbell_offset, bool usePciMmioBridge,
  void* shadowBufferVirt, uint16_t nvmeTargetBdf, void* nvmeBar0Gpu) {
  xio_mmio_bridge::ringDoorbell(sq_tail, doorbell_offset, usePciMmioBridge,
                                 shadowBufferVirt, nvmeTargetBdf,
                                 nvmeBar0Gpu);
}

/**
 * Ring NVMe CQ head doorbell to notify controller that CQEs have been
 * consumed. This is critical - without updating CQ head doorbell, the
 * controller will run out of CQ slots and stall.
 */
__host__ __device__ void ringCqHeadDoorbell(
  uint16_t cq_head, uint32_t cq_doorbell_offset, bool usePciMmioBridge,
  void* shadowBufferVirt, uint16_t nvmeTargetBdf, void* nvmeBar0Gpu) {
  xio_mmio_bridge::ringCqHeadDoorbell(cq_head, cq_doorbell_offset,
                                       usePciMmioBridge, shadowBufferVirt,
                                       nvmeTargetBdf, nvmeBar0Gpu);
}

//
// Helper functions for command construction
//

/**
 * Calculate LBA for an operation
 */
__device__ uint64_t calculate_lba(unsigned i, uint16_t cmd_id,
                                   uint64_t base_lba, uint32_t blocks,
                                   uint64_t lba_range_lbas,
                                   bool use_random_access) {
  if (use_random_access && lba_range_lbas > 0) {
    uint64_t seed = (uint64_t)i * 0x9e3779b9 + cmd_id * 0x85ebca6b;
    seed ^= seed >> 16;
    seed *= 0xc2b2ae35;
    seed ^= seed >> 13;
    seed *= 0x9e3779b9;
    seed ^= seed >> 16;
    return base_lba + (seed % lba_range_lbas);
  } else {
    if (lba_range_lbas > 0) {
      return base_lba + ((i * blocks) % lba_range_lbas);
    } else {
      return base_lba + (i * blocks);
    }
  }
}

/**
 * Determine command type (read or write) for an operation
 */
__device__ bool determine_command_type(unsigned i, bool write_only_mode,
                                       bool read_only_mode,
                                       bool alternate_mode) {
  if (write_only_mode) {
    return false; // Write
  } else if (read_only_mode) {
    return true; // Read
  } else if (alternate_mode) {
    return (i % 2 == 0); // Alternate
  } else {
    return (i % 2 == 0); // Default to alternate
  }
}

/**
 * Calculate PRPs for a command
 * Handles both sequential mode (reuse buffer) and batch mode (per-operation
 * buffer)
 */
__device__ void calculate_prps_for_command(
  unsigned i, bool is_read_command, bool sequential_mode,
  bool has_read_buffer, bool has_write_buffer, bool read_only_mode,
  bool write_only_mode, bool alternate_mode, size_t transfer_size,
  size_t bufferSize, uint8_t* readBuffer, uint8_t* writeBuffer,
  uint64_t readBufferDma, uint64_t writeBufferDma, uint64_t* prp1,
  uint64_t* prp2) {
  if (is_read_command && has_read_buffer) {
    uint64_t buffer_offset;
    if (sequential_mode) {
      // Sequential mode: reuse same buffer
      buffer_offset = 0;
    } else {
      // Batch mode: per-operation buffer
      buffer_offset = read_only_mode ? (i * transfer_size)
                                     : ((i / 2) * transfer_size);
    }
    if (buffer_offset + transfer_size <= bufferSize) {
      uint64_t buffer_addr = readBufferDma
                                ? (readBufferDma + buffer_offset)
                                : (uint64_t)(readBuffer + buffer_offset);
      nvme_ep::nvme_calculate_prps(buffer_addr, transfer_size, prp1, prp2);
    } else {
      *prp1 = NVME_EP_INVALID_PRP1;
      *prp2 = NVME_EP_INVALID_PRP2;
    }
  } else if (!is_read_command && has_write_buffer) {
    uint64_t buffer_offset;
    if (sequential_mode) {
      // Sequential mode: per-operation buffer
      buffer_offset = i * transfer_size;
    } else {
      // Batch mode: per-operation buffer
      buffer_offset = write_only_mode ? (i * transfer_size)
                                      : ((i / 2) * transfer_size);
    }
    if (buffer_offset + transfer_size <= bufferSize) {
      uint64_t buffer_addr = writeBufferDma
                                ? (writeBufferDma + buffer_offset)
                                : (uint64_t)(writeBuffer + buffer_offset);
      nvme_ep::nvme_calculate_prps(buffer_addr, transfer_size, prp1, prp2);
    } else {
      *prp1 = NVME_EP_INVALID_PRP1;
      *prp2 = NVME_EP_INVALID_PRP2;
    }
  } else {
    *prp1 = NVME_EP_INVALID_PRP1;
    *prp2 = NVME_EP_INVALID_PRP2;
  }
}

/**
 * Setup and write SQE for a command
 */
__device__ void setup_and_write_sqe(
  struct nvme_sqe* sqeAddr, uint16_t sq_tail, bool is_write, uint16_t cmd_id,
  uint32_t nsid, uint64_t lba, uint32_t blocks, uint64_t prp1, uint64_t prp2,
  unsigned operation_index, const XioEndpointConfig& config, int verbose) {
  nvme_ep::sqeType sqeLocal = {};
  struct nvme_sqe* sqe = &sqeLocal;
  nvme_ep::nvme_sqe_setup_rw(sqe, is_write, cmd_id, nsid, lba, blocks, prp1,
                             prp2);

  // Record start time
  if (config.startTimes != nullptr) {
    config.startTimes[operation_index] = wall_clock64();
  }

  // Write SQE
  nvme_ep::sqeWrite(sqeLocal, &sqeAddr[sq_tail]);
  __threadfence_system();

  // Dump SQE information if very verbose
  if (verbose >= 2) {
    printf("[SQE] cmd_id=%u opcode=0x%02x nsid=%u lba=%llu blocks=%u "
           "prp1=0x%016llx prp2=0x%016llx sq_tail=%u\n",
           cmd_id, sqe->opcode, nsid, (unsigned long long)lba, blocks,
           (unsigned long long)prp1, (unsigned long long)prp2, sq_tail);
  }
}

} // namespace nvme_ep

//
// Batch mode helper: poll for a specific CID
//

// Helper: Read CQE entry
__device__ inline nvme_ep::cqeType nvme_ep_read_cqe(
  volatile struct nvme_cqe* cqe_ptr) {
  return nvme_ep::cqeRead((volatile nvme_ep::cqeType*)cqe_ptr);
}

//
// Batch mode helper: poll for a specific CID (last command in batch)
// Scans CQ entries forward from cq_head until target_cid is found
// Returns number of completions processed
//
__device__ uint16_t nvme_ep_batch_poll_for_cid(
  const XioEndpointConfig& config, struct nvme_cqe* cqeAddr,
  bool usePciMmioBridge, void* shadowBufferVirt, uint16_t nvmeTargetBdf,
  uint32_t cq_doorbell_offset, void* nvmeBar0Gpu, int verbose,
  unsigned num_ops, uint16_t queue_size, uint16_t* completed_count_inout,
  uint16_t* cq_head_inout, uint16_t target_cid) {
  uint16_t& completed_count = *completed_count_inout;
  uint16_t& cq_head = *cq_head_inout;

  if (completed_count >= num_ops || cqeAddr == nullptr) {
    return 0;
  }
  
  if (queue_size == 0) {
    return 0;
  }

  uint32_t poll_count = 0;
  const uint32_t max_polls = 10000000;
  uint16_t processed_count = 0;
  uint16_t start_cq_head = cq_head;
  uint16_t batch_first_cid = completed_count + 1;
  
  // Validate target_cid
  if (target_cid < batch_first_cid || target_cid > num_ops) {
    if (verbose >= 1) {
      printf("[POLL] Invalid target_cid %u (expected %u-%u)\n",
             target_cid, batch_first_cid, num_ops);
    }
    return 0;
  }
  
  uint16_t batch_size = target_cid - batch_first_cid + 1;
  
  // Validate batch_size
  if (batch_size == 0 || batch_size > queue_size) {
    if (verbose >= 1) {
      printf("[POLL] Invalid batch_size %u (queue_size=%u)\n",
             batch_size, queue_size);
    }
    return 0;
  }

  if (verbose >= 2) {
    printf("[POLL] Polling for CID %u (batch CIDs %u-%u), starting at slot %u\n",
           target_cid, batch_first_cid, target_cid, cq_head);
  }

  // Scan forward through CQ entries looking for target_cid
  // NVMe guarantees in-order completion, so once we find target_cid,
  // all previous CIDs in the batch have also completed
  while (poll_count < max_polls && processed_count == 0) {
    poll_count++;

    // Check current slot
    volatile struct nvme_cqe* cqe_entry = &cqeAddr[cq_head];
    nvme_ep::cqeType cqe_new = nvme_ep_read_cqe(cqe_entry);

    if (verbose >= 2 && poll_count % 10000 == 0) {
      printf("[POLL] slot=%u cmd_id=%u target_cid=%u completed=%u\n",
             cq_head, cqe_new.command_id, target_cid, completed_count);
    }

    // If we found the target CID, process all completions in the batch
    if (cqe_new.command_id == target_cid && cqe_new.command_id != 0) {
      // Found target CID - since NVMe guarantees in-order completion,
      // scan backwards from found slot to locate batch_first_cid
      uint16_t found_slot = cq_head;
      uint16_t batch_start_slot = found_slot;
      
      // Scan backwards to find where batch_first_cid actually is
      // This handles CQ wraps correctly
      for (uint16_t scan_back = 0; scan_back < batch_size && scan_back < queue_size; scan_back++) {
        uint16_t check_slot = (found_slot - scan_back + queue_size) % queue_size;
        volatile struct nvme_cqe* cqe_check = &cqeAddr[check_slot];
        nvme_ep::cqeType cqe_check_val = nvme_ep_read_cqe(cqe_check);
        
        if (cqe_check_val.command_id == batch_first_cid && 
            cqe_check_val.command_id != 0) {
          batch_start_slot = check_slot;
          break;
        }
      }

      // Process all completions in this batch (forward from batch_start_slot)
      // Since NVMe guarantees in-order completion, when we find target_cid,
      // all completions from batch_first_cid to target_cid are present
      // Assign the same finish time to all completions in the batch
      uint64_t end_time = wall_clock64();
      uint16_t current_slot = batch_start_slot;
      
      // Record end time for all CIDs in the batch
      for (uint16_t expected_cid = batch_first_cid; 
           expected_cid <= target_cid; expected_cid++) {
        // Record end time for this CID (same time for all in batch)
        uint16_t op_idx = expected_cid - 1;
        if (config.endTimes != nullptr && op_idx < num_ops) {
          config.endTimes[op_idx] = end_time;
        }

        // Read and log CQE if verbose
        if (verbose >= 2) {
          volatile struct nvme_cqe* cqe = &cqeAddr[current_slot];
          nvme_ep::cqeType cqe_val = nvme_ep_read_cqe(cqe);
          
          if (cqe_val.command_id == expected_cid && cqe_val.command_id != 0) {
            uint8_t sc = NVME_CQE_STATUS_SC(cqe_val.status);
            uint8_t sct = NVME_CQE_STATUS_SCT(cqe_val.status);
            printf("[CQE] slot=%u cmd_id=%u status=0x%04x (SCT=%u SC=0x%02x)\n",
                   current_slot, cqe_val.command_id, cqe_val.status, sct, sc);
          }
        }

        current_slot = (current_slot + 1) % queue_size;
      }
      
      // All completions in batch have been processed
      processed_count = batch_size;

      // Advance cq_head past the last completion (target_cid)
      cq_head = (found_slot + 1) % queue_size;
      completed_count += processed_count;

      // Update CQ doorbell
      nvme_ep::ringCqHeadDoorbell(cq_head, cq_doorbell_offset, usePciMmioBridge,
                                   shadowBufferVirt, nvmeTargetBdf, nvmeBar0Gpu);

      if (verbose >= 2) {
        printf("[POLL] Found target CID %u at slot %u, processed %u completions\n",
               target_cid, found_slot, processed_count);
      }
      break;
    }

    // Advance to next slot
    cq_head = (cq_head + 1) % queue_size;
    
    // If we've wrapped around without finding it, reset and keep polling
    if (cq_head == start_cq_head && poll_count > queue_size) {
      // Wrapped around - target not ready yet, keep polling from start
      if (verbose >= 2 && poll_count % 100000 == 0) {
        printf("[POLL] Wrapped around, still waiting for CID %u\n", target_cid);
      }
    }
  }

  return processed_count;
}

//
// Batch mode helper: submit a batch of commands
// Returns number of commands submitted
//
__device__ uint16_t nvme_ep_batch_submit_commands(
  const XioEndpointConfig& config, struct nvme_sqe* sqeAddr,
  struct nvme_cqe* cqeAddr, uint32_t lbaSize, uint64_t base_lba,
  bool usePciMmioBridge, void* shadowBufferVirt, uint16_t nvmeTargetBdf,
  uint32_t doorbell_offset, uint8_t* readBuffer, uint8_t* writeBuffer,
  size_t bufferSize, uint64_t readBufferDma, uint64_t writeBufferDma,
  uint16_t queue_size, uint64_t lba_range_lbas, bool use_random_access,
  void* nvmeBar0Gpu, int verbose, unsigned num_ops,
  bool has_read_buffer, bool has_write_buffer, bool read_only_mode,
  bool write_only_mode, bool alternate_mode, size_t transfer_size,
  uint32_t nsid, uint32_t blocks, uint16_t* sq_tail_inout,
  uint16_t batch_size, uint16_t submitted_count) {
  uint16_t& sq_tail = *sq_tail_inout;

  // Calculate actual batch size (don't exceed remaining operations)
  uint16_t remaining_to_submit = num_ops - submitted_count;
  uint16_t actual_batch_size =
    (remaining_to_submit < batch_size) ? remaining_to_submit : batch_size;

  if (verbose >= 2) {
    printf("[BATCH] submitting=%u batch_size=%u remaining=%u sq_tail=%u\n",
           submitted_count, actual_batch_size, remaining_to_submit, sq_tail);
  }

  // Issue commands for this batch
  for (uint16_t batch_i = 0; batch_i < actual_batch_size; batch_i++) {
    unsigned i = submitted_count + batch_i;
    uint16_t cmd_id = (uint16_t)(i + 1);

    uint64_t lba = nvme_ep::calculate_lba(i, cmd_id, base_lba, blocks,
                                          lba_range_lbas, use_random_access);
    bool is_read_command = nvme_ep::determine_command_type(
      i, write_only_mode, read_only_mode, alternate_mode);
    bool is_write = !is_read_command;

    uint64_t prp1, prp2;
    nvme_ep::calculate_prps_for_command(
      i, is_read_command, false, has_read_buffer, has_write_buffer,
      read_only_mode, write_only_mode, alternate_mode, transfer_size,
      bufferSize, readBuffer, writeBuffer, readBufferDma, writeBufferDma,
      &prp1, &prp2);

    nvme_ep::setup_and_write_sqe(sqeAddr, sq_tail, is_write, cmd_id, nsid, lba,
                                  blocks, prp1, prp2, i, config, verbose);

    sq_tail = (sq_tail + 1) % queue_size;
  }

  // Ring doorbell if we wrote commands
  if (actual_batch_size > 0) {
    __threadfence_system();
    nvme_ep::ringDoorbell(sq_tail, doorbell_offset, usePciMmioBridge,
                          shadowBufferVirt, nvmeTargetBdf, nvmeBar0Gpu);
  }

  return actual_batch_size;
}

//
// Sequential mode implementation
//
__device__ void nvme_ep_sequential_mode(
  const XioEndpointConfig& config, struct nvme_sqe* sqeAddr,
  struct nvme_cqe* cqeAddr, uint32_t lbaSize, uint64_t base_lba,
  bool usePciMmioBridge, void* shadowBufferVirt, uint16_t nvmeTargetBdf,
  uint16_t queueId, uint32_t doorbell_offset, uint8_t* readBuffer,
  uint8_t* writeBuffer, size_t bufferSize, uint64_t readBufferDma,
  uint64_t writeBufferDma, uint32_t lfsrSeed, uint16_t queue_size,
  uint64_t lba_range_lbas, bool use_random_access, void* nvmeBar0Gpu,
  int verbose, unsigned num_ops, bool sequential_is_read,
  bool has_read_buffer, bool has_write_buffer, bool read_only_mode,
  bool write_only_mode, bool alternate_mode, size_t transfer_size,
  uint32_t nsid, uint32_t blocks, uint32_t cq_doorbell_offset) {
  // Track submission queue tail
  uint16_t sq_tail = 0;
  uint16_t last_sq_head = 0;
  uint16_t cq_head = 0;
  uint8_t expected_phase = 0xFF;

  // Sequential mode: issue one SQE, wait for completion, repeat
  for (unsigned i = 0; i < num_ops; i++) {
    uint16_t cmd_id = (uint16_t)(i + 1);

    // Calculate LBA using helper function
    uint64_t lba = nvme_ep::calculate_lba(i, cmd_id, base_lba, blocks,
                                           lba_range_lbas, use_random_access);

    // Calculate PRPs using helper function
    uint64_t prp1, prp2;
    nvme_ep::calculate_prps_for_command(
      i, sequential_is_read, true, // sequential_mode = true
      has_read_buffer, has_write_buffer, read_only_mode, write_only_mode,
      alternate_mode, transfer_size, bufferSize, readBuffer, writeBuffer,
      readBufferDma, writeBufferDma, &prp1, &prp2);

    // Setup and write SQE using helper function
    nvme_ep::setup_and_write_sqe(sqeAddr, sq_tail, !sequential_is_read, cmd_id,
                                  nsid, lba, blocks, prp1, prp2, i, config,
                                  verbose);

    // Ring doorbell
    nvme_ep::ringDoorbell(sq_tail, doorbell_offset, usePciMmioBridge,
                          shadowBufferVirt, nvmeTargetBdf, nvmeBar0Gpu);

    // Increment tail after ringing doorbell
    sq_tail = (sq_tail + 1) % queue_size;

    // Wait for completion
    uint32_t poll_count = 0;
    const uint32_t max_polls = 10000000;
    nvme_ep::cqeType cqe_last = {};
    bool cqe_advanced = false;

    while (poll_count < max_polls) {
      volatile struct nvme_cqe* cqe_entry = &cqeAddr[cq_head];
      uint16_t new_sq_head = 0;

      nvme_ep::cqeType cqe_new = nvme_ep::cqePoll(
        cqe_last, (volatile nvme_ep::cqeType*)cqe_entry, last_sq_head,
        &new_sq_head, cmd_id, queue_size, &cq_head, &cqe_advanced,
        &expected_phase);

      if (cqe_advanced) {
        nvme_ep::ringCqHeadDoorbell(cq_head, cq_doorbell_offset,
                                     usePciMmioBridge, shadowBufferVirt,
                                     nvmeTargetBdf, nvmeBar0Gpu);
        last_sq_head = new_sq_head;
        poll_count = 0;
        continue;
      }

      uint8_t phase = NVME_CQE_STATUS_PHASE(cqe_new.status);
      uint8_t sc = NVME_CQE_STATUS_SC(cqe_new.status);
      uint8_t sct = NVME_CQE_STATUS_SCT(cqe_new.status);
      bool phase_matches =
        (expected_phase == 0xFF) || (phase == expected_phase);
      if (phase_matches || new_sq_head > last_sq_head) {
        if (verbose >= 2) {
          printf("[CQE] cmd_id=%u sq_head=%u status=0x%04x (SCT=%u SC=0x%02x) "
                 "phase=%u cq_head=%u\n",
                 cqe_new.command_id, new_sq_head, cqe_new.status, sct, sc,
                 phase, cq_head);
        }
        if (config.endTimes != nullptr && cmd_id >= 1 &&
            cmd_id <= num_ops) {
          unsigned idx = cmd_id - 1;
          config.endTimes[idx] = wall_clock64();
        }
        if (expected_phase == 0xFF) {
          uint16_t next_cq_head = (cq_head + 1) % queue_size;
          if (next_cq_head == 0) {
            expected_phase = phase ^ 1;
          } else {
            expected_phase = phase;
          }
        }
        cq_head = (cq_head + 1) % queue_size;
        nvme_ep::ringCqHeadDoorbell(cq_head, cq_doorbell_offset,
                                     usePciMmioBridge, shadowBufferVirt,
                                     nvmeTargetBdf, nvmeBar0Gpu);
        last_sq_head = new_sq_head;
        break;
      }

      poll_count++;
    }
  }
}

//
// Drive Endpoint (with data buffers) - Acts as NVMe host driver
//
// Merged driveEndpoint function - handles both batch and sequential modes
// Sequential mode: if writeIo < 0, issues one SQE at a time waiting for
// completion
//
// Helper: Calculate CQ head doorbell offset
__device__ inline uint32_t nvme_ep_calculate_cq_doorbell_offset(
  uint16_t queueId) {
  const uint32_t doorbell_stride = 0; // Usually 0 (4 bytes per doorbell)
  const uint32_t stride_bytes = 4 << doorbell_stride;
  const uint32_t doorbell_base = 0x1000;
  // SQ doorbell: doorbell_base + (2 * queueId) * stride_bytes (even)
  // CQ head doorbell: doorbell_base + (2 * queueId + 1) * stride_bytes (odd)
  return doorbell_base + (2 * queueId + 1) * stride_bytes;
}

// Helper: Determine operation mode and parameters
__device__ inline void nvme_ep_determine_mode(
  int readIo, int writeIo, unsigned config_iterations, bool* sequential_mode,
  unsigned* num_ops, bool* sequential_is_read) {
  *sequential_mode = (readIo < 0 || writeIo < 0);
  if (*sequential_mode) {
    if (readIo < 0) {
      *num_ops = -readIo;
      *sequential_is_read = true;
    } else {
      *num_ops = -writeIo;
      *sequential_is_read = false;
    }
  } else {
    *num_ops = config_iterations;
  }
}

// Helper: Determine buffer operation modes
__device__ inline void nvme_ep_determine_buffer_modes(
  uint8_t* readBuffer, uint8_t* writeBuffer, size_t bufferSize,
  bool* has_read_buffer, bool* has_write_buffer, bool* read_only_mode,
  bool* write_only_mode, bool* alternate_mode) {
  *has_write_buffer = (writeBuffer != nullptr && bufferSize > 0);
  *has_read_buffer = (readBuffer != nullptr && bufferSize > 0);
  *write_only_mode = *has_write_buffer && !*has_read_buffer;
  *read_only_mode = *has_read_buffer && !*has_write_buffer;
  *alternate_mode = *has_write_buffer && *has_read_buffer;
}

__device__ void nvme_ep_driveEndpoint(
  const XioEndpointConfig& config, struct nvme_sqe* sqeAddr,
  struct nvme_cqe* cqeAddr, uint32_t lbaSize, uint64_t base_lba,
  bool usePciMmioBridge, void* shadowBufferVirt, uint16_t nvmeTargetBdf,
  uint16_t queueId, uint32_t doorbell_offset, uint8_t* readBuffer,
  uint8_t* writeBuffer, size_t bufferSize, uint64_t readBufferDma,
  uint64_t writeBufferDma, uint32_t lfsrSeed, uint16_t queue_size,
  uint64_t lba_range_lbas, bool use_random_access, void* nvmeBar0Gpu,
  int verbose,
  int readIo, int writeIo, uint16_t batch_size) {
  // Validate inputs
  if (cqeAddr == nullptr) {
    return; // Cannot proceed without valid CQ pointer
  }

  // Calculate doorbell offsets
  const uint32_t cq_doorbell_offset = nvme_ep_calculate_cq_doorbell_offset(
    queueId);

  // Determine operation mode
  bool sequential_mode;
  unsigned num_ops;
  bool sequential_is_read;
  nvme_ep_determine_mode(readIo, writeIo, config.iterations, &sequential_mode,
                         &num_ops, &sequential_is_read);

  // Test parameters
  const uint32_t nsid = 1;   // Namespace ID
  const uint32_t blocks = 8; // Number of blocks per operation
  const size_t transfer_size = blocks * lbaSize;

  // Determine buffer operation modes
  bool has_write_buffer;
  bool has_read_buffer;
  bool read_only_mode;
  bool write_only_mode;
  bool alternate_mode;
  nvme_ep_determine_buffer_modes(readBuffer, writeBuffer, bufferSize,
                                  &has_read_buffer, &has_write_buffer,
                                  &read_only_mode, &write_only_mode,
                                  &alternate_mode);

  // Generate write data if needed
  if (has_write_buffer) {
    nvme_ep::nvme_generate_pattern(writeBuffer, bufferSize, 0, lbaSize,
                                   lfsrSeed);
  }

  // Calculate effective batch size (default: min(queue_size/2, 16))
  uint16_t effective_batch_size = batch_size;
  if (effective_batch_size == 0) {
    uint16_t half_queue = queue_size / 2;
    effective_batch_size = (half_queue < 16) ? half_queue : 16;
  }

  // Initialize queue state (for batch mode)
  uint16_t sq_tail = 0;
  uint16_t cq_head = 0;

  // Route to appropriate mode handler
  if (sequential_mode) {
    // Sequential mode: submit and wait for each command individually
    nvme_ep_sequential_mode(
      config, sqeAddr, cqeAddr, lbaSize, base_lba, usePciMmioBridge,
      shadowBufferVirt, nvmeTargetBdf, queueId, doorbell_offset, readBuffer,
      writeBuffer, bufferSize, readBufferDma, writeBufferDma, lfsrSeed,
      queue_size, lba_range_lbas, use_random_access, nvmeBar0Gpu, verbose,
      num_ops, sequential_is_read, has_read_buffer, has_write_buffer,
      read_only_mode, write_only_mode, alternate_mode, transfer_size, nsid,
      blocks, cq_doorbell_offset);
  } else {
    // Batch mode: submit commands in fixed-size batches and poll for last CID
    uint16_t completed_count = 0;
    uint16_t submitted_count = 0;
    uint16_t last_batch_last_cid = 0; // Track last CID of most recently submitted batch

    while (submitted_count < num_ops || completed_count < num_ops) {
      // Submit a batch of commands if needed
      if (submitted_count < num_ops) {
        uint16_t batch_count = nvme_ep_batch_submit_commands(
          config, sqeAddr, cqeAddr, lbaSize, base_lba, usePciMmioBridge,
          shadowBufferVirt, nvmeTargetBdf, doorbell_offset, readBuffer,
          writeBuffer, bufferSize, readBufferDma, writeBufferDma, queue_size,
          lba_range_lbas, use_random_access, nvmeBar0Gpu, verbose, num_ops,
          has_read_buffer, has_write_buffer, read_only_mode, write_only_mode,
          alternate_mode, transfer_size, nsid, blocks, &sq_tail,
          effective_batch_size, submitted_count);
        submitted_count += batch_count;
        // Last CID of the batch we just submitted (CIDs are 1-indexed)
        last_batch_last_cid = submitted_count;
      }

      // Poll for completions if needed
      if (completed_count < submitted_count && last_batch_last_cid > 0) {
        // Poll until we see the last CID of the most recently submitted batch
        uint16_t processed = nvme_ep_batch_poll_for_cid(
          config, cqeAddr, usePciMmioBridge, shadowBufferVirt, nvmeTargetBdf,
          cq_doorbell_offset, nvmeBar0Gpu, verbose, num_ops, queue_size,
          &completed_count, &cq_head, last_batch_last_cid);
        
        // If we didn't process any completions, we're still waiting
        // Continue the loop to check if we can submit more or need to keep polling
      }
    }
  }
}

// Wrapper kernel to launch nvme_ep_driveEndpoint
// Follows test-ep pattern: extract values on host, pass as parameters
__global__ void nvme_ep_kernel(
  struct nvme_sqe* sqeAddr, struct nvme_cqe* cqeAddr,
  unsigned long long int* startTimes, unsigned long long int* endTimes,
  unsigned iterations, unsigned numThreads, uint32_t lbaSize, uint64_t base_lba,
  bool usePciMmioBridge, void* shadowBufferVirt, uint16_t nvmeTargetBdf,
  uint16_t queueId, uint32_t doorbell_offset, uint8_t* readBuffer,
  uint8_t* writeBuffer, size_t bufferSize, uint64_t readBufferDma,
  uint64_t writeBufferDma, uint32_t lfsrSeed, uint16_t queue_size,
  uint64_t lba_range_lbas, bool use_random_access, void* nvmeBar0Gpu,
  int readIo, int writeIo, uint16_t batch_size, int verbose) {
  // Reconstruct XioEndpointConfig from parameters
  XioEndpointConfig config;
  config.submissionQueue = sqeAddr;
  config.completionQueue = cqeAddr;
  config.startTimes = startTimes;
  config.endTimes = endTimes;
  config.iterations = iterations;
  config.numThreads = numThreads;
  config.endpointConfig = nullptr; // Don't use endpointConfig pointer

  // Validate pointers before use
  if (sqeAddr == nullptr || cqeAddr == nullptr) {
    return; // Invalid pointers - kernel cannot proceed
  }

  nvme_ep_driveEndpoint(config, sqeAddr, cqeAddr, lbaSize, base_lba,
                        usePciMmioBridge, shadowBufferVirt, nvmeTargetBdf,
                        queueId, doorbell_offset, readBuffer, writeBuffer,
                        bufferSize, readBufferDma, writeBufferDma, lfsrSeed,
                        queue_size, lba_range_lbas, use_random_access,
                        nvmeBar0Gpu, verbose, readIo, writeIo, batch_size);
}

// Host-side helper functions
#ifndef __HIP_DEVICE_COMPILE__

// Old PCI config reading functions removed - now using kernel module IOCTL
// PCI MMIO bridge shadow buffer mapping moved to xio-mmio-bridge.hip

// Map NVMe BAR0 for direct doorbell access
// Similar to test-gpu-nvme-write.cpp's map_nvme_bar0 function
__host__ int nvme_ep_map_bar0(uint16_t nvme_bdf, void** bar0_cpu,
                              void** bar0_gpu) {
  int bar0_fd = -1;
  int drm_fd = -1;
  void* mapped = MAP_FAILED;
  char resource_path[256];
  size_t bar0_size = 8192; // Map 8KB (enough for doorbell registers)
  hipError_t hip_err = hipSuccess;

  // Convert BDF to format: 00:BB:DD.F
  uint8_t bus = (nvme_bdf >> 8) & 0xFF;
  uint8_t dev = (nvme_bdf >> 3) & 0x1F;
  uint8_t func = nvme_bdf & 0x7;

  // Build resource0 path: /sys/bus/pci/devices/0000:BB:DD.F/resource0
  snprintf(resource_path, sizeof(resource_path),
           "/sys/bus/pci/devices/0000:%02x:%02x.%x/resource0", bus, dev, func);

  // Open BAR0 resource file
  bar0_fd = open(resource_path, O_RDWR);
  if (bar0_fd < 0) {
    fprintf(stderr, "Failed to open NVMe BAR0 resource %s: %s\n",
            resource_path, strerror(errno));
    return -errno;
  }

  // Map BAR0 to userspace
  mapped = mmap(nullptr, bar0_size, PROT_READ | PROT_WRITE, MAP_SHARED,
                bar0_fd, 0);
  if (mapped == MAP_FAILED) {
    fprintf(stderr, "Failed to mmap NVMe BAR0: %s\n", strerror(errno));
    close(bar0_fd);
    return -errno;
  }

  fprintf(stderr, "NVMe BAR0 mapped at %p (size=%zu)\n", mapped, bar0_size);

  // Register with DRM GEM_USERPTR (required for GPU access to PCI MMIO)
  drm_fd = open("/dev/dri/renderD128", O_RDWR);
  if (drm_fd < 0) {
    fprintf(stderr, "Warning: Failed to open DRM device: %s\n",
            strerror(errno));
    fprintf(stderr, "Cannot register BAR0 with GPU via GEM_USERPTR.\n");
    munmap(mapped, bar0_size);
    close(bar0_fd);
    return -errno;
  }

  struct drm_amdgpu_gem_userptr gem_userptr = {};
  gem_userptr.addr = (uint64_t)mapped;
  gem_userptr.size = bar0_size;
  gem_userptr.flags = AMDGPU_GEM_USERPTR_REGISTER;

  if (ioctl(drm_fd, DRM_IOCTL_AMDGPU_GEM_USERPTR, &gem_userptr) < 0) {
    fprintf(stderr,
            "Warning: DRM_IOCTL_AMDGPU_GEM_USERPTR failed for BAR0: %s\n",
            strerror(errno));
    fprintf(stderr, "Cannot register BAR0 with GPU.\n");
    close(drm_fd);
    munmap(mapped, bar0_size);
    close(bar0_fd);
    return -errno;
  }

  fprintf(stderr, "NVMe BAR0 registered with DRM GEM_USERPTR (handle: %u)\n",
          gem_userptr.handle);

  // Register with HIP
  hip_err = hipHostRegister(mapped, bar0_size, hipHostRegisterMapped);
  if (hip_err != hipSuccess) {
    fprintf(stderr, "Warning: Failed to register BAR0 with HIP: %s\n",
            hipGetErrorString(hip_err));
    close(drm_fd);
    munmap(mapped, bar0_size);
    close(bar0_fd);
    return -EINVAL;
  }

  fprintf(stderr, "NVMe BAR0 registered with HIP for GPU access\n");

  // Get GPU pointer
  void* gpu_ptr = nullptr;
  hipError_t gpu_ptr_err = hipHostGetDevicePointer(&gpu_ptr, mapped, 0);
  if (gpu_ptr_err != hipSuccess) {
    fprintf(stderr, "Warning: hipHostGetDevicePointer failed for BAR0: %s\n",
            hipGetErrorString(gpu_ptr_err));
    (void)hipHostUnregister(mapped);
    close(drm_fd);
    munmap(mapped, bar0_size);
    close(bar0_fd);
    return -EINVAL;
  }

  fprintf(stderr, "NVMe BAR0 GPU pointer obtained: %p (host: %p)\n", gpu_ptr,
          mapped);

  // Keep bar0_fd and drm_fd open for the mapping to remain valid
  // The kernel will clean them up when the process exits

  *bar0_cpu = mapped;
  *bar0_gpu = gpu_ptr;

  // Note: We keep bar0_fd and drm_fd open - the mappings persist even after
  // close The kernel will clean them up when the process exits

  return 0;
}

//
// Host helper function for NVMe queue creation via IOCTL
//

/**
 * Read NVMe Controller Capabilities (CAP) register from BAR0
 *
 * The CAP register is a 64-bit register at offset 0x00-0x07 in BAR0.
 * It contains controller capabilities including CQR (Contiguous Queues Required).
 *
 * @param nvme_bdf NVMe device BDF in 0xBBDD format
 * @param cap_out Output parameter for CAP register value
 * @return 0 on success, negative error code on failure
 */
__host__ int nvme_ep_read_cap_register(uint16_t nvme_bdf, uint64_t* cap_out) {
  int bar0_fd = -1;
  void* bar0_mapped = MAP_FAILED;
  char resource_path[256];
  size_t bar0_size = 8; // Only need 8 bytes for CAP register
  int ret = 0;

  if (!cap_out) {
    return -EINVAL;
  }

  // Convert BDF to format: 00:BB:DD.F
  uint8_t bus = (nvme_bdf >> 8) & 0xFF;
  uint8_t dev = (nvme_bdf >> 3) & 0x1F;
  uint8_t func = nvme_bdf & 0x7;

  // Build resource0 path: /sys/bus/pci/devices/0000:BB:DD.F/resource0
  snprintf(resource_path, sizeof(resource_path),
           "/sys/bus/pci/devices/0000:%02x:%02x.%x/resource0", bus, dev, func);

  // Open BAR0 resource file
  bar0_fd = open(resource_path, O_RDONLY);
  if (bar0_fd < 0) {
    fprintf(stderr, "Failed to open NVMe BAR0 resource %s: %s\n",
            resource_path, strerror(errno));
    return -errno;
  }

  // Map BAR0 to userspace (read-only for CAP register)
  bar0_mapped = mmap(nullptr, bar0_size, PROT_READ, MAP_SHARED, bar0_fd, 0);
  if (bar0_mapped == MAP_FAILED) {
    fprintf(stderr, "Failed to mmap NVMe BAR0: %s\n", strerror(errno));
    close(bar0_fd);
    return -errno;
  }

  // Read CAP register (64-bit at offset 0)
  *cap_out = *reinterpret_cast<volatile uint64_t*>(bar0_mapped);

  // Cleanup
  munmap(bar0_mapped, bar0_size);
  close(bar0_fd);

  return ret;
}

// Export HSA-allocated VRAM as DMA-BUF and register with kernel module
// Based on QEMU reference code: test-gpu-nvme-write.cpp
// Returns 0 on success, negative error code on failure
// is_emulated: true for emulated NVMe (returns GPU BAR GPA), false for
// passthrough (returns P2PDMA IOVA)
static int export_and_register_vram_buffer(void* vram_ptr, size_t size,
                                           uint16_t nvme_bdf,
                                           const char* kernel_module_device,
                                           uint64_t* phys_addr_out,
                                           bool is_emulated = false) {
  hsa_status_t status;
  hipDeviceptr_t aligned_ptr;
  const size_t host_page_size = sysconf(_SC_PAGESIZE);
  uint64_t dmabuf_offset = 0;
  size_t aligned_size;
  int dmabuf_fd = -1;
  int kmod_fd = -1;
  int ret = 0;

  if (!vram_ptr || !phys_addr_out || size == 0) {
    return -EINVAL;
  }

  // Round down to host page size for dmabuf alignment
  aligned_ptr = (hipDeviceptr_t)((uintptr_t)vram_ptr & ~(host_page_size - 1));
  dmabuf_offset = (uintptr_t)vram_ptr - (uintptr_t)aligned_ptr;
  aligned_size = (size + dmabuf_offset + host_page_size - 1) &
                 ~(host_page_size - 1);

  fprintf(stderr,
          "  Aligning VRAM buffer: ptr=%p -> aligned=%p, "
          "size=%zu -> %zu, offset=%llu\n",
          vram_ptr, (void*)aligned_ptr, size, aligned_size,
          (unsigned long long)dmabuf_offset);

  // Export as DMA-BUF using HSA runtime
  dmabuf_fd = 0;
  status = hsa_amd_portable_export_dmabuf((void*)aligned_ptr, aligned_size,
                                          &dmabuf_fd, &dmabuf_offset);
  if (status != HSA_STATUS_SUCCESS) {
    fprintf(stderr,
            "ERROR: hsa_amd_portable_export_dmabuf failed (status=%d)\n",
            status);
    fprintf(stderr, "  This requires:\n");
    fprintf(stderr, "  - ROCm 5.3+ with dmabuf support\n");
    fprintf(stderr, "  - Kernel CONFIG_DMABUF_MOVE_NOTIFY=y\n");
    fprintf(stderr, "  - Kernel CONFIG_PCI_P2PDMA=y\n");
    return -ENOTSUP;
  }

  fprintf(stderr, "  ✅ Exported dmabuf: fd=%d, offset=0x%llx\n", dmabuf_fd,
          (unsigned long long)dmabuf_offset);

  // Open kernel module device
  kmod_fd = open(kernel_module_device, O_RDWR);
  if (kmod_fd < 0) {
    fprintf(stderr, "ERROR: Failed to open %s: %s\n", kernel_module_device,
            strerror(errno));
    close(dmabuf_fd);
    return -errno;
  }

  // Register buffer with kernel module to get physical address
  rocm_axiio_register_buffer_req req = {};
  req.dmabuf_fd = dmabuf_fd;
  req.virt_addr = reinterpret_cast<uint64_t>(vram_ptr);
  req.size = size;
  req.nvme_bdf = nvme_bdf;
  req.flags = is_emulated ? ROCM_XIO_FLAG_EMULATED
                           : ROCM_XIO_FLAG_PASSTHROUGH;

  ret = ioctl(kmod_fd, ROCM_XIO_REGISTER_BUFFER, &req);
  if (ret < 0) {
    fprintf(stderr, "ERROR: ROCM_XIO_REGISTER_BUFFER ioctl failed: %s\n",
            strerror(errno));
    close(dmabuf_fd);
    close(kmod_fd);
    return -errno;
  }

  // Physical address includes the offset within the dmabuf
  *phys_addr_out = req.phys_addr + dmabuf_offset;

  fprintf(stderr,
          "  ✅ Registered buffer: virt=0x%016llx, phys=0x%016llx, "
          "size=%zu\n",
          (unsigned long long)req.virt_addr, (unsigned long long)*phys_addr_out,
          size);

  // Close dmabuf FD - kernel module has the mapping
  close(dmabuf_fd);
  close(kmod_fd);

  return 0;
}

// Physical address translation is now provided by xioGetPhysAddr() from xio.h

// Forward declarations
// Forward declaration removed - using common function from xio-mmio-bridge.hip

// Run endpoint test - launches GPU kernel and waits for completion
__host__ hipError_t nvme_ep_run(XioEndpointConfig* config) {
  if (!config) {
    return hipErrorInvalidValue;
  }

  // HIP initialization: Ensure HIP is initialized (important when running under
  // sudo) Check if HIP is already initialized by trying to get device count
  int device_count = 0;
  hipError_t count_err = hipGetDeviceCount(&device_count);
  if (count_err != hipSuccess || device_count == 0) {
    // HIP not initialized or no devices - try to initialize
    hipError_t hip_init_err = hipInit(0);
    if (hip_init_err != hipSuccess) {
      fprintf(stderr,
              "Warning: hipInit returned: %s (code: %d), continuing anyway\n",
              hipGetErrorString(hip_init_err), hip_init_err);
    }
    // Set device to 0 after initialization
    hipError_t hip_dev_err = hipSetDevice(0);
    if (hip_dev_err != hipSuccess) {
      fprintf(stderr, "Error: Failed to set HIP device 0: %s (code: %d)\n",
              hipGetErrorString(hip_dev_err), hip_dev_err);
      return hip_dev_err;
    }
  } else {
    // HIP is already initialized - verify device is set correctly
    int current_device = -1;
    hipError_t get_dev_err = hipGetDevice(&current_device);
    if (get_dev_err == hipSuccess && current_device != 0) {
      // Device is set but not 0 - set it to 0
      hipError_t set_dev_err = hipSetDevice(0);
      if (set_dev_err != hipSuccess) {
        fprintf(stderr,
                "Warning: Failed to set HIP device to 0: %s (code: %d)\n",
                hipGetErrorString(set_dev_err), set_dev_err);
      }
    }
  }

  // Get nvme-ep specific config (follows test-ep pattern)
  nvme_ep::NvmeEpConfig* nvmeConfig = nullptr;
  if (!config->endpointConfig) {
    fprintf(stderr, "Error: nvme-ep requires endpoint configuration\n");
    return hipErrorInvalidValue;
  }

  nvmeConfig = static_cast<nvme_ep::NvmeEpConfig*>(config->endpointConfig);

  // Queue creation is MANDATORY for nvme-ep - device must be specified
  if (nvmeConfig->device.empty()) {
    fprintf(stderr,
            "Error: NVMe device not specified. --controller is required.\n");
    return hipErrorInvalidValue;
  }

  // Create NVMe queues - MUST succeed before proceeding
  // NVMe queues are circular buffers - commands wrap around, so the queue
  // length must be large enough to handle outstanding commands without
  // overwriting unprocessed ones.
  uint16_t queue_size = nvmeConfig->queueLength;

  fprintf(stderr, "Using queue length: %u entries\n", queue_size);

  struct nvme_queue_info queue_info;
  int ret = nvme_ep::nvme_create_queue_via_ioctl(
    nvmeConfig->device.c_str(), ROCM_XIO_DEVICE_PATH, nvmeConfig->queueId,
    queue_size, nvmeConfig->nvmeTargetBdf,
    config->memoryMode, // Respect memory mode like test-ep
    &queue_info);

  // Warn if requested operations exceed what the queue can handle
  // max_outstanding = queue_size (can use all queue entries)
  // If num_ops > max_outstanding, we'll need multiple batches
  uint16_t max_outstanding = queue_size;
  uint16_t total_ops = config->iterations;
  if (total_ops > max_outstanding) {
    fprintf(stderr,
            "Note: Requested %u operations with queue size %u "
            "(max outstanding: %u)\n",
            total_ops, queue_size, max_outstanding);
    fprintf(stderr,
            "Operations will be submitted in batches of up to %u commands\n",
            max_outstanding);
  }

  if (ret < 0) {
    fprintf(stderr, "Error: Failed to create NVMe queues: %s\n",
            strerror(-ret));
    fprintf(stderr,
            "Queue creation failed - cannot proceed with kernel launch.\n");
    return hipErrorInvalidValue;
  }

  // Update config with created queue addresses
  // Use GPU pointers for kernel launch (obtained via hipHostGetDevicePointer)
  config->submissionQueue = queue_info.sq_gpu ? queue_info.sq_gpu
                                              : queue_info.sq_virt;
  config->completionQueue = queue_info.cq_gpu ? queue_info.cq_gpu
                                              : queue_info.cq_virt;
  nvmeConfig->sqBaseAddr = queue_info.sq_phys;
  nvmeConfig->cqBaseAddr = queue_info.cq_phys;
  nvmeConfig->sqSize = queue_info.sq_size;
  nvmeConfig->cqSize = queue_info.cq_size;

  fprintf(stderr, "NVMe queues created: SQ=0x%llx, CQ=0x%llx, queue_id=%u\n",
          (unsigned long long)queue_info.sq_phys,
          (unsigned long long)queue_info.cq_phys, nvmeConfig->queueId);
  fprintf(stderr, "Queue GPU pointers: SQ=%p (host=%p), CQ=%p (host=%p)\n",
          queue_info.sq_gpu, queue_info.sq_virt, queue_info.cq_gpu,
          queue_info.cq_virt);

  // Verify queues were created successfully
  if (!config->submissionQueue || !config->completionQueue) {
    fprintf(stderr,
            "Error: Queue creation succeeded but queue pointers are null\n");
    return hipErrorInvalidValue;
  }

  // Set up PCI MMIO bridge shadow buffer if enabled
  // Match QEMU guest code pattern: map QEMU's guest RAM shadow buffer via
  // kernel module QEMU allocates shadow buffer as guest RAM using
  // memory_region_init_ram(), which makes it accessible as regular guest
  // memory. We map it via kernel module mmap to get access to the same physical
  // memory that QEMU sees.
  if (nvmeConfig->usePciMmioBridge) {
    void* shadow_virt = nullptr;
    int ret_shadow = xio_mmio_bridge::map_shadow_buffer(
      nvmeConfig->mmioBridgeBdf,
                                                   &shadow_virt);
    if (ret_shadow < 0) {
      fprintf(stderr, "Failed to map PCI MMIO bridge shadow buffer\n");
      return hipErrorInvalidValue;
    }
    fprintf(stderr, "PCI MMIO bridge shadow buffer mapped at %p\n",
            shadow_virt);

    // Register shadow buffer for GPU access (matching QEMU guest code pattern)
    // Kernel module mmap maps QEMU's guest RAM, which is the same physical
    // memory that QEMU's address_space_read() sees.
    const size_t shadow_size = 8192; // 8KB shadow buffer (matches QEMU default)

    // Step 1: Register with DRM GEM_USERPTR (required for GPU access)
    // This matches the QEMU guest code pattern (test-gpu-nvme-write.cpp lines
    // 933-947)
    int drm_fd = open("/dev/dri/renderD128", O_RDWR);
    if (drm_fd < 0) {
      fprintf(stderr, "Warning: Failed to open DRM device: %s\n",
              strerror(errno));
      fprintf(stderr,
              "Cannot register shadow buffer with GPU via GEM_USERPTR.\n");
      fprintf(
        stderr,
        "Disabling PCI MMIO bridge mode - GPU kernel will skip doorbell.\n");
      munmap(shadow_virt, shadow_size);
      nvmeConfig->shadowBufferVirt = nullptr;
      nvmeConfig->usePciMmioBridge = false;
    } else {
      struct drm_amdgpu_gem_userptr gem_userptr = {};
      gem_userptr.addr = (uint64_t)shadow_virt;
      gem_userptr.size = shadow_size;
      gem_userptr.flags = AMDGPU_GEM_USERPTR_REGISTER;

      if (ioctl(drm_fd, DRM_IOCTL_AMDGPU_GEM_USERPTR, &gem_userptr) < 0) {
        fprintf(stderr, "Warning: DRM_IOCTL_AMDGPU_GEM_USERPTR failed: %s\n",
                strerror(errno));
        fprintf(stderr, "Cannot register shadow buffer with GPU.\n");
        fprintf(
          stderr,
          "Disabling PCI MMIO bridge mode - GPU kernel will skip doorbell.\n");
        close(drm_fd);
        munmap(shadow_virt, shadow_size);
        nvmeConfig->shadowBufferVirt = nullptr;
        nvmeConfig->shadowBufferCpu = nullptr;
        nvmeConfig->usePciMmioBridge = false;
      } else {
        fprintf(stderr,
                "Shadow buffer registered with DRM GEM_USERPTR "
                "(handle: %u)\n",
                gem_userptr.handle);

        // Step 2: Register with HIP (matching QEMU guest code pattern)
        hipError_t hip_err = hipHostRegister(shadow_virt, shadow_size,
                                             hipHostRegisterMapped);
        if (hip_err != hipSuccess) {
          fprintf(stderr,
                  "Warning: Failed to register shadow buffer with HIP: "
                  "%s\n",
                  hipGetErrorString(hip_err));
          fprintf(stderr, "Disabling PCI MMIO bridge mode - GPU kernel will "
                          "skip doorbell.\n");
          close(drm_fd);
          munmap(shadow_virt, shadow_size);
          nvmeConfig->shadowBufferVirt = nullptr;
          nvmeConfig->shadowBufferCpu = nullptr;
          nvmeConfig->usePciMmioBridge = false;
        } else {
          fprintf(stderr, "Shadow buffer registered with HIP for GPU access\n");

          // Step 3: Get GPU pointer (matching QEMU guest code pattern)
          // After hipHostRegister, we need hipHostGetDevicePointer to get the
          // GPU-accessible pointer
          void* shadow_gpu_ptr = nullptr;
          hipError_t gpu_ptr_err = hipHostGetDevicePointer(&shadow_gpu_ptr,
                                                           shadow_virt, 0);
          if (gpu_ptr_err != hipSuccess) {
            fprintf(stderr, "Warning: hipHostGetDevicePointer failed: %s\n",
                    hipGetErrorString(gpu_ptr_err));
            fprintf(stderr, "Disabling PCI MMIO bridge mode - GPU kernel will "
                            "skip doorbell.\n");
            close(drm_fd);
            munmap(shadow_virt, shadow_size);
            nvmeConfig->shadowBufferVirt = nullptr;
            nvmeConfig->usePciMmioBridge = false;
          } else {
            fprintf(stderr,
                    "Shadow buffer GPU pointer obtained: %p (host: %p)\n",
                    shadow_gpu_ptr, shadow_virt);
            // Store GPU pointer for kernel use and CPU pointer for cleanup
            nvmeConfig->shadowBufferVirt = shadow_gpu_ptr;
            nvmeConfig->shadowBufferCpu = shadow_virt;
          }
          // Note: We keep drm_fd open for the mapping to remain valid
          // In a production system, you might want to track this fd and close
          // it on cleanup
        }
      }
      // Keep drm_fd open - the mapping persists even after close
      // The kernel will clean it up when the process exits
      close(drm_fd);
    }
  } else {
    // PCI MMIO bridge is disabled - set up direct doorbell via BAR0
    void* bar0_cpu = nullptr;
    void* bar0_gpu = nullptr;
    int ret_bar0 = nvme_ep_map_bar0(nvmeConfig->nvmeTargetBdf, &bar0_cpu,
                                    &bar0_gpu);
    if (ret_bar0 < 0) {
      fprintf(stderr,
              "Warning: Failed to map NVMe BAR0 for direct doorbell: %s\n",
              strerror(-ret_bar0));
      fprintf(
        stderr,
        "Direct doorbell mode disabled - GPU kernel will skip doorbell.\n");
      nvmeConfig->nvmeBar0Gpu = nullptr;
      nvmeConfig->nvmeBar0Cpu = nullptr;
    } else {
      fprintf(stderr, "NVMe BAR0 mapped for direct doorbell access\n");
      nvmeConfig->nvmeBar0Gpu = bar0_gpu;
      nvmeConfig->nvmeBar0Cpu = bar0_cpu; // Store for cleanup
    }
  }

  // Extract values from endpointConfig (follows test-ep pattern)
  // This avoids passing host pointers to GPU kernel
  uint32_t lbaSize = 512;
  bool usePciMmioBridge = false;
  void* shadowBufferVirt = nullptr;
  void* nvmeBar0Gpu = nullptr;
  uint16_t nvmeTargetBdf = 0x0030; // Default: 00:06.0
  uint16_t queueId = 63;
  uint32_t lfsrSeed = 0;
  size_t dataBufferSize = 0;
  int readIo = 0;
  int writeIo = 0;

  uint64_t baseLba = 0;      // Default value
  uint64_t lbaRangeLbas = 0; // 0 means no range limit (use original behavior)
  bool useRandomAccess = false;
  uint16_t batchSize = 0;    // Default: auto-calculate
  if (nvmeConfig) {
    lbaSize = nvmeConfig->lbaSize;
    baseLba = nvmeConfig->baseLba;
    usePciMmioBridge = nvmeConfig->usePciMmioBridge;
    shadowBufferVirt = nvmeConfig->shadowBufferVirt;
    nvmeBar0Gpu = nvmeConfig->nvmeBar0Gpu;
    nvmeTargetBdf = nvmeConfig->nvmeTargetBdf;
    queueId = nvmeConfig->queueId;
    lfsrSeed = nvmeConfig->lfsrSeed;
    dataBufferSize = nvmeConfig->dataBufferSize;
    readIo = nvmeConfig->readIo;
    writeIo = nvmeConfig->writeIo;
    batchSize = nvmeConfig->batchSize;

    // Query namespace capacity in LBAs
    uint64_t namespace_capacity = 0;
    int capacity_ret = nvme_ep_query_namespace_capacity(
      nvmeConfig->device.c_str(), 1, &namespace_capacity);
    if (capacity_ret == 0 && namespace_capacity > 0) {
      lbaRangeLbas = namespace_capacity;
      fprintf(stderr, "Using full namespace capacity: %llu LBAs\n",
              (unsigned long long)lbaRangeLbas);
    } else {
      fprintf(stderr, "Warning: Failed to query namespace capacity, "
                      "LBA range will be unlimited\n");
      lbaRangeLbas = 0; // 0 means no limit
    }

    // Determine access pattern
    useRandomAccess = (nvmeConfig->accessPattern == "random");
  }

  // Calculate SQ doorbell offset on host side (matching
  // test-gpu-nvme-write.cpp) Doorbell base is at BAR0 + 0x1000 SQ doorbell
  // offset = 0x1000 + (2 * queue_id * doorbell_stride)
  const uint32_t doorbell_stride = 0; // Usually 0 (4 bytes per doorbell)
  const uint32_t stride_bytes = 4 << doorbell_stride;
  const uint32_t doorbell_base = 0x1000;
  const uint32_t doorbell_offset = doorbell_base + (2 * queueId) * stride_bytes;

  // Allocate data buffers if enabled and needed
  uint8_t* readBuffer = nullptr;
  uint8_t* writeBuffer = nullptr;
  uint8_t* readBufferGpu = nullptr;  // GPU-accessible pointer (may be same as
                                     // readBuffer)
  uint8_t* writeBufferGpu = nullptr; // GPU-accessible pointer (may be same as
                                     // writeBuffer)
  uint64_t readBufferDma = 0;
  uint64_t writeBufferDma = 0;
  bool dataBufferOnDevice = (config->memoryMode & 0x8) != 0; // Bit 3
  bool readBufferActuallyOnDevice = false;  // Track actual allocation type
  bool writeBufferActuallyOnDevice = false; // Track actual allocation type

  // Allocate data buffers if buffer size is specified and I/O is requested
  // Note: readIo and writeIo can be negative for sequential mode, so check != 0
  if (dataBufferSize > 0 && (readIo != 0 || writeIo != 0)) {
    // Allocate read buffer if read I/O is requested (including sequential mode)
    if (readIo != 0) {
      // Try device memory first if requested (matching test-gpu-nvme-write.cpp
      // pattern)
      if (dataBufferOnDevice) {
        // Use hipMalloc for VRAM allocation (matching test code line 792)
        hipError_t buf_err = hipMalloc(&readBuffer, dataBufferSize);
        if (buf_err != hipSuccess) {
          fprintf(stderr, "Error: hipMalloc failed for read buffer: %s\n",
                  hipGetErrorString(buf_err));
          return buf_err;
        }

        fprintf(stderr, "  VRAM buffer virtual: %p\n", readBuffer);
        fprintf(stderr, "  Exporting as DMA-BUF (HSA runtime)...\n");

        // Detect if NVMe is emulated (needed for buffer registration flags)
        bool is_emulated = false;
        (void)xioDetectEmulatedNvme(nvmeConfig->device.c_str(), &is_emulated);

        // Export VRAM as dmabuf and register with kernel module
        int ret = export_and_register_vram_buffer(readBuffer, dataBufferSize,
                                                  nvmeConfig->nvmeTargetBdf,
                                                  ROCM_XIO_DEVICE_PATH,
                                                  &readBufferDma, is_emulated);
        if (ret < 0) {
          fprintf(stderr,
                  "ERROR: DMA-BUF export failed for device memory: %s\n",
                  strerror(-ret));
          fprintf(stderr, "  Device memory was requested but dmabuf export is "
                          "not available\n");
          (void)hipFree(readBuffer);
          readBuffer = nullptr;
          return hipErrorInvalidValue;
        }

        fprintf(stderr, "  Data buffer physical: 0x%016llx (VRAM)\n",
                (unsigned long long)readBufferDma);
        fprintf(stderr, "  GPU writes directly to VRAM\n");
        fprintf(stderr, "  NVMe DMAs from VRAM (P2P)\n");

        // Device memory - GPU pointer is same as host pointer
        readBufferGpu = readBuffer;
        readBufferActuallyOnDevice = true; // Track that we're using device
                                           // memory
      } else {
        // Host memory - use hipHostMalloc (matching test code line 836)
        hipError_t buf_err = hipHostMalloc(&readBuffer, dataBufferSize,
                                           hipHostMallocMapped);
        if (buf_err != hipSuccess) {
          fprintf(stderr, "Error: hipHostMalloc failed for read buffer: %s\n",
                  hipGetErrorString(buf_err));
          return buf_err;
        }

        // Get physical address for host memory using /proc/self/pagemap
        readBufferDma = xioGetPhysAddr(readBuffer);
        if (!readBufferDma) {
          fprintf(stderr,
                  "ERROR: Failed to get read buffer physical address\n");
          (void)hipHostFree(readBuffer);
          readBuffer = nullptr;
          return hipErrorInvalidValue;
        }

        fprintf(stderr, "  Data buffer virtual:  %p\n", readBuffer);
        fprintf(stderr, "  Data buffer physical: 0x%016llx\n",
                (unsigned long long)readBufferDma);
        fprintf(stderr, "  GPU can write directly to this buffer\n");
        fprintf(stderr, "  NVMe can DMA from this buffer\n");
        readBufferActuallyOnDevice = false; // Track that we're using host
                                            // memory
      }

      // Read buffer registration:
      // - Device memory: Already registered via
      // export_and_register_vram_buffer()
      // - Host memory: Physical address obtained from pagemap via
      // xioGetPhysAddr(), kernel module will use virt_to_phys() fallback if
      // needed for PRP injection

      // Verify read buffer is GPU-accessible and get GPU pointer if needed
      // (matches QEMU guest code pattern - hipHostMallocMapped should be
      // GPU-accessible)
      if (!dataBufferOnDevice) {
        hipPointerAttribute_t attr;
        hipError_t attr_err = hipPointerGetAttributes(&attr, readBuffer);
        if (attr_err != hipSuccess) {
          fprintf(stderr,
                  "Warning: Read buffer may not be GPU-accessible: %s\n",
                  hipGetErrorString(attr_err));
          readBufferGpu = readBuffer; // Fallback to host pointer
        } else {
          fprintf(
            stderr,
            "Read buffer GPU accessibility verified: type=%d, device=%d\n",
            attr.type, attr.device);
          // Get explicit GPU pointer (may be same as host pointer for mapped
          // memory)
          void* gpu_ptr = nullptr;
          hipError_t gpu_ptr_err = hipHostGetDevicePointer(&gpu_ptr, readBuffer,
                                                           0);
          if (gpu_ptr_err == hipSuccess && gpu_ptr != nullptr) {
            // Store GPU pointer for kernel launch (may be same as host pointer)
            readBufferGpu = static_cast<uint8_t*>(gpu_ptr);
            fprintf(stderr, "Read buffer GPU pointer: %p (host: %p)\n",
                    readBufferGpu, readBuffer);
          } else {
            // Fallback: use host pointer (should work for hipHostMallocMapped)
            readBufferGpu = readBuffer;
          }
        }
      } else {
        // Device memory - GPU pointer is same as host pointer
        readBufferGpu = readBuffer;
      }

      fprintf(stderr, "Read buffer allocated: virt=%p, phys=0x%llx, size=%zu\n",
              readBuffer, (unsigned long long)readBufferDma, dataBufferSize);
    }

    // Allocate write buffer if write I/O is requested (including sequential
    // mode)
    if (writeIo != 0) {
      // Try device memory first if requested (matching test-gpu-nvme-write.cpp
      // pattern)
      bool writeBufferOnDevice = dataBufferOnDevice; // Track if we're using
                                                     // device memory

      if (dataBufferOnDevice) {
        // Use hipMalloc for VRAM allocation (matching test code line 792)
        hipError_t buf_err = hipMalloc(&writeBuffer, dataBufferSize);
        if (buf_err != hipSuccess) {
          fprintf(stderr, "Error: hipMalloc failed for write buffer: %s\n",
                  hipGetErrorString(buf_err));
          // Free read buffer on failure
          if (readBuffer) {
            if (dataBufferOnDevice) {
              (void)hipFree(readBuffer);
            } else {
              (void)hipHostFree(readBuffer);
            }
          }
          return buf_err;
        }

        fprintf(stderr, "  VRAM buffer virtual: %p\n", writeBuffer);
        fprintf(stderr, "  Exporting as DMA-BUF (HSA runtime)...\n");

        // Detect if NVMe is emulated (needed for buffer registration flags)
        bool is_emulated = false;
        (void)xioDetectEmulatedNvme(nvmeConfig->device.c_str(), &is_emulated);

        // Export VRAM as dmabuf and register with kernel module
        int ret = export_and_register_vram_buffer(writeBuffer, dataBufferSize,
                                                  nvmeConfig->nvmeTargetBdf,
                                                  ROCM_XIO_DEVICE_PATH,
                                                  &writeBufferDma, is_emulated);
        if (ret < 0) {
          fprintf(stderr,
                  "ERROR: DMA-BUF export failed for device memory: %s\n",
                  strerror(-ret));
          fprintf(stderr, "  Device memory was requested but dmabuf export is "
                          "not available\n");
          (void)hipFree(writeBuffer);
          writeBuffer = nullptr;
          // Free read buffer on failure
          if (readBuffer) {
            if (readBufferActuallyOnDevice) {
              (void)hipFree(readBuffer);
            } else {
              (void)hipHostFree(readBuffer);
            }
          }
          return hipErrorInvalidValue;
        }

        fprintf(stderr, "  Data buffer physical: 0x%016llx (VRAM)\n",
                (unsigned long long)writeBufferDma);
        fprintf(stderr, "  GPU writes directly to VRAM\n");
        fprintf(stderr, "  NVMe DMAs from VRAM (P2P)\n");

        // Device memory - GPU pointer is same as host pointer
        writeBufferGpu = writeBuffer;
        writeBufferActuallyOnDevice = true; // Track that we're using device
                                            // memory
      } else {
        // Host memory - use hipHostMalloc (matching test code line 836)
        hipError_t buf_err = hipHostMalloc(&writeBuffer, dataBufferSize,
                                           hipHostMallocMapped);
        if (buf_err != hipSuccess) {
          fprintf(stderr, "Error: hipHostMalloc failed for write buffer: %s\n",
                  hipGetErrorString(buf_err));
          // Free read buffer on failure
          if (readBuffer) {
            if (readBufferActuallyOnDevice) {
              (void)hipFree(readBuffer);
            } else {
              (void)hipHostFree(readBuffer);
            }
          }
          return buf_err;
        }

        // Get physical address for host memory using /proc/self/pagemap
        writeBufferDma = xioGetPhysAddr(writeBuffer);
        if (!writeBufferDma) {
          fprintf(stderr,
                  "ERROR: Failed to get write buffer physical address\n");
          (void)hipHostFree(writeBuffer);
          writeBuffer = nullptr;
          // Free read buffer on failure
          if (readBuffer) {
            if (readBufferActuallyOnDevice) {
              (void)hipFree(readBuffer);
            } else {
              (void)hipHostFree(readBuffer);
            }
          }
          return hipErrorInvalidValue;
        }

        fprintf(stderr, "  Data buffer virtual:  %p\n", writeBuffer);
        fprintf(stderr, "  Data buffer physical: 0x%016llx\n",
                (unsigned long long)writeBufferDma);
        fprintf(stderr, "  GPU can write directly to this buffer\n");
        fprintf(stderr, "  NVMe can DMA from this buffer\n");
        writeBufferActuallyOnDevice = false; // Track that we're using host
                                             // memory
      }

      // Write buffer registration:
      // - Device memory: Already registered via
      // export_and_register_vram_buffer()
      // - Host memory: Physical address obtained from pagemap via
      // xioGetPhysAddr(), kernel module will use virt_to_phys() fallback if
      // needed for PRP injection

      // Verify write buffer is GPU-accessible and get GPU pointer if needed
      // (matches QEMU guest code pattern - hipHostMallocMapped should be
      // GPU-accessible)
      if (!writeBufferOnDevice) {
        hipPointerAttribute_t attr;
        hipError_t attr_err = hipPointerGetAttributes(&attr, writeBuffer);
        if (attr_err != hipSuccess) {
          fprintf(stderr,
                  "Warning: Write buffer may not be GPU-accessible: %s\n",
                  hipGetErrorString(attr_err));
          writeBufferGpu = writeBuffer; // Fallback to host pointer
        } else {
          fprintf(
            stderr,
            "Write buffer GPU accessibility verified: type=%d, device=%d\n",
            attr.type, attr.device);
          // Get explicit GPU pointer (may be same as host pointer for mapped
          // memory)
          void* gpu_ptr = nullptr;
          hipError_t gpu_ptr_err = hipHostGetDevicePointer(&gpu_ptr,
                                                           writeBuffer, 0);
          if (gpu_ptr_err == hipSuccess && gpu_ptr != nullptr) {
            // Store GPU pointer for kernel launch (may be same as host pointer)
            writeBufferGpu = static_cast<uint8_t*>(gpu_ptr);
            fprintf(stderr, "Write buffer GPU pointer: %p (host: %p)\n",
                    writeBufferGpu, writeBuffer);
          } else {
            // Fallback: use host pointer (should work for hipHostMallocMapped)
            writeBufferGpu = writeBuffer;
          }
        }
      } else {
        // Device memory - GPU pointer is same as host pointer
        writeBufferGpu = writeBuffer;
      }

      fprintf(stderr,
              "Write buffer allocated: virt=%p, phys=0x%llx, size=%zu\n",
              writeBuffer, (unsigned long long)writeBufferDma, dataBufferSize);
    }
  }

  // Launch GPU kernel with individual parameters (matching test-ep pattern)
  // Note: HIP device should already be set above, before queue creation
  // Verify all pointers are valid and GPU-accessible before launch
  if (!config->submissionQueue || !config->completionQueue) {
    fprintf(stderr, "Error: Invalid queue pointers (sq=%p, cq=%p)\n",
            config->submissionQueue, config->completionQueue);
    return hipErrorInvalidValue;
  }

  // Verify queue pointers are GPU-accessible (like we do for data buffers)
  hipPointerAttribute_t sq_attr, cq_attr;
  hipError_t sq_attr_err = hipPointerGetAttributes(&sq_attr,
                                                   config->submissionQueue);
  hipError_t cq_attr_err = hipPointerGetAttributes(&cq_attr,
                                                   config->completionQueue);

  if (sq_attr_err != hipSuccess) {
    fprintf(stderr,
            "Warning: Failed to get SQ pointer attributes: %s (code: %d)\n",
            hipGetErrorString(sq_attr_err), sq_attr_err);
    fprintf(stderr, "SQ pointer may not be GPU-accessible\n");
  } else {
    fprintf(stderr, "SQ GPU accessibility verified: type=%d, device=%d\n",
            sq_attr.type, sq_attr.device);
  }

  if (cq_attr_err != hipSuccess) {
    fprintf(stderr,
            "Warning: Failed to get CQ pointer attributes: %s (code: %d)\n",
            hipGetErrorString(cq_attr_err), cq_attr_err);
    fprintf(stderr, "CQ pointer may not be GPU-accessible\n");
  } else {
    fprintf(stderr, "CQ GPU accessibility verified: type=%d, device=%d\n",
            cq_attr.type, cq_attr.device);
  }

  // Verify shadowBufferVirt is GPU-accessible if it's non-null (like we do for
  // data buffers)
  if (shadowBufferVirt != nullptr) {
    hipPointerAttribute_t shadow_attr;
    hipError_t shadow_attr_err = hipPointerGetAttributes(&shadow_attr,
                                                         shadowBufferVirt);
    if (shadow_attr_err != hipSuccess) {
      fprintf(stderr,
              "Warning: Failed to get shadow buffer pointer attributes: %s "
              "(code: %d)\n",
              hipGetErrorString(shadow_attr_err), shadow_attr_err);
      fprintf(stderr, "Shadow buffer may not be GPU-accessible - disabling PCI "
                      "MMIO bridge mode\n");
      shadowBufferVirt = nullptr;
      usePciMmioBridge = false;
    } else {
      fprintf(stderr,
              "Shadow buffer GPU accessibility verified: type=%d, device=%d\n",
              shadow_attr.type, shadow_attr.device);
    }
  }

  // Verify nvmeBar0Gpu is GPU-accessible if it's non-null
  if (nvmeBar0Gpu != nullptr) {
    hipPointerAttribute_t bar0_attr;
    hipError_t bar0_attr_err = hipPointerGetAttributes(&bar0_attr, nvmeBar0Gpu);
    if (bar0_attr_err != hipSuccess) {
      fprintf(stderr,
              "Warning: Failed to get BAR0 pointer attributes: %s (code: %d)\n",
              hipGetErrorString(bar0_attr_err), bar0_attr_err);
      fprintf(
        stderr,
        "BAR0 may not be GPU-accessible - disabling direct doorbell mode\n");
      nvmeBar0Gpu = nullptr;
    } else {
      fprintf(stderr, "BAR0 GPU accessibility verified: type=%d, device=%d\n",
              bar0_attr.type, bar0_attr.device);
    }
  }

  // All pointers are GPU-accessible:
  // - Queues: allocated with hipHostMalloc (via
  // xioAllocateSubmissionQueue/CompletionQueue)
  // - startTimes/endTimes: allocated with hipHostMalloc in tester
  // - shadowBufferVirt: GPU pointer (from shadow buffer registration, if
  // enabled) - verified above
  // - readBuffer/writeBuffer: GPU pointers (from hipHostGetDevicePointer, if
  // host memory) Pass all pointers directly like test-ep does (test-ep line
  // 870-873)

  // Note: shadowBufferVirt is from kernel module mmap, which may not be
  // GPU-accessible even after hipHostRegister. If PCI MMIO bridge is enabled
  // but shadow buffer registration failed, disable PCI MMIO bridge mode to
  // avoid kernel launch failure. The GPU kernel handles nullptr
  // shadowBufferVirt gracefully.

  fprintf(stderr,
          "Launching kernel: sq=%p, cq=%p, startTimes=%p, endTimes=%p, "
          "shadowBuffer=%p, usePciMmioBridge=%d, nvmeBar0Gpu=%p\n",
          config->submissionQueue, config->completionQueue, config->startTimes,
          config->endTimes, shadowBufferVirt, usePciMmioBridge, nvmeBar0Gpu);
  fprintf(stderr,
          "Data buffers: readBuffer=%p (dma=0x%llx), writeBuffer=%p "
          "(dma=0x%llx), size=%zu\n",
          readBufferGpu ? readBufferGpu : readBuffer,
          (unsigned long long)readBufferDma,
          writeBufferGpu ? writeBufferGpu : writeBuffer,
          (unsigned long long)writeBufferDma, dataBufferSize);
  fprintf(stderr,
          "Kernel parameters: lbaSize=%u, blocks=8, expected transfer_size=%u, "
          "writeBufferDma=0x%llx\n",
          lbaSize, 8 * lbaSize, (unsigned long long)writeBufferDma);

  // Launch kernel - matching test-ep pattern exactly (line 870-873)
  // queue_size is in entries (calculated above, stored in queue_size variable)

  fprintf(stderr, "Calling hipLaunchKernelGGL...\n");
  fflush(stderr);
  fprintf(stderr, "Queue length: %u entries\n", queue_size);
  fflush(stderr);

  // Validate pointers before casting and launching kernel
  if (!config) {
    fprintf(stderr, "Error: config is null\n");
    fflush(stderr);
    return hipErrorInvalidValue;
  }
  if (!config->submissionQueue || !config->completionQueue) {
    fprintf(stderr, "Error: Invalid queue pointers before kernel launch\n");
    fprintf(stderr, "  submissionQueue=%p, completionQueue=%p\n",
            config->submissionQueue, config->completionQueue);
    fflush(stderr);
    return hipErrorInvalidValue;
  }
  
  // Validate numThreads before kernel launch
  if (config->numThreads == 0 || config->numThreads > 1024) {
    fprintf(stderr, "Error: Invalid numThreads=%u (must be 1-1024)\n",
            config->numThreads);
    fflush(stderr);
    return hipErrorInvalidValue;
  }

  // Cast void* to typed pointers like test-ep does (test-ep line 778-779)
  // This helps HIP validate the pointers correctly
  struct nvme_sqe* sqePtr = static_cast<struct nvme_sqe*>(
    config->submissionQueue);
  struct nvme_cqe* cqePtr = static_cast<struct nvme_cqe*>(
    config->completionQueue);

  fprintf(stderr, "About to launch kernel with numThreads=%u\n",
          config->numThreads);
  fprintf(stderr,
          "Kernel parameters: iterations=%u, lbaSize=%u, baseLba=%llu\n",
          config->iterations, lbaSize, (unsigned long long)baseLba);
  fprintf(stderr,
          "Pointers: sqePtr=%p, cqePtr=%p, startTimes=%p, endTimes=%p\n",
          sqePtr, cqePtr, config->startTimes, config->endTimes);
  fprintf(stderr, "Buffers: readBuffer=%p, writeBuffer=%p, shadowBuffer=%p\n",
          readBufferGpu ? readBufferGpu : readBuffer,
          writeBufferGpu ? writeBufferGpu : writeBuffer,
          shadowBufferVirt);
  fflush(stderr);

  // Clear any pending HIP errors before kernel launch
  hipError_t preLaunchErr = hipGetLastError();
  if (preLaunchErr != hipSuccess) {
    fprintf(stderr, "Warning: Pending HIP error before kernel launch: %s\n",
            hipGetErrorString(preLaunchErr));
    fflush(stderr);
  }

  // Flush all output before kernel launch
  fflush(stderr);
  fflush(stdout);

  // Ensure HIP device is set and synchronized before kernel launch
  hipError_t dev_err = hipSetDevice(0);
  if (dev_err != hipSuccess) {
    fprintf(stderr, "Error: Failed to set HIP device 0 before launch: %s\n",
            hipGetErrorString(dev_err));
    fflush(stderr);
    return dev_err;
  }

  // Synchronize HIP before kernel launch to ensure all memory operations
  // (including BAR0 registration) are complete
  hipError_t sync_err = hipDeviceSynchronize();
  if (sync_err != hipSuccess) {
    fprintf(stderr, "Warning: hipDeviceSynchronize before launch failed: %s\n",
            hipGetErrorString(sync_err));
    fflush(stderr);
    // Continue anyway - this might not be fatal
  }

  // Launch kernel - HIP may crash with many parameters, so we try to catch it
  // by ensuring all parameters are valid before the call
  hipLaunchKernelGGL(
    nvme_ep_kernel, dim3(1), dim3(config->numThreads), 0, 0,
    sqePtr,             // Cast to typed pointer like test-ep
    cqePtr,             // Cast to typed pointer like test-ep
    config->startTimes, // GPU-accessible (hipHostMalloc in tester) - pass
                        // directly like test-ep
    config->endTimes,   // GPU-accessible (hipHostMalloc in tester) - pass
                        // directly like test-ep
    config->iterations, config->numThreads, lbaSize, baseLba, usePciMmioBridge,
    shadowBufferVirt, // GPU pointer (from shadow buffer registration, if
                      // enabled)
    nvmeTargetBdf, queueId,
    doorbell_offset, // Doorbell offset calculated on host (matching
                     // test-gpu-nvme-write.cpp)
    readBufferGpu ? readBufferGpu
                  : readBuffer, // GPU pointer if available (host memory)
    writeBufferGpu ? writeBufferGpu
                   : writeBuffer, // GPU pointer if available (host memory)
    dataBufferSize, readBufferDma, writeBufferDma, lfsrSeed, queue_size,
    lbaRangeLbas,    // LBA range in LBAs (0 = no limit)
    useRandomAccess, // true for random access, false for sequential
    nvmeBar0Gpu,     // GPU pointer to NVMe BAR0 (for direct doorbell)
    readIo,          // readIo (negative for sequential mode)
    writeIo,         // writeIo (negative for sequential mode)
    batchSize,       // Batch size (0 = auto: min(queue_size/2, 16))
    config->verbose); // Verbose level (0=none, 1=normal, 2=very verbose)

  // Check for kernel launch errors immediately
  hipError_t err = hipGetLastError();
  if (err != hipSuccess) {
    fprintf(stderr, "Kernel launch error: %s (code: %d)\n",
            hipGetErrorString(err), err);
    fprintf(stderr,
            "Debug: submissionQueue=%p, completionQueue=%p, "
            "startTimes=%p, endTimes=%p, shadowBuffer=%p\n",
            config->submissionQueue, config->completionQueue,
            config->startTimes, config->endTimes, shadowBufferVirt);

    // Additional diagnostics
    int diag_device = -1;
    hipError_t diag_err = hipGetDevice(&diag_device);
    fprintf(stderr, "HIP device after launch error: device=%d, err=%d\n",
            diag_device, diag_err);

    return err;
  }

  fprintf(stderr, "Kernel launched successfully\n");

  // Wait for GPU kernel to complete (kernel rings doorbell internally)
  err = hipDeviceSynchronize();
  if (err != hipSuccess) {
    fprintf(stderr, "Device synchronization error: %s (code: %d)\n",
            hipGetErrorString(err), err);
  }

  // Add a small delay to ensure all NVMe commands have completed
  // This helps avoid race conditions when cleaning up queues
  usleep(10000); // 10ms delay

  // Cleanup buffers: unregister from kernel module before freeing
  int kmod_fd_cleanup = open(ROCM_XIO_DEVICE_PATH, O_RDWR);
  if (kmod_fd_cleanup >= 0) {
    // Unregister read buffer if it was registered (check if DMA address was set)
    if (readBuffer && readBufferDma != 0) {
      rocm_axiio_unregister_buffer_req unreg_req = {};
      unreg_req.virt_addr = reinterpret_cast<uint64_t>(readBuffer);
      int unreg_ret = ioctl(kmod_fd_cleanup, ROCM_XIO_UNREGISTER_BUFFER,
                            &unreg_req);
      if (unreg_ret < 0 && errno != ENOENT) {
        fprintf(stderr, "Warning: Failed to unregister read buffer: %s\n",
                strerror(errno));
      }
    }

    // Unregister write buffer if it was registered (check if DMA address was set)
    if (writeBuffer && writeBufferDma != 0) {
      rocm_axiio_unregister_buffer_req unreg_req = {};
      unreg_req.virt_addr = reinterpret_cast<uint64_t>(writeBuffer);
      int unreg_ret = ioctl(kmod_fd_cleanup, ROCM_XIO_UNREGISTER_BUFFER,
                            &unreg_req);
      if (unreg_ret < 0 && errno != ENOENT) {
        fprintf(stderr, "Warning: Failed to unregister write buffer: %s\n",
                strerror(errno));
      }
    }
    close(kmod_fd_cleanup);
  }

  // Free data buffers after unregistering
  if (readBuffer) {
    if (readBufferActuallyOnDevice) {
      (void)hipFree(readBuffer);
    } else {
      (void)hipHostFree(readBuffer);
    }
  }
  if (writeBuffer) {
    if (writeBufferActuallyOnDevice) {
      (void)hipFree(writeBuffer);
    } else {
      (void)hipHostFree(writeBuffer);
    }
  }

  // Cleanup NVMe queues after kernel completes and buffers are freed
  int cleanup_ret = nvme_ep::nvme_cleanup_queue_via_ioctl(
    nvmeConfig->device.c_str(), ROCM_XIO_DEVICE_PATH, nvmeConfig->queueId,
    &queue_info, config->memoryMode);
  if (cleanup_ret < 0) {
    fprintf(stderr, "Warning: Queue cleanup failed: %s\n",
            strerror(-cleanup_ret));
    // Don't fail the test if cleanup fails - kernel already completed
  }

  // Unregister shadow buffer from HIP if it was registered
  // This must be done before unmapping to avoid heap corruption
  if (nvmeConfig->shadowBufferCpu != nullptr) {
    hipError_t unreg_err = hipHostUnregister(nvmeConfig->shadowBufferCpu);
    if (unreg_err != hipSuccess) {
      fprintf(stderr, "Warning: Failed to unregister shadow buffer from HIP: "
              "%s\n", hipGetErrorString(unreg_err));
    } else {
      fprintf(stderr, "Shadow buffer unregistered from HIP\n");
    }
    // Note: We don't unmap shadow buffer here - it's mmap'd and will be cleaned
    // up when the process exits. The file descriptors are also kept open.
  }

  // Unregister BAR0 from HIP if it was registered
  // This must be done before unmapping to avoid heap corruption
  if (nvmeConfig->nvmeBar0Cpu != nullptr) {
    hipError_t unreg_err = hipHostUnregister(nvmeConfig->nvmeBar0Cpu);
    if (unreg_err != hipSuccess) {
      fprintf(stderr, "Warning: Failed to unregister BAR0 from HIP: %s\n",
              hipGetErrorString(unreg_err));
    } else {
      fprintf(stderr, "BAR0 unregistered from HIP\n");
    }
    // Note: We don't unmap BAR0 here - it's mmap'd and will be cleaned up
    // when the process exits. The file descriptors are also kept open.
  }

  return err;
}

// Read PCI config space register
// Old PCI config reading functions removed - now using kernel module IOCTL
// PCI MMIO bridge shadow buffer mapping moved to xio-mmio-bridge.hip

/**
 * Check if NVMe controller supports non-contiguous queues (PC=0)
 *
 * Reads the CAP register and checks the CQR (Contiguous Queues Required) bit.
 * If CQR=0, the controller supports non-contiguous queues (PC=0).
 * If CQR=1, the controller requires contiguous queues (PC=1).
 *
 * @param nvme_bdf NVMe device BDF in 0xBBDD format
 * @param supports_pc0 Output parameter: true if PC=0 is supported, false if PC=1
 *                    is required
 * @return 0 on success, negative error code on failure
 */
__host__ int nvme_ep_check_pc0_support(uint16_t nvme_bdf, bool* supports_pc0) {
  uint64_t cap = 0;
  int ret = 0;

  if (!supports_pc0) {
    return -EINVAL;
  }

  ret = nvme_ep_read_cap_register(nvme_bdf, &cap);
  if (ret < 0) {
    fprintf(stderr, "Failed to read CAP register: %s\n", strerror(-ret));
    return ret;
  }

  // CQR (Contiguous Queues Required) is bit 16 of CAP register
  // CQR=0 means PC=0 (non-contiguous) is supported
  // CQR=1 means PC=1 (contiguous) is required
  const uint64_t CQR_MASK = (1ULL << 16);
  *supports_pc0 = ((cap & CQR_MASK) == 0);

  fprintf(stderr, "NVMe CAP register: 0x%016llx, CQR=%u, PC=0 supported: %s\n",
          (unsigned long long)cap, (unsigned)((cap >> 16) & 1),
          *supports_pc0 ? "YES" : "NO");

  return 0;
}

// Structure for NVMe Identify Namespace response (4096 bytes)
// When USE_LIBNVME is defined, libnvme provides this struct, so we skip it.
#ifndef USE_LIBNVME
struct nvme_id_ns {
  uint64_t nsze;  // Namespace size
  uint64_t ncap;  // Namespace capacity
  uint64_t nuse;  // Namespace utilization
  uint8_t nsfeat; // Namespace features
  uint8_t nlbaf;  // Number of LBA formats
  uint8_t flbas;  // Formatted LBA size (bits 3:0 = current format index)
  uint8_t mc;     // Metadata capabilities
  uint8_t dpc;    // End-to-end data protection capabilities
  uint8_t dps;    // End-to-end data protection type settings
  uint8_t nmic;   // Namespace multi-path I/O and namespace sharing capabilities
  uint8_t rescap; // Reservation capabilities
  uint8_t fpi;    // Format progress indicator
  uint8_t dlfeat; // Deallocate logical block features
  uint16_t nawun; // Namespace atomic write unit normal
  uint16_t nawupf;    // Namespace atomic write unit power fail
  uint16_t nacwu;     // Namespace atomic compare and write unit
  uint16_t nabsn;     // Namespace atomic boundary size normal
  uint16_t nabo;      // Namespace atomic boundary offset
  uint16_t nabspf;    // Namespace atomic boundary size power fail
  uint16_t noiob;     // Namespace optimal I/O boundary
  uint8_t nvmcap[16]; // NVM capacity
  uint8_t resv[40];   // Reserved
  uint8_t lbaf[64];   // LBA format support (16 formats * 4 bytes each)
};
#endif // USE_LIBNVME

__host__ int nvme_ep_query_lba_size(const char* nvme_device, uint32_t nsid,
                                    unsigned* lba_size) {
  // Declare all variables at the top to avoid goto scoping issues
  int nvme_fd = -1;
  int ret = 0;
  struct nvme_passthru_cmd cmd;
  struct nvme_id_ns* id_ns = nullptr;
  uint8_t flbas = 0;
  uint8_t lba_format_idx = 0;
  uint8_t* lbaf_ptr = nullptr;
  uint8_t lbads = 0;
  uint16_t status = 0;
  uint8_t* response_base = nullptr; // Base pointer for accessing lbaf array

  if (!nvme_device || !lba_size) {
    return -EINVAL;
  }

  // Allocate buffer for Identify Namespace response (4096 bytes)
  id_ns = static_cast<struct nvme_id_ns*>(malloc(4096));
  if (!id_ns) {
    return -ENOMEM;
  }
  memset(id_ns, 0, 4096);

  // Open NVMe device
  nvme_fd = open(nvme_device, O_RDONLY);
  if (nvme_fd < 0) {
    fprintf(stderr, "Failed to open NVMe device %s: %s\n", nvme_device,
            strerror(errno));
    ret = -errno;
    goto cleanup;
  }

  // Send Identify Namespace command
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_identify;
  cmd.nsid = nsid;
  cmd.cdw10 = 0; // CNS=0 (Identify Namespace)
  cmd.addr = reinterpret_cast<uint64_t>(id_ns);
  cmd.data_len = 4096;
  cmd.timeout_ms = 0; // Use default timeout

  ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret < 0) {
    fprintf(stderr, "Failed to identify namespace: %s\n", strerror(errno));
    ret = -errno;
    goto cleanup;
  }

  // Check completion status
  if (cmd.result & 0xFFFE) {
    status = (cmd.result >> 1) & 0xFF;
    fprintf(stderr, "Identify Namespace failed with status 0x%02x\n", status);
    ret = -EIO;
    goto cleanup;
  }

  // Extract FLBAS (Formatted LBA and Metadata Size)
  // Bits 3:0 contain the current LBA format index
  flbas = id_ns->flbas;
  lba_format_idx = flbas & 0x0F;

  // Validate LBA format index
  // nlbaf indicates the number of LBA formats supported (0-indexed)
  // Valid format indices are 0 through nlbaf (inclusive)
  // So if nlbaf=7, formats 0-7 are supported (8 formats total)
  if (lba_format_idx > id_ns->nlbaf) {
    fprintf(stderr, "Invalid LBA format index %u (max supported: %u)\n",
            lba_format_idx, id_ns->nlbaf);
    ret = -EINVAL;
    goto cleanup;
  }

  // Extract LBADS (LBA Data Size) from LBA Format structure
  // LBA Format structures start at offset 128 (after header) in the NVMe
  // response According to Linux kernel struct nvme_lbaf:
  //   struct nvme_lbaf {
  //     __le16  ms;    // Metadata size (bytes 0-1, little-endian)
  //     __u8    ds;    // LBA Data Size - LBADS (byte 2)
  //     __u8    rp;    // Relative Performance (byte 3)
  //   };
  // So LBADS is in byte 2 of each 4-byte structure, not byte 0!
  //
  // IMPORTANT: Access lbaf array using byte offset from start of buffer
  // to avoid structure padding/alignment issues. The lbaf array starts at
  // offset 128 bytes from the start of the Identify Namespace response.
  response_base = reinterpret_cast<uint8_t*>(id_ns);
  lbaf_ptr = response_base + 128 + (lba_format_idx * 4);

  // Debug: Print raw bytes for format 0 to diagnose parsing issues
  if (lba_format_idx == 0) {
    uint8_t* lbaf0_raw = response_base + 128;
    fprintf(stderr,
            "Debug: Format 0 raw bytes at offset 128: "
            "[0]=0x%02x [1]=0x%02x [2]=0x%02x [3]=0x%02x\n",
            lbaf0_raw[0], lbaf0_raw[1], lbaf0_raw[2], lbaf0_raw[3]);
    // Also check as 32-bit little-endian value
    uint32_t lbaf0_u32 = *reinterpret_cast<uint32_t*>(lbaf0_raw);
    fprintf(stderr, "Debug: Format 0 as uint32 (little-endian): 0x%08x\n",
            lbaf0_u32);
    fprintf(
      stderr,
      "Debug: Extracting bits - [0-7]=%u [8-15]=%u [16-23]=%u [24-31]=%u\n",
      (lbaf0_u32 >> 0) & 0xFF, (lbaf0_u32 >> 8) & 0xFF,
      (lbaf0_u32 >> 16) & 0xFF, (lbaf0_u32 >> 24) & 0xFF);
  }

  // LBADS (ds field) is in byte 2 according to struct nvme_lbaf
  // Structure layout: bytes[0-1]=ms (little-endian), byte[2]=ds (LBADS),
  // byte[3]=rp
  lbads = lbaf_ptr[2] & 0xFF;

  // Debug: If byte 0 is 0, check if the value is in byte 2 (might indicate
  // alignment issue)
  if (lbads == 0 && lbaf_ptr[2] != 0) {
    fprintf(stderr,
            "Debug: Byte 0 is 0, but byte 2 has value 0x%02x - "
            "possible structure alignment issue\n",
            lbaf_ptr[2]);
    // Try reading from byte 2 as a workaround (this shouldn't be necessary if
    // structure is correct) But for now, let's see what the actual layout is
  }

  // Debug output - show all supported formats
  // nlbaf indicates number of formats supported, valid indices are 0 through
  // nlbaf
  fprintf(stderr,
          "LBA size detection: nlbaf=%u (supports formats 0-%u), "
          "flbas=0x%02x, lba_format_idx=%u\n",
          id_ns->nlbaf, id_ns->nlbaf, flbas, lba_format_idx);
  fprintf(stderr, "Supported LBA formats:\n");
  for (uint8_t i = 0; i <= id_ns->nlbaf && i < 16; i++) {
    // Access lbaf using byte offset from start of buffer (offset 128)
    // Structure: bytes[0-1]=ms (little-endian), byte[2]=ds (LBADS), byte[3]=rp
    uint8_t* lbaf_i_ptr = response_base + 128 + (i * 4);
    uint16_t ms_i = lbaf_i_ptr[0] | (lbaf_i_ptr[1] << 8); // Little-endian
    uint8_t lbads_i = lbaf_i_ptr[2] & 0xFF;               // LBADS is in byte 2
    uint32_t lba_size_i = (lbads_i > 0) ? (1U << lbads_i) : 0;
    fprintf(stderr, "  Format %u: lbads=%u, ms=%u, lba_size=%u bytes%s\n", i,
            lbads_i, ms_i, lba_size_i,
            (i == lba_format_idx) ? " (current)" : "");
  }

  // Validate LBADS value
  // LBADS=0 indicates unformatted namespace or invalid format
  // Standard LBA sizes: lbads=9 (512B), lbads=12 (4KB)
  // Some devices may support lbads=8 (256B) or other values
  if (lbads == 0) {
    fprintf(stderr,
            "Warning: Invalid LBADS value (0) in format %u, "
            "namespace may be unformatted\n",
            lba_format_idx);

    // Try to find a valid format by checking other supported indices
    // Only check formats 0 through nlbaf (as indicated by nlbaf)
    bool found_valid = false;
    for (uint8_t i = 0; i <= id_ns->nlbaf && i < 16; i++) {
      // Access lbaf using byte offset from start of buffer (offset 128)
      // Structure: bytes[0-1]=ms (little-endian), byte[2]=ds (LBADS),
      // byte[3]=rp
      uint8_t* lbaf_i_ptr = response_base + 128 + (i * 4);
      uint8_t lbads_i = lbaf_i_ptr[2] & 0xFF; // LBADS is in byte 2
      if (lbads_i > 0) {
        uint32_t lba_size_i = 1U << lbads_i;
        fprintf(stderr,
                "Found format %u with lbads=%u (lba_size=%u bytes), "
                "using it instead\n",
                i, lbads_i, lba_size_i);
        if (lbads_i < 9) {
          fprintf(stderr,
                  "Warning: Unusual LBA size (%u bytes), "
                  "standard sizes are 512B (lbads=9) or 4KB (lbads=12)\n",
                  lba_size_i);
        }
        lbads = lbads_i;
        found_valid = true;
        break;
      }
    }

    if (!found_valid) {
      fprintf(stderr, "No valid LBA format found, will fall back to default\n");
      // Return error so caller can use fallback
      ret = -EINVAL;
      goto cleanup;
    }
  } else if (lbads < 9) {
    // Valid but unusual LBA size
    fprintf(stderr,
            "Warning: Unusual LBA size (%u bytes, lbads=%u), "
            "standard sizes are 512B (lbads=9) or 4KB (lbads=12)\n",
            1U << lbads, lbads);
  }

  // LBA size = 2^LBADS bytes
  *lba_size = 1U << lbads;
  fprintf(stderr, "Selected LBA size: %u bytes (lbads=%u)\n", *lba_size, lbads);

  ret = 0;

cleanup:
  if (nvme_fd >= 0) {
    close(nvme_fd);
  }
  if (id_ns) {
    free(id_ns);
  }
  return ret;
}

__host__ int nvme_ep_query_namespace_capacity(const char* nvme_device,
                                              uint32_t nsid,
                                              uint64_t* capacity_lbas) {
  int nvme_fd = -1;
  int ret = 0;
  struct nvme_passthru_cmd cmd;
  struct nvme_id_ns* id_ns = nullptr;
  uint16_t status = 0;

  if (!nvme_device || !capacity_lbas) {
    return -EINVAL;
  }

  // Allocate buffer for Identify Namespace response (4096 bytes)
  id_ns = static_cast<struct nvme_id_ns*>(malloc(4096));
  if (!id_ns) {
    return -ENOMEM;
  }
  memset(id_ns, 0, 4096);

  // Open NVMe device
  nvme_fd = open(nvme_device, O_RDONLY);
  if (nvme_fd < 0) {
    fprintf(stderr, "Failed to open NVMe device %s: %s\n", nvme_device,
            strerror(errno));
    ret = -errno;
    goto cleanup;
  }

  // Send Identify Namespace command
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_identify;
  cmd.nsid = nsid;
  cmd.cdw10 = 0; // CNS=0 (Identify Namespace)
  cmd.addr = reinterpret_cast<uint64_t>(id_ns);
  cmd.data_len = 4096;
  cmd.timeout_ms = 0; // Use default timeout

  ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret < 0) {
    fprintf(stderr, "Failed to identify namespace: %s\n", strerror(errno));
    ret = -errno;
    goto cleanup;
  }

  // Check completion status
  if (cmd.result & 0xFFFE) {
    status = (cmd.result >> 1) & 0xFF;
    fprintf(stderr, "Identify Namespace failed with status 0x%02x\n", status);
    ret = -EIO;
    goto cleanup;
  }

  // Extract NSZE (Namespace Size) - capacity in LBAs
  // NSZE is little-endian 64-bit value at offset 0
  *capacity_lbas = id_ns->nsze;
  fprintf(stderr, "Namespace capacity: %llu LBAs\n",
          (unsigned long long)*capacity_lbas);

  ret = 0;

cleanup:
  if (nvme_fd >= 0) {
    close(nvme_fd);
  }
  if (id_ns) {
    free(id_ns);
  }
  return ret;
}

__host__ int nvme_ep_check_rootfs(const char* nvme_device) {
  // Extract namespace device (e.g., /dev/nvme0 -> /dev/nvme0n1)
  char ns_device[256];
  snprintf(ns_device, sizeof(ns_device), "%sn1", nvme_device);

  // Check /proc/mounts for root mount
  FILE* f = fopen("/proc/mounts", "r");
  if (!f) {
    fprintf(stderr, "Warning: Failed to open /proc/mounts\n");
    return 0; // Can't check, allow to proceed
  }

  char line[512];
  bool is_rootfs = false;
  while (fgets(line, sizeof(line), f)) {
    // Format: device mount_point filesystem ...
    char device[256], mount_point[256];
    if (sscanf(line, "%255s %255s", device, mount_point) == 2) {
      if (strcmp(mount_point, "/") == 0) {
        // Check if this device matches our NVMe device
        if (strstr(device, ns_device) != nullptr ||
            strstr(device, nvme_device) != nullptr) {
          is_rootfs = true;
          break;
        }
      }
    }
  }
  fclose(f);

  if (is_rootfs) {
    fprintf(stderr,
            "ERROR: NVMe device %s appears to be the root filesystem!\n",
            nvme_device);
    fprintf(stderr, "This operation will NOT proceed on rootfs to prevent data "
                    "corruption.\n");
    fprintf(stderr, "Please specify a different NVMe device.\n");
    return -1;
  }

  return 0;
}

__host__ int nvme_ep_read_smart_log(const char* nvme_device,
                                    struct nvme_smart_log* smart_log) {
  int nvme_fd = open(nvme_device, O_RDONLY);
  if (nvme_fd < 0) {
    fprintf(stderr, "Failed to open NVMe device %s: %s\n", nvme_device,
            strerror(errno));
    return -errno;
  }

  // Allocate buffer on heap to ensure kernel can access it
  // Stack-allocated buffers might not work with ioctl
  uint8_t* buffer = static_cast<uint8_t*>(malloc(512));
  if (!buffer) {
    fprintf(stderr, "Failed to allocate SMART log buffer\n");
    close(nvme_fd);
    return -ENOMEM;
  }
  memset(buffer, 0, 512);

  // Use NVME_IOCTL_ADMIN64_CMD with nvme_passthru_cmd64 structure
  // NVME_IOCTL_ADMIN_CMD expects nvme_admin_cmd which has different layout
  // The 64-bit version is needed for the 64-bit result field
  struct nvme_passthru_cmd64 cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_get_log_page;
  cmd.nsid = 0xFFFFFFFF; // Controller-level log
  // cdw10: NUMD (Number of Dwords) in bits [31:16], LID (Log Identifier) in
  // bits [15:0] NUMD = 127 (0x7F) for 512 bytes, LID = 0x02 (SMART/Health
  // Information)
  cmd.cdw10 = (127 << 16) | 0x02; // (NUMD << 16) | LID
  cmd.cdw11 = 0x00000000;         // Reserved
  cmd.cdw12 = 0x0000007F;         // RAE=0, LSP=0, LSI=0x7F (all fields)
  cmd.addr = reinterpret_cast<uint64_t>(buffer);
  cmd.data_len = 512;
  cmd.timeout_ms = 0;

  int ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN64_CMD, &cmd);
  if (ret < 0) {
    fprintf(stderr, "Failed to read SMART log: %s\n", strerror(errno));
    free(buffer);
    close(nvme_fd);
    return -errno;
  }

  // Check completion status
  if (cmd.result & 0xFFFE) {
    uint16_t status = (cmd.result >> 1) & 0xFF;
    fprintf(stderr, "SMART log read failed with status 0x%02x\n", status);
    free(buffer);
    close(nvme_fd);
    return -EIO;
  }

  // Copy data from buffer to structure
  memcpy(smart_log, buffer, 512);

  free(buffer);
  close(nvme_fd);
  return 0;
}

/**
 * Generate PRP list for non-contiguous queue buffer
 * For PC=0 queues, NVMe requires a PRP list describing all physical pages
 * 
 * @param virt_addr Virtual address of queue buffer
 * @param size Size of queue buffer in bytes
 * @param kmod_fd Kernel module file descriptor (for allocating PRP list memory)
 * @param base_phys_addr Base physical address (0 = use pagemap, non-zero = use this for DMA-BUF)
 * @param prp1_out Output: PRP1 value (first page address or PRP list address)
 * @param prp2_out Output: PRP2 value (second page address, PRP list address, or 0)
 * @param prp_list_virt_out Output: Virtual address of PRP list (for cleanup)
 * @param prp_list_phys_out Output: Physical address of PRP list
 * @return 0 on success, negative error code on failure
 */
static int generate_prp_list_for_queue(void* virt_addr, size_t size, int kmod_fd,
                                       uint64_t base_phys_addr,
                                       uint64_t* prp1_out, uint64_t* prp2_out,
                                       void** prp_list_virt_out,
                                       uint64_t* prp_list_kernel_virt_out) {
  const size_t host_page_size = sysconf(_SC_PAGESIZE);
  const size_t nvme_page_size = NVME_PAGE_SIZE; // Typically 4096
  uint64_t virt_start = reinterpret_cast<uint64_t>(virt_addr);
  uint64_t page_offset = virt_start % host_page_size;
  
  // Calculate number of pages the queue spans
  size_t num_pages = (size + page_offset + host_page_size - 1) / host_page_size;
  
  // Allocate array to hold physical page addresses
  uint64_t* page_phys_addrs = static_cast<uint64_t*>(malloc(num_pages * sizeof(uint64_t)));
  if (!page_phys_addrs) {
    return -ENOMEM;
  }
  
  // Get physical addresses of all pages
  if (base_phys_addr != 0) {
    // DMA-BUF memory: use provided base physical address
    // Calculate page addresses from base address
    uint64_t base_page_phys = base_phys_addr & ~(host_page_size - 1);
    uint64_t base_offset = base_phys_addr & (host_page_size - 1);
    
    for (size_t i = 0; i < num_pages; i++) {
      uint64_t page_phys_addr = base_page_phys + (i * host_page_size);
      // For first page, add offset within page
      if (i == 0) {
        page_phys_addr += base_offset;
      }
      page_phys_addrs[i] = page_phys_addr;
    }
  } else {
    // Host memory: use /proc/self/pagemap
    int pagemap_fd = open("/proc/self/pagemap", O_RDONLY);
    if (pagemap_fd < 0) {
      fprintf(stderr, "ERROR: Failed to open /proc/self/pagemap: %s\n",
              strerror(errno));
      free(page_phys_addrs);
      return -errno;
    }
    
    // Read physical addresses for all pages
    for (size_t i = 0; i < num_pages; i++) {
      uint64_t pfn;
      off_t pagemap_offset = ((virt_start / host_page_size) + i) * sizeof(uint64_t);
      
      if (lseek(pagemap_fd, pagemap_offset, SEEK_SET) < 0 ||
          read(pagemap_fd, &pfn, sizeof(pfn)) != sizeof(pfn)) {
        fprintf(stderr, "ERROR: Failed to read pagemap page %zu\n", i);
        free(page_phys_addrs);
        close(pagemap_fd);
        return -EIO;
      }
      
      if (!(pfn & (1ULL << 63))) {
        fprintf(stderr, "ERROR: Page %zu not present in pagemap\n", i);
        free(page_phys_addrs);
        close(pagemap_fd);
        return -EFAULT;
      }
      
      uint64_t phys_pfn = pfn & ((1ULL << 55) - 1);
      uint64_t page_phys_addr = phys_pfn * host_page_size;
      
      // For first page, add offset within page
      if (i == 0) {
        page_phys_addr += page_offset;
      }
      
      page_phys_addrs[i] = page_phys_addr;
    }
    
    close(pagemap_fd);
  }
  
  // Calculate PRP1 and PRP2 based on number of pages
  uint64_t prp1 = page_phys_addrs[0];
  uint64_t prp2 = 0;
  void* prp_list_virt = nullptr;
  uint64_t prp_list_phys = 0; // Will be set to kernel or userspace physical address
  uint64_t prp_list_kernel_virt = 0; // 0 means userspace-allocated, non-zero means kernel-allocated
  
  if (num_pages == 1) {
    // Single page: PRP1 = page address, PRP2 = 0
    prp2 = 0;
    prp_list_kernel_virt = 0;
  } else if (num_pages == 2) {
    // Two pages: PRP1 = first page, PRP2 = second page
    prp2 = page_phys_addrs[1];
    prp_list_kernel_virt = 0;
  } else {
    // More than 2 pages: Need PRP list
    // PRP list must be physically contiguous and page-aligned
    size_t prp_list_size = num_pages * sizeof(uint64_t);
    // Ensure PRP list size is page-aligned for mmap
    size_t prp_list_size_aligned = 
      (prp_list_size + host_page_size - 1) & ~(host_page_size - 1);
    
    // Allocate PRP list via kernel module (must be physically contiguous)
    // Allocate page-aligned size for mmap compatibility
    rocm_axiio_alloc_contig_mem_req prp_alloc_req = {};
    prp_alloc_req.size = prp_list_size_aligned;
    
    fprintf(stderr,
            "DEBUG: Allocating PRP list: size=%zu bytes (%zu entries), "
            "aligned=%zu\n",
            prp_list_size, num_pages, prp_list_size_aligned);
    
    int ret = ioctl(kmod_fd, ROCM_XIO_ALLOC_CONTIG_MEM, &prp_alloc_req);
    if (ret < 0) {
      fprintf(stderr,
              "ERROR: Failed to allocate PRP list memory: %s\n",
              strerror(errno));
      free(page_phys_addrs);
      return -errno;
    }
    
    fprintf(stderr,
            "DEBUG: PRP list allocated: virt=0x%016llx phys=0x%016llx "
            "size=%zu\n",
            (unsigned long long)prp_alloc_req.virt_addr,
            (unsigned long long)prp_alloc_req.phys_addr, prp_list_size_aligned);
    
    // Map PRP list to userspace
    // Kernel mmap handler expects vm_pgoff = phys_addr / PAGE_SIZE (in pages)
    // Ensure physical address is page-aligned (it should be from alloc_pages)
    if (prp_alloc_req.phys_addr % host_page_size != 0) {
      fprintf(stderr,
              "ERROR: PRP list physical address not page-aligned: 0x%016llx\n",
              (unsigned long long)prp_alloc_req.phys_addr);
      rocm_axiio_free_contig_mem_req free_req = {};
      free_req.virt_addr = prp_alloc_req.virt_addr;
      ioctl(kmod_fd, ROCM_XIO_FREE_CONTIG_MEM, &free_req);
      free(page_phys_addrs);
      return -EINVAL;
    }
    
    off_t mmap_offset = prp_alloc_req.phys_addr / host_page_size;
    fprintf(stderr,
            "DEBUG: PRP list mmap: phys=0x%016llx size=%zu offset=%ld "
            "(pages), kmod_fd=%d\n",
            (unsigned long long)prp_alloc_req.phys_addr, prp_list_size_aligned,
            (long)mmap_offset, kmod_fd);
    
    // Verify file descriptor is valid
    if (fcntl(kmod_fd, F_GETFD) < 0) {
      fprintf(stderr,
              "ERROR: Invalid file descriptor for mmap: %s\n",
              strerror(errno));
      rocm_axiio_free_contig_mem_req free_req = {};
      free_req.virt_addr = prp_alloc_req.virt_addr;
      ioctl(kmod_fd, ROCM_XIO_FREE_CONTIG_MEM, &free_req);
      free(page_phys_addrs);
      return -errno;
    }
    
    // Try mmap first, but if it fails, we'll use a workaround
    prp_list_virt = mmap(nullptr, prp_list_size_aligned, PROT_READ | PROT_WRITE,
                        MAP_SHARED, kmod_fd, mmap_offset);
    if (prp_list_virt == MAP_FAILED) {
      // mmap failed - this is a known issue with character devices
      // Workaround: Allocate PRP list in userspace and use its physical address
      // Note: This requires the PRP list to be in physically accessible memory
      fprintf(stderr,
              "WARNING: mmap failed for PRP list (this is expected for character "
              "devices). Using userspace allocation workaround.\n");
      
      // Allocate PRP list in userspace (must be page-aligned for physical address lookup)
      void* prp_list_userspace = aligned_alloc(host_page_size, prp_list_size_aligned);
      if (!prp_list_userspace) {
        fprintf(stderr,
                "ERROR: Failed to allocate PRP list in userspace: %s\n",
                strerror(errno));
        rocm_axiio_free_contig_mem_req free_req = {};
        free_req.virt_addr = prp_alloc_req.virt_addr;
        ioctl(kmod_fd, ROCM_XIO_FREE_CONTIG_MEM, &free_req);
        free(page_phys_addrs);
        return -ENOMEM;
      }
      
      // Zero-initialize the memory to ensure it's physically mapped
      // This is necessary because aligned_alloc may allocate memory that isn't
      // physically mapped until first access
      memset(prp_list_userspace, 0, prp_list_size_aligned);
      
      // Pin the memory to prevent swapping (required for DMA access)
      if (mlock(prp_list_userspace, prp_list_size_aligned) < 0) {
        fprintf(stderr,
                "WARNING: Failed to lock PRP list memory: %s (DMA may fail)\n",
                strerror(errno));
        // Continue anyway - some systems allow DMA without mlock
      }
      
      // Get physical address of userspace-allocated PRP list
      int pagemap_fd_prp = open("/proc/self/pagemap", O_RDONLY);
      if (pagemap_fd_prp < 0) {
        fprintf(stderr,
                "ERROR: Failed to open /proc/self/pagemap for PRP list: %s\n",
                strerror(errno));
        free(prp_list_userspace);
        rocm_axiio_free_contig_mem_req free_req = {};
        free_req.virt_addr = prp_alloc_req.virt_addr;
        ioctl(kmod_fd, ROCM_XIO_FREE_CONTIG_MEM, &free_req);
        free(page_phys_addrs);
        return -errno;
      }
      
      uint64_t prp_pfn;
      off_t prp_offset = (reinterpret_cast<uint64_t>(prp_list_userspace) /
                          host_page_size) * sizeof(uint64_t);
      if (lseek(pagemap_fd_prp, prp_offset, SEEK_SET) < 0 ||
          read(pagemap_fd_prp, &prp_pfn, sizeof(prp_pfn)) != sizeof(prp_pfn)) {
        fprintf(stderr,
                "ERROR: Failed to read pagemap for PRP list: %s\n",
                strerror(errno));
        close(pagemap_fd_prp);
        free(prp_list_userspace);
        rocm_axiio_free_contig_mem_req free_req = {};
        free_req.virt_addr = prp_alloc_req.virt_addr;
        ioctl(kmod_fd, ROCM_XIO_FREE_CONTIG_MEM, &free_req);
        free(page_phys_addrs);
        return -errno;
      }
      close(pagemap_fd_prp);
      
      if (!(prp_pfn & (1ULL << 63))) {
        fprintf(stderr,
                "ERROR: PRP list page not present in pagemap\n");
        free(prp_list_userspace);
        rocm_axiio_free_contig_mem_req free_req = {};
        free_req.virt_addr = prp_alloc_req.virt_addr;
        ioctl(kmod_fd, ROCM_XIO_FREE_CONTIG_MEM, &free_req);
        free(page_phys_addrs);
        return -EFAULT;
      }
      
      uint64_t prp_phys_pfn = prp_pfn & ((1ULL << 55) - 1);
      uint64_t prp_list_phys_userspace = prp_phys_pfn * host_page_size;
      
      // Free kernel-allocated PRP list (we'll use userspace one instead)
      rocm_axiio_free_contig_mem_req free_req = {};
      free_req.virt_addr = prp_alloc_req.virt_addr;
      ioctl(kmod_fd, ROCM_XIO_FREE_CONTIG_MEM, &free_req);
      
      // Use userspace-allocated PRP list
      prp_list_virt = prp_list_userspace;
      prp_list_phys = prp_list_phys_userspace;
      prp_list_kernel_virt = 0; // Mark as userspace-allocated
      
      fprintf(stderr,
              "DEBUG: Using userspace PRP list: virt=%p phys=0x%016llx\n",
              prp_list_virt, (unsigned long long)prp_list_phys);
    } else {
      // mmap succeeded - use kernel-allocated PRP list
      prp_list_phys = prp_alloc_req.phys_addr;
      prp_list_kernel_virt = prp_alloc_req.virt_addr;
    }
    
    // Fill PRP list with physical addresses (all page-aligned)
    // Only fill the actual number of entries needed, not the full aligned size
    uint64_t* prp_list = static_cast<uint64_t*>(prp_list_virt);
    for (size_t i = 0; i < num_pages; i++) {
      // Round down to page boundary for all entries
      prp_list[i] = page_phys_addrs[i] & ~(nvme_page_size - 1);
    }
    
    // Set PRP1 and PRP2 (prp_list_phys was set above in the mmap success/failure branches)
    prp1 = page_phys_addrs[0]; // First page (may have offset)
    prp2 = prp_list_phys; // PRP list address (either kernel or userspace)
    
    fprintf(stderr,
            "DEBUG: PRP list filled: %zu entries, PRP1=0x%016llx "
            "PRP2=0x%016llx\n",
            num_pages, (unsigned long long)prp1,
            (unsigned long long)prp2);
  }
  
  *prp_list_kernel_virt_out = prp_list_kernel_virt;
  
  *prp1_out = prp1;
  *prp2_out = prp2;
  *prp_list_virt_out = prp_list_virt;
  
  free(page_phys_addrs);
  return 0;
}

__host__ int nvme_ep::nvme_create_queue_via_ioctl(
  const char* nvme_device, const char* kernel_module_device, uint16_t queue_id,
  uint16_t queue_size, uint16_t nvme_bdf, unsigned memory_mode,
  struct nvme_queue_info* info) {
  // NOTE: We use manual CREATE_SQ/CREATE_CQ instead of libnvme APIs because:
  // 1. libnvme uses its own memory allocation (not GPU-accessible)
  // 2. We need GPU-accessible memory for device-side queue access
  // 3. We use custom kernel module integration for physical address mapping
  // libnvme is used only for status code helpers (nvme_status_to_string)
  // when USE_LIBNVME is defined.
  // Declare all variables at the top to avoid goto scoping issues
  int kmod_fd = -1;
  int nvme_fd = -1;
  int drm_fd = -1;
  int ret = 0;
  hipError_t sqe_err = hipSuccess;
  hipError_t cqe_err = hipSuccess;
  hipError_t sq_gpu_ptr_err = hipSuccess;
  hipError_t cq_gpu_ptr_err = hipSuccess;
  void* sq_virt = nullptr;
  void* cq_virt = nullptr;
  void* sq_gpu = nullptr;
  void* cq_gpu = nullptr;
  bool sq_uses_coherent = false; // Track if SQ was reallocated with coherent
  bool cq_uses_coherent = false; // Track if CQ was reallocated with coherent
  // Track if SQ/CQ were allocated via kernel module
  bool sq_uses_kernel_alloc = false;
  bool cq_uses_kernel_alloc = false;
  // Kernel virtual addresses for SQ/CQ (for freeing)
  uint64_t sq_kernel_virt_addr = 0;
  uint64_t cq_kernel_virt_addr = 0;
  bool sq_is_device = (memory_mode & 0x1) != 0; // Bit 0: GPU write location
  bool cq_is_device = (memory_mode & 0x2) != 0; // Bit 1: CPU write location
  int sq_dmabuf_fd = -1; // Not currently used, but kept for struct
                         // compatibility
  int cq_dmabuf_fd = -1; // Not currently used, but kept for struct
                         // compatibility
  uint64_t sq_phys = 0;
  uint64_t cq_phys = 0;
  uint64_t sq_prp1 = 0, sq_prp2 = 0; // PRP entries for SQ
  uint64_t cq_prp1 = 0, cq_prp2 = 0; // PRP entries for CQ
  void* sq_prp_list_virt = nullptr; // PRP list userspace virtual address for SQ
  void* cq_prp_list_virt = nullptr; // PRP list userspace virtual address for CQ
  uint64_t sq_prp_list_kernel_virt = 0; // PRP list kernel virtual address for SQ
  uint64_t cq_prp_list_kernel_virt = 0; // PRP list kernel virtual address for CQ
  struct nvme_passthru_cmd cmd;
  struct drm_amdgpu_gem_userptr sq_userptr = {};
  struct drm_amdgpu_gem_userptr cq_userptr = {};
  bool gpuWriteToDevice = (memory_mode & 0x1) != 0;
  bool cpuWriteToDevice = (memory_mode & 0x2) != 0;
  size_t page_size = 0;
  size_t sq_size_aligned = 0;
  size_t cq_size_aligned = 0;
  const size_t host_page_size = sysconf(_SC_PAGESIZE); // Declare early for goto

  if (!nvme_device || !kernel_module_device || !info) {
    return -EINVAL;
  }

  // Validate queue_size is power of 2 and non-zero
  // Note: uint16_t max is 65535, so no need to check upper bound
  if (queue_size == 0 || (queue_size & (queue_size - 1)) != 0) {
    return -EINVAL;
  }

  // Calculate queue sizes in bytes
  const size_t sq_size_bytes = queue_size * NVME_EP_SQE_SIZE;
  const size_t cq_size_bytes = queue_size * NVME_EP_CQE_SIZE;

  // Calculate page-aligned sizes for GEM_USERPTR (required for GPU access)
  page_size = sysconf(_SC_PAGESIZE);
  sq_size_aligned = ((sq_size_bytes + page_size - 1) / page_size) * page_size;
  cq_size_aligned = ((cq_size_bytes + page_size - 1) / page_size) * page_size;

  // Zero-initialize output structure
  memset(info, 0, sizeof(*info));
  info->sq_size = sq_size_bytes;
  info->cq_size = cq_size_bytes;
  info->queue_size = queue_size; // Store queue size in entries

  // Open kernel module device
  kmod_fd = open(kernel_module_device, O_RDWR);
  if (kmod_fd < 0) {
    fprintf(stderr, "Failed to open kernel module device %s: %s\n",
            kernel_module_device, strerror(errno));
    return -errno;
  }

  // Detect if NVMe device is emulated (QEMU) or passthrough
  bool is_emulated = false;
  int detect_ret = xioDetectEmulatedNvme(nvme_device, &is_emulated);
  if (detect_ret != 0) {
    fprintf(stderr, "Warning: Failed to detect NVMe type for %s: %s\n",
            nvme_device, strerror(-detect_ret));
    fprintf(stderr, "Defaulting to passthrough mode\n");
    is_emulated = false;
  }
  fprintf(stderr, "NVMe device %s detected as: %s\n", nvme_device,
          is_emulated ? "EMULATED" : "PASSTHROUGH");

  // Check controller capabilities for PC=0 support
  // QEMU emulated devices always require PC=1, but real hardware may support
  // PC=0. Check the CAP register's CQR bit to determine actual capability.
  bool supports_pc0 = false;
  bool use_pc1 = true; // Default to PC=1 (safer)
  if (!is_emulated) {
    // For passthrough devices, check CAP register CQR bit
    int cap_ret = nvme_ep_check_pc0_support(nvme_bdf, &supports_pc0);
    if (cap_ret == 0) {
      use_pc1 = !supports_pc0; // Use PC=1 if CQR=1 (PC=0 not supported)
    } else {
      fprintf(stderr,
              "Warning: Failed to read CAP register, defaulting to PC=1\n");
      use_pc1 = true; // Default to PC=1 on error
    }
  }
  // For emulated devices, always use PC=1 (QEMU requirement)

  // Open NVMe device (requires root permissions)
  nvme_fd = open(nvme_device, O_RDWR);
  if (nvme_fd < 0) {
    if (errno == EACCES || errno == EPERM) {
      fprintf(stderr, "Failed to open NVMe device %s: %s\n", nvme_device,
              strerror(errno));
      fprintf(stderr, "Note: NVMe device access requires root permissions.\n");
      fprintf(stderr,
              "Please run with sudo or ensure your user has access to %s\n",
              nvme_device);
    } else {
      fprintf(stderr, "Failed to open NVMe device %s: %s\n", nvme_device,
              strerror(errno));
    }
    close(kmod_fd);
    return -errno;
  }

  // Allocate SQ buffer based on memory mode (like test-ep)
  // Bit 0 (LSB): GPU write location (SQE) - 0=host, 1=device
  sqe_err = xioAllocateSubmissionQueue(sq_size_bytes, memory_mode, &sq_virt);
  if (sqe_err != hipSuccess) {
    fprintf(stderr, "Failed to allocate SQ buffer: %s\n",
            hipGetErrorString(sqe_err));
    ret = -ENOMEM;
    goto cleanup;
  }

  // Allocate CQ buffer based on memory mode (like test-ep)
  // Bit 1: CPU write location (CQE) - 0=host, 1=device
  cqe_err = xioAllocateCompletionQueue(cq_size_bytes, memory_mode, &cq_virt);
  if (cqe_err != hipSuccess) {
    fprintf(stderr, "Failed to allocate CQ buffer: %s\n",
            hipGetErrorString(cqe_err));
    // Free SQ on failure
    xioFreeSubmissionQueue(sq_virt, memory_mode);
    ret = -ENOMEM;
    goto cleanup;
  }

  // Zero-initialize queues
  // For host memory (mmap), use memset directly
  // For device memory (HSA), we need to use hipMemset or
  // hsa_memory_assign_agent
  if (gpuWriteToDevice) {
    // Device memory allocated via HSA - use hipMemset if pointer is
    // GPU-accessible Note: HSA-allocated memory may need special handling
    memset(sq_virt, 0,
           sq_size_bytes); // HSA fine-grained memory is host-accessible
  } else {
    // Host memory (malloc) - use memset
    memset(sq_virt, 0, sq_size_bytes);
  }

  if (cpuWriteToDevice) {
    // Device memory allocated via HSA
    memset(cq_virt, 0,
           cq_size_bytes); // HSA fine-grained memory is host-accessible
    // Ensure memset is visible to GPU before kernel launch
    // Use memory barrier to ensure writes complete
    __sync_synchronize();
  } else {
    // Host memory (malloc) - use memset
    memset(cq_virt, 0, cq_size_bytes);
    // Ensure memset is visible to GPU before kernel launch
    __sync_synchronize();
  }
  
  // Verify CQ is zeroed (sanity check - helps catch allocation issues)
  // Check first few entries to ensure memset worked
  // Use block scope to avoid goto jump issues
  {
    volatile struct nvme_cqe* cq_check = static_cast<volatile struct nvme_cqe*>(cq_virt);
    for (uint16_t i = 0; i < queue_size && i < 4; i++) {
      nvme_ep::cqeType cqe_check = nvme_ep::cqeRead(
        reinterpret_cast<volatile nvme_ep::cqeType*>(&cq_check[i]));
      if (cqe_check.command_id != 0 || cqe_check.status != 0 || 
          cqe_check.sq_head != 0) {
        fprintf(stderr, "WARNING: CQ entry %u not properly zeroed: "
                "cmd_id=%u status=0x%04x sq_head=%u\n",
                i, cqe_check.command_id, cqe_check.status, cqe_check.sq_head);
      }
    }
  }

  // For non-contiguous queues (PC=0), we don't need kernel allocation
  // Regular memory allocations work fine since physical contiguity is not required
  // We'll get physical addresses via /proc/self/pagemap for PRP list generation
  // Skip kernel allocation for non-contiguous queues
  if (false && !gpuWriteToDevice) { // Disabled for PC=0 (non-contiguous queues)
    rocm_axiio_alloc_contig_mem_req alloc_req = {};
    alloc_req.size = sq_size_bytes;
    
    // Allocate contiguous memory via kernel module IOCTL
    ret = ioctl(kmod_fd, ROCM_XIO_ALLOC_CONTIG_MEM, &alloc_req);
    if (ret < 0) {
      fprintf(stderr,
              "ERROR: Failed to allocate contiguous SQ memory via kernel "
              "module: %s\n",
              strerror(errno));
      fprintf(stderr,
              "Queue size: %zu bytes. System may not have enough contiguous "
              "physical memory.\n",
              sq_size_bytes);
      ret = -errno;
      goto cleanup;
    }
    
    // Map physical memory to userspace via mmap
    // Use physical address divided by page size as the offset (handle)
    const size_t host_page_size = sysconf(_SC_PAGESIZE);
    off_t mmap_offset = alloc_req.phys_addr / host_page_size;
    fprintf(stderr,
            "DEBUG: Attempting mmap: virt_addr=0x%016llx phys_addr=0x%016llx "
            "page_size=%zu offset=%lld (0x%016llx) size=%zu\n",
            (unsigned long long)alloc_req.virt_addr,
            (unsigned long long)alloc_req.phys_addr, host_page_size,
            (long long)mmap_offset, (unsigned long long)mmap_offset,
            sq_size_bytes);
    void* sq_virt_mapped = mmap(nullptr, sq_size_bytes, PROT_READ | PROT_WRITE,
                                MAP_SHARED, kmod_fd, mmap_offset);
    if (sq_virt_mapped == MAP_FAILED) {
      fprintf(stderr,
              "ERROR: Failed to mmap contiguous SQ memory: %s (errno=%d)\n",
              strerror(errno), errno);
      // Free the kernel allocation
      rocm_axiio_free_contig_mem_req free_req = {};
      free_req.virt_addr = alloc_req.virt_addr;
      ioctl(kmod_fd, ROCM_XIO_FREE_CONTIG_MEM, &free_req);
      ret = -errno;
      goto cleanup;
    }
    
    // Zero the memory (alloc_pages with __GFP_ZERO should zero it, but be safe)
    memset(sq_virt_mapped, 0, sq_size_bytes);
    
    // Copy data from original allocation if needed (only if original exists)
    if (sq_virt != nullptr) {
      memcpy(sq_virt_mapped, sq_virt, sq_size_bytes);
      // Free original allocation (may be hipHostMalloc or malloc)
      hipError_t freeErr = hipHostFree(sq_virt);
      if (freeErr != hipSuccess) {
        // Not HIP-allocated, use regular free
        free(sq_virt);
      }
      sq_virt = nullptr; // Clear pointer to avoid double-free
    }
    
    sq_virt = sq_virt_mapped;
    sq_phys = alloc_req.phys_addr;
    sq_uses_coherent = true; // Mark that SQ uses coherent memory
    sq_uses_kernel_alloc = true; // Mark that SQ was allocated via kernel module
    sq_kernel_virt_addr = alloc_req.virt_addr; // Save kernel virt addr for cleanup
    
    fprintf(stderr,
            "SQ: Allocated %zu bytes of contiguous memory via kernel module: "
            "virt=0x%016llx phys=0x%016llx\n",
            sq_size_bytes, (unsigned long long)sq_virt,
            (unsigned long long)sq_phys);
  }

  // For non-contiguous queues (PC=0), skip kernel allocation
  if (false && !cpuWriteToDevice) { // Disabled for PC=0 (non-contiguous queues)
    rocm_axiio_alloc_contig_mem_req alloc_req = {};
    alloc_req.size = cq_size_bytes;
    
    // Allocate contiguous memory via kernel module IOCTL
    ret = ioctl(kmod_fd, ROCM_XIO_ALLOC_CONTIG_MEM, &alloc_req);
    if (ret < 0) {
      fprintf(stderr,
              "ERROR: Failed to allocate contiguous CQ memory via kernel "
              "module: %s\n",
              strerror(errno));
      fprintf(stderr,
              "Queue size: %zu bytes. System may not have enough contiguous "
              "physical memory.\n",
              cq_size_bytes);
      ret = -errno;
      goto cleanup;
    }
    
    // Map physical memory to userspace via mmap
    // Use physical address divided by page size as the offset (handle)
    const size_t host_page_size = sysconf(_SC_PAGESIZE);
    off_t mmap_offset = alloc_req.phys_addr / host_page_size;
    void* cq_virt_mapped = mmap(nullptr, cq_size_bytes, PROT_READ | PROT_WRITE,
                                MAP_SHARED, kmod_fd, mmap_offset);
    if (cq_virt_mapped == MAP_FAILED) {
      fprintf(stderr,
              "ERROR: Failed to mmap contiguous CQ memory: %s\n",
              strerror(errno));
      // Free the kernel allocation
      rocm_axiio_free_contig_mem_req free_req = {};
      free_req.virt_addr = alloc_req.virt_addr;
      ioctl(kmod_fd, ROCM_XIO_FREE_CONTIG_MEM, &free_req);
      ret = -errno;
      goto cleanup;
    }
    
    // Zero the memory (alloc_pages with __GFP_ZERO should zero it, but be safe)
    memset(cq_virt_mapped, 0, cq_size_bytes);
    
    // Copy data from original allocation if needed (only if original exists)
    if (cq_virt != nullptr) {
      memcpy(cq_virt_mapped, cq_virt, cq_size_bytes);
      // Free original allocation (may be hipHostMalloc or malloc)
      hipError_t freeErr = hipHostFree(cq_virt);
      if (freeErr != hipSuccess) {
        // Not HIP-allocated, use regular free
        free(cq_virt);
      }
      cq_virt = nullptr; // Clear pointer to avoid double-free
    }
    
    cq_virt = cq_virt_mapped;
    cq_phys = alloc_req.phys_addr;
    cq_uses_coherent = true; // Mark that CQ uses coherent memory
    cq_uses_kernel_alloc = true; // Mark that CQ was allocated via kernel module
    cq_kernel_virt_addr = alloc_req.virt_addr; // Save kernel virt addr for cleanup
    
    fprintf(stderr,
            "CQ: Allocated %zu bytes of contiguous memory via kernel module: "
            "virt=0x%016llx phys=0x%016llx\n",
            cq_size_bytes, (unsigned long long)cq_virt,
            (unsigned long long)cq_phys);
  }

  // Register queues with GPU (matching test-gpu-nvme-write.cpp pattern)
  // Step 1: DRM GEM_USERPTR registration (required for GPU access to host
  // memory)
  // Note: For device memory (hipMalloc), queues are already GPU-accessible,
  // so GEM_USERPTR is optional but we do it anyway for consistency
  // GEM_USERPTR requires page-aligned sizes (already calculated above)

  drm_fd = open("/dev/dri/renderD128", O_RDWR);
  if (drm_fd < 0) {
    fprintf(stderr, "Warning: Failed to open DRM device: %s\n",
            strerror(errno));
    fprintf(stderr, "Cannot register queues with GPU via GEM_USERPTR.\n");
    // For device memory, this is not fatal - queues are already GPU-accessible
    if (sq_is_device && cq_is_device) {
      fprintf(stderr, "Note: Device memory queues are already GPU-accessible, "
                      "continuing without GEM_USERPTR\n");
      drm_fd = -1; // Mark as not opened
    } else {
      ret = -errno;
      goto cleanup;
    }
  } else {
    // Register SQ with DRM GEM_USERPTR (if DRM fd opened successfully)
    sq_userptr.addr = (uint64_t)sq_virt;
    sq_userptr.size = sq_size_aligned; // Use page-aligned size
    sq_userptr.flags = AMDGPU_GEM_USERPTR_REGISTER;

    if (ioctl(drm_fd, DRM_IOCTL_AMDGPU_GEM_USERPTR, &sq_userptr) < 0) {
      fprintf(stderr,
              "Warning: DRM_IOCTL_AMDGPU_GEM_USERPTR failed for SQ: %s\n",
              strerror(errno));
      // For device memory, this is not fatal
      if (sq_is_device) {
        fprintf(stderr, "Note: SQ is device memory (already GPU-accessible), "
                        "continuing without GEM_USERPTR\n");
      } else {
        fprintf(stderr, "Cannot register SQ with GPU.\n");
        close(drm_fd);
        ret = -errno;
        goto cleanup;
      }
    } else {
      fprintf(stderr, "SQ registered with DRM GEM_USERPTR (handle: %u)\n",
              sq_userptr.handle);
    }

    // Register CQ with DRM GEM_USERPTR
    cq_userptr.addr = (uint64_t)cq_virt;
    cq_userptr.size = cq_size_aligned; // Use page-aligned size
    cq_userptr.flags = AMDGPU_GEM_USERPTR_REGISTER;

    if (ioctl(drm_fd, DRM_IOCTL_AMDGPU_GEM_USERPTR, &cq_userptr) < 0) {
      fprintf(stderr,
              "Warning: DRM_IOCTL_AMDGPU_GEM_USERPTR failed for CQ: %s\n",
              strerror(errno));
      // For device memory, this is not fatal
      if (cq_is_device) {
        fprintf(stderr, "Note: CQ is device memory (already GPU-accessible), "
                        "continuing without GEM_USERPTR\n");
      } else {
        fprintf(stderr, "Cannot register CQ with GPU.\n");
        if (sq_userptr.handle != 0) {
          // Try to unregister SQ if it was registered
          // (Note: There's no unregister call, but closing drm_fd should handle
          // it)
        }
        close(drm_fd);
        ret = -errno;
        goto cleanup;
      }
    } else {
      fprintf(stderr, "CQ registered with DRM GEM_USERPTR (handle: %u)\n",
              cq_userptr.handle);
    }
  }

  // Step 2: Get GPU pointers for HIP-allocated memory
  // Memory allocated via xioAllocateSubmissionQueue/xioAllocateCompletionQueue
  // uses hipHostMalloc with hipHostMallocMapped, which already makes it
  // GPU-accessible. We just need to get the device pointer.
  // Skip if:
  // 1. Memory was allocated with kernel module (not HIP-allocated)
  // 2. Memory is device memory (allocated via HSA, already GPU-accessible)
  // Note: hipHostMalloc memory doesn't need hipHostRegister - it's already registered

  // Step 3: Get GPU pointers (matching test-gpu-nvme-write.cpp pattern)
  // For device memory (hipMalloc), GPU pointer is same as host pointer
  // For host memory (hipHostMalloc with hipHostMallocMapped), get device pointer
  if (sq_is_device) {
    // Device memory - GPU pointer is same as host pointer
    sq_gpu = sq_virt;
    sq_gpu_ptr_err = hipSuccess;
  } else if (sq_uses_kernel_alloc) {
    // Kernel-allocated memory - not GPU-accessible, use host pointer
    sq_gpu = sq_virt;
    sq_gpu_ptr_err = hipSuccess;
  } else {
    // Host memory allocated via hipHostMalloc (with hipHostMallocMapped)
    // Get GPU pointer directly - no need to register first
    sq_gpu_ptr_err = hipHostGetDevicePointer(&sq_gpu, sq_virt, 0);
    if (sq_gpu_ptr_err != hipSuccess) {
      fprintf(stderr, "Warning: hipHostGetDevicePointer failed for SQ: %s\n",
              hipGetErrorString(sq_gpu_ptr_err));
      // Fall back to using host pointer
      sq_gpu = sq_virt;
    }
  }

  if (cq_is_device) {
    // Device memory - GPU pointer is same as host pointer
    cq_gpu = cq_virt;
    cq_gpu_ptr_err = hipSuccess;
  } else if (cq_uses_kernel_alloc) {
    // Kernel-allocated memory - not GPU-accessible, use host pointer
    cq_gpu = cq_virt;
    cq_gpu_ptr_err = hipSuccess;
  } else {
    // Host memory allocated via hipHostMalloc (with hipHostMallocMapped)
    // Get GPU pointer directly - no need to register first
    cq_gpu_ptr_err = hipHostGetDevicePointer(&cq_gpu, cq_virt, 0);
    if (cq_gpu_ptr_err != hipSuccess) {
      fprintf(stderr, "Warning: hipHostGetDevicePointer failed for CQ: %s\n",
              hipGetErrorString(cq_gpu_ptr_err));
      // Fall back to using host pointer
      cq_gpu = cq_virt;
    }
  }

  fprintf(stderr,
          "Queues registered with GPU: SQ=%p (host=%p), CQ=%p (host=%p)\n",
          sq_gpu, sq_virt, cq_gpu, cq_virt);

  // Keep drm_fd open for the mappings to remain valid
  // Note: In a production system, you might want to track this fd
  // The kernel will clean it up when the process exits
  // We close it here but set to -1 so cleanup doesn't try to close again
  close(drm_fd);
  drm_fd = -1;

  // Get dmabuf file descriptors for the buffers
  // Note: This requires HIP extension or manual dmabuf export
  // For now, we'll use a placeholder approach - in practice, you may need
  // to use hipMemGetInfo or a HIP extension to get dmabuf FDs
  // TODO: Get actual dmabuf FDs from HIP buffers
  // This is platform-specific and may require HIP extensions
  // For now, we'll assume the kernel module can handle virtual addresses
  // directly, or we need to implement dmabuf export separately

  // Get physical addresses based on memory mode
  // Memory mode 0 (host memory): Use /proc/self/pagemap (like QEMU guest code)
  // Memory mode with bits set (device memory): Use dmabuf FDs and kernel module
  // IOCTL

  if (gpuWriteToDevice) {
    // Device memory (HSA) - export as DMA-BUF and get physical address
    // Similar to VRAM buffer export - need page alignment
    const size_t host_page_size = sysconf(_SC_PAGESIZE);
    void* aligned_sq_ptr = (void*)((uintptr_t)sq_virt & ~(host_page_size - 1));
    uint64_t sq_dmabuf_offset = (uintptr_t)sq_virt - (uintptr_t)aligned_sq_ptr;
    size_t aligned_sq_size = (sq_size_bytes + sq_dmabuf_offset +
                              host_page_size - 1) &
                             ~(host_page_size - 1);

    int sq_dmabuf_fd = -1;
    hsa_status_t sq_dmabuf_status = hsa_amd_portable_export_dmabuf(
      aligned_sq_ptr, aligned_sq_size, &sq_dmabuf_fd, &sq_dmabuf_offset);
    if (sq_dmabuf_status != HSA_STATUS_SUCCESS) {
      fprintf(stderr, "ERROR: Failed to export SQ as DMA-BUF (status=%d): %s\n",
              sq_dmabuf_status,
              (sq_dmabuf_status == HSA_STATUS_ERROR_INVALID_ARGUMENT)
                ? "Invalid argument"
                : "Unknown error");
      fprintf(stderr, "Device memory queues require DMA-BUF export support.\n");
      ret = -ENOTSUP;
      goto cleanup;
    }

    // Get physical address via kernel module
    rocm_axiio_register_buffer_req buf_req = {};
    buf_req.dmabuf_fd = sq_dmabuf_fd;
    buf_req.virt_addr = reinterpret_cast<uint64_t>(sq_virt);
    buf_req.size = sq_size_bytes;
    buf_req.nvme_bdf = nvme_bdf;
    buf_req.flags = is_emulated ? ROCM_XIO_FLAG_EMULATED
                                : ROCM_XIO_FLAG_PASSTHROUGH;
    fprintf(stderr, "SQ registration: is_emulated=%d, flags=0x%x\n",
            is_emulated, buf_req.flags);

    ret = ioctl(kmod_fd, ROCM_XIO_REGISTER_BUFFER, &buf_req);
    close(sq_dmabuf_fd); // Close FD after kernel module has it
    if (ret < 0) {
      fprintf(stderr,
              "ERROR: Failed to get SQ physical address via kernel module: "
              "%s\n",
              strerror(errno));
      ret = -errno;
      goto cleanup;
    }
    sq_phys = buf_req.phys_addr + sq_dmabuf_offset;
    fprintf(stderr,
            "SQ device memory: virt=0x%016llx, phys=0x%016llx (via DMA-BUF)\n",
            (unsigned long long)reinterpret_cast<uint64_t>(sq_virt),
            (unsigned long long)sq_phys);
  } else {
    // Host memory (mmap) - use /proc/self/pagemap to get physical address
    // For non-contiguous queues (PC=0), we only need the first page's physical
    // address. The PRP list generation will handle all pages (contiguous or not).
    int pagemap_fd = open("/proc/self/pagemap", O_RDONLY);
    if (pagemap_fd < 0) {
      fprintf(stderr, "Warning: Failed to open /proc/self/pagemap: %s\n",
              strerror(errno));
      fprintf(stderr, "Using virtual address as physical address for SQ\n");
      sq_phys = reinterpret_cast<uint64_t>(sq_virt);
    } else {
      const size_t host_page_size = sysconf(_SC_PAGESIZE);
      uint64_t page_offset = reinterpret_cast<uint64_t>(sq_virt) % host_page_size;
      uint64_t first_pfn = 0;
      
      // Read first page to get base physical address
      off_t first_offset = (reinterpret_cast<uint64_t>(sq_virt) /
                             host_page_size) * sizeof(uint64_t);
      
      if (lseek(pagemap_fd, first_offset, SEEK_SET) >= 0 &&
          read(pagemap_fd, &first_pfn, sizeof(first_pfn)) ==
              sizeof(first_pfn)) {
        if (first_pfn & (1ULL << 63)) {
          uint64_t first_phys_pfn = first_pfn & ((1ULL << 55) - 1);
          sq_phys = (first_phys_pfn * host_page_size) + page_offset;
        } else {
          fprintf(stderr,
                  "Warning: SQ page not present in pagemap, using virtual "
                  "address\n");
          sq_phys = reinterpret_cast<uint64_t>(sq_virt);
        }
      } else {
        fprintf(stderr,
                "Warning: Failed to read pagemap for SQ, using virtual "
                "address\n");
        sq_phys = reinterpret_cast<uint64_t>(sq_virt);
      }
      close(pagemap_fd);
    }
  }

  if (cpuWriteToDevice) {
    // Device memory (HSA) - export as DMA-BUF and get physical address
    // Similar to VRAM buffer export - need page alignment
    const size_t host_page_size = sysconf(_SC_PAGESIZE);
    void* aligned_cq_ptr = (void*)((uintptr_t)cq_virt & ~(host_page_size - 1));
    uint64_t cq_dmabuf_offset = (uintptr_t)cq_virt - (uintptr_t)aligned_cq_ptr;
    size_t aligned_cq_size = (cq_size_bytes + cq_dmabuf_offset +
                              host_page_size - 1) &
                             ~(host_page_size - 1);

    int cq_dmabuf_fd = -1;
    hsa_status_t cq_dmabuf_status = hsa_amd_portable_export_dmabuf(
      aligned_cq_ptr, aligned_cq_size, &cq_dmabuf_fd, &cq_dmabuf_offset);
    if (cq_dmabuf_status != HSA_STATUS_SUCCESS) {
      fprintf(stderr, "ERROR: Failed to export CQ as DMA-BUF (status=%d): %s\n",
              cq_dmabuf_status,
              (cq_dmabuf_status == HSA_STATUS_ERROR_INVALID_ARGUMENT)
                ? "Invalid argument"
                : "Unknown error");
      fprintf(stderr, "Device memory queues require DMA-BUF export support.\n");
      ret = -ENOTSUP;
      goto cleanup;
    }

    // Get physical address via kernel module
    rocm_axiio_register_buffer_req buf_req = {};
    buf_req.dmabuf_fd = cq_dmabuf_fd;
    buf_req.virt_addr = reinterpret_cast<uint64_t>(cq_virt);
    buf_req.size = cq_size_bytes;
    buf_req.nvme_bdf = nvme_bdf;
    buf_req.flags = is_emulated ? ROCM_XIO_FLAG_EMULATED
                                : ROCM_XIO_FLAG_PASSTHROUGH;
    fprintf(stderr, "CQ registration: is_emulated=%d, flags=0x%x\n",
            is_emulated, buf_req.flags);

    ret = ioctl(kmod_fd, ROCM_XIO_REGISTER_BUFFER, &buf_req);
    close(cq_dmabuf_fd); // Close FD after kernel module has it
    if (ret < 0) {
      fprintf(stderr,
              "ERROR: Failed to get CQ physical address via kernel module: "
              "%s\n",
              strerror(errno));
      ret = -errno;
      goto cleanup;
    }
    cq_phys = buf_req.phys_addr + cq_dmabuf_offset;
    fprintf(stderr,
            "CQ device memory: virt=0x%016llx, phys=0x%016llx (via DMA-BUF)\n",
            (unsigned long long)reinterpret_cast<uint64_t>(cq_virt),
            (unsigned long long)cq_phys);
  } else {
    // Host memory (mmap) - use /proc/self/pagemap
    // For non-contiguous queues (PC=0), we only need the first page's physical
    // address. The PRP list generation will handle all pages (contiguous or not).
    int pagemap_fd = open("/proc/self/pagemap", O_RDONLY);
    if (pagemap_fd < 0) {
      fprintf(stderr, "Warning: Failed to open /proc/self/pagemap: %s\n",
              strerror(errno));
      fprintf(stderr, "Using virtual address as physical address for CQ\n");
      cq_phys = reinterpret_cast<uint64_t>(cq_virt);
    } else {
      const size_t host_page_size = sysconf(_SC_PAGESIZE);
      uint64_t page_offset = reinterpret_cast<uint64_t>(cq_virt) % host_page_size;
      uint64_t first_pfn = 0;
      
      // Read first page to get base physical address
      off_t first_offset = (reinterpret_cast<uint64_t>(cq_virt) /
                             host_page_size) * sizeof(uint64_t);
      
      if (lseek(pagemap_fd, first_offset, SEEK_SET) >= 0 &&
          read(pagemap_fd, &first_pfn, sizeof(first_pfn)) ==
              sizeof(first_pfn)) {
        if (first_pfn & (1ULL << 63)) {
          uint64_t first_phys_pfn = first_pfn & ((1ULL << 55) - 1);
          cq_phys = (first_phys_pfn * host_page_size) + page_offset;
        } else {
          fprintf(stderr,
                  "Warning: CQ page not present in pagemap, using virtual "
                  "address\n");
          cq_phys = reinterpret_cast<uint64_t>(cq_virt);
        }
      } else {
        fprintf(stderr,
                "Warning: Failed to read pagemap for CQ, using virtual "
                "address\n");
        cq_phys = reinterpret_cast<uint64_t>(cq_virt);
      }
      close(pagemap_fd);
    }
  }

  // Register queue addresses with kernel module for kprobe injection
  // Note: For device memory queues, ROCM_XIO_REGISTER_BUFFER was already
  // called above to map the DMA-BUF. This registration is for kprobe tracking
  // and works for both host and device memory queues.
  rocm_axiio_register_queue_addr_req reg_req;

  // Register SQ
  memset(&reg_req, 0, sizeof(reg_req));
  reg_req.virt_addr = reinterpret_cast<uint64_t>(sq_virt);
  reg_req.phys_addr = sq_phys;
  reg_req.size = sq_size_bytes;
  reg_req.queue_type = 0; // SQ

  ret = ioctl(kmod_fd, ROCM_XIO_REGISTER_QUEUE_ADDR, &reg_req);
  if (ret < 0) {
    fprintf(stderr, "Failed to register SQ address: %s\n", strerror(errno));
    ret = -errno;
    goto cleanup;
  }

  // Register CQ
  memset(&reg_req, 0, sizeof(reg_req));
  reg_req.virt_addr = reinterpret_cast<uint64_t>(cq_virt);
  reg_req.phys_addr = cq_phys;
  reg_req.size = cq_size_bytes;
  reg_req.queue_type = 1; // CQ

  ret = ioctl(kmod_fd, ROCM_XIO_REGISTER_QUEUE_ADDR, &reg_req);
  if (ret < 0) {
    fprintf(stderr, "Failed to register CQ address: %s\n", strerror(errno));
    ret = -errno;
    goto cleanup;
  }

  // Generate PRP lists for non-contiguous queues (PC=0)
  // PRP lists are only needed if queue spans more than one page
  if (sq_size_bytes > host_page_size) {
    ret = generate_prp_list_for_queue(sq_virt, sq_size_bytes, kmod_fd, sq_phys,
                                      &sq_prp1, &sq_prp2, &sq_prp_list_virt,
                                      &sq_prp_list_kernel_virt);
    if (ret < 0) {
      fprintf(stderr, "ERROR: Failed to generate PRP list for SQ: %s\n",
              strerror(-ret));
      goto cleanup;
    }
    fprintf(stderr, "SQ PRP: PRP1=0x%016llx PRP2=0x%016llx\n",
            (unsigned long long)sq_prp1, (unsigned long long)sq_prp2);
  } else {
    // Single page: PRP1 = physical address, PRP2 = 0
    sq_prp1 = sq_phys;
    sq_prp2 = 0;
    fprintf(stderr, "SQ fits in single page: PRP1=0x%016llx PRP2=0\n",
            (unsigned long long)sq_prp1);
  }

  if (cq_size_bytes > host_page_size) {
    ret = generate_prp_list_for_queue(cq_virt, cq_size_bytes, kmod_fd, cq_phys,
                                      &cq_prp1, &cq_prp2, &cq_prp_list_virt,
                                      &cq_prp_list_kernel_virt);
    if (ret < 0) {
      fprintf(stderr, "ERROR: Failed to generate PRP list for CQ: %s\n",
              strerror(-ret));
      goto cleanup;
    }
    fprintf(stderr, "CQ PRP: PRP1=0x%016llx PRP2=0x%016llx\n",
            (unsigned long long)cq_prp1, (unsigned long long)cq_prp2);
  } else {
    // Single page: PRP1 = physical address, PRP2 = 0
    cq_prp1 = cq_phys;
    cq_prp2 = 0;
    fprintf(stderr, "CQ fits in single page: PRP1=0x%016llx PRP2=0\n",
            (unsigned long long)cq_prp1);
  }

  // Delete existing queues if they exist (ignore errors - queue may not exist)
  // Delete SQ first, then CQ (NVMe spec requirement: CQ cannot be deleted
  // while associated SQ exists)

  // Delete Submission Queue (DELETE_SQ)
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_delete_sq;
  cmd.nsid = 0;         // Admin commands use NSID 0
  cmd.cdw10 = queue_id; // QID
  cmd.data_len = 0;     // No data transfer for DELETE_SQ

  ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret < 0) {
    // Ignore errors - queue may not exist
    fprintf(stderr, "Note: DELETE_SQ failed (queue may not exist): %s\n",
            strerror(errno));
  } else if (cmd.result & 0xFFFE) {
    // Check status code, but don't fail - queue may not exist
    uint16_t status_field = cmd.result & 0xFFFF;
    uint8_t sc = NVME_CQE_STATUS_SC(status_field);
    // Ignore errors - queue may not exist or may have already been deleted
    fprintf(
      stderr,
      "Note: DELETE_SQ returned status code 0x%02x (queue may not exist)\n",
      sc);
  }

  // Delete Completion Queue (DELETE_CQ)
  memset(&cmd, 0, sizeof(cmd));
  cmd.opcode = nvme_admin_delete_cq;
  cmd.nsid = 0;         // Admin commands use NSID 0
  cmd.cdw10 = queue_id; // QID
  cmd.data_len = 0;     // No data transfer for DELETE_CQ

  ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret < 0) {
    // Ignore errors - queue may not exist
    fprintf(stderr, "Note: DELETE_CQ failed (queue may not exist): %s\n",
            strerror(errno));
  } else if (cmd.result & 0xFFFE) {
    // Check status code, but don't fail - queue may not exist
    uint16_t status_field = cmd.result & 0xFFFF;
    uint8_t sc = NVME_CQE_STATUS_SC(status_field);
    // Ignore errors - queue may not exist or may have already been deleted
    fprintf(
      stderr,
      "Note: DELETE_CQ returned status code 0x%02x (queue may not exist)\n",
      sc);
  }

  // Create Completion Queue first (CREATE_CQ)
  memset(&cmd, 0, sizeof(cmd));

  cmd.opcode = nvme_admin_create_cq;
  cmd.nsid = 0;                                  // Admin commands use NSID 0
  cmd.cdw10 = (queue_size - 1) << 16 | queue_id; // QSIZE | QID
  // Set IEN based on emulated vs passthrough:
  // - Emulated (QEMU): IEN=1 required
  //   QEMU's nvme_create_cq() validates NVME_CQ_FLAGS_PC(qflags) at line 4698
  //   of hw/nvme/ctrl.c. While the NVMe spec defines bit 0 as IEN (not PC),
  //   QEMU's implementation requires bit 0=1 (IEN=1) for emulated devices.
  //   This is a QEMU implementation limitation/simplification.
  // - Passthrough: IEN=0 (interrupts disabled, polling mode)
  //   Real hardware may support polling mode (IEN=0) for better performance
  //   in high-throughput scenarios. Note: We don't check controller capabilities
  //   for IEN support - if IEN=0 fails, the controller will return an error.
  // cdw11 format: bits 15:1 = IV (Interrupt Vector), bit 0 = IEN
  cmd.cdw11 = is_emulated ? 0x00000001 : 0x00000000;
  // For non-contiguous queues, pass PRP1 via addr field
  // The kprobe will inject PRP1, and we'll need to handle PRP2 separately
  // For now, pass PRP1 directly - kprobe injection will be updated to handle PRP lists
  cmd.addr = cq_prp1; // PRP1 for non-contiguous queue
  cmd.data_len = 0; // No data transfer for CREATE_CQ
  // TODO: Update kernel kprobe to inject PRP2 for non-contiguous queues

  // Debug: Print what we're sending to the controller
  fprintf(stderr, "CREATE_CQ: queue_id=%u, queue_size=%u, cdw10=0x%08x "
                  "(QSIZE-1=0x%04x in bits 31:16, QID=0x%04x in bits 15:0)\n",
          queue_id, queue_size, cmd.cdw10, (queue_size - 1), queue_id);
  fprintf(stderr, "  Buffer address: virt=0x%016llx, size=%zu bytes "
                  "(%u entries * %u bytes/entry)\n",
          (unsigned long long)reinterpret_cast<uint64_t>(cq_virt),
          cq_size_bytes, queue_size, NVME_EP_CQE_SIZE);

  ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret < 0) {
    if (errno == EACCES || errno == EPERM) {
      fprintf(stderr, "ERROR: Failed to create completion queue: %s\n",
              strerror(errno));
      fprintf(stderr, "Note: CREATE_CQ IOCTL requires root permissions.\n");
      fprintf(
        stderr,
        "Please ensure you have CAP_SYS_ADMIN capability or run with sudo.\n");
    } else {
      fprintf(stderr, "ERROR: Failed to create completion queue: %s\n",
              strerror(errno));
    }
    fprintf(stderr, "ERROR: Cannot proceed - queue creation failed.\n");
    ret = -errno;
    goto cleanup;
  }

  // Check completion status
  // result field contains NVMe status code in lower 16 bits:
  //   Bits 15:1 = Status Code (SC)
  //   Bit 0 = Phase Tag (P)
  // Check if status code is non-zero (any error)
  if (cmd.result & 0xFFFE) {
    uint16_t status_field = cmd.result & 0xFFFF;
    uint8_t sc = NVME_CQE_STATUS_SC(status_field);
    uint8_t sct = NVME_CQE_STATUS_SCT(status_field);
#ifdef USE_LIBNVME
    const char* sc_str = nvme_status_to_string(sc, sct);
    fprintf(stderr,
            "ERROR: CREATE_CQ failed with status code 0x%02x (SCT=%u): %s\n",
            sc, sct, sc_str ? sc_str : "Unknown");
#else
    fprintf(stderr,
            "ERROR: CREATE_CQ failed with status code 0x%02x (SCT=%u)\n", sc,
            sct);
#endif
    if (sc == NVME_SC_INVALID_FIELD) {
      fprintf(
        stderr,
        "  Error: Invalid field in command (queue_id=%u, queue_size=%u)\n",
        queue_id, queue_size);
    } else if (sc == NVME_SC_CAP_EXCEEDED) {
      fprintf(
        stderr,
        "  Error: Queue size exceeds controller capabilities (queue_size=%u)\n",
        queue_size);
    }
    fprintf(stderr, "ERROR: Cannot proceed - queue creation failed.\n");
    ret = -EIO;
    goto cleanup;
  }

  fprintf(stderr,
          "Successfully created completion queue (queue_id=%u, size=%u)\n",
          queue_id, queue_size);

  // Create Submission Queue (CREATE_SQ)
  memset(&cmd, 0, sizeof(cmd));

  cmd.opcode = nvme_admin_create_sq;
  cmd.nsid = 0;                                  // Admin commands use NSID 0
  cmd.cdw10 = (queue_size - 1) << 16 | queue_id; // QSIZE | QID
  // Set PC based on controller capabilities:
  // - Emulated (QEMU): PC=1 required (Physically Contiguous)
  //   QEMU's nvme_create_sq() validates NVME_SQ_FLAGS_PC(qflags) at line 4322
  //   of hw/nvme/ctrl.c. QEMU only supports physically contiguous queues
  //   (PC=1) - it does not implement PRP list handling for non-contiguous
  //   queues. This is a QEMU implementation limitation, not an NVMe spec
  //   requirement.
  // - Passthrough: Check CAP register CQR bit to determine PC support
  //   If CQR=0 (checked above), controller supports PC=0 (non-contiguous queues)
  //   If CQR=1, controller requires PC=1 (contiguous queues)
  //   Real NVMe hardware typically supports both PC=0 and PC=1, but some
  //   controllers may require PC=1 (CQR=1).
  // cdw11 format: bits 31:16 = CQID, bits 15:1 = QPRIO, bit 0 = PC
  cmd.cdw11 = (queue_id << 16) | (use_pc1 ? 0x0001 : 0x0000);
  // cdw11 format: bits 31:16 = CQID, bits 15:1 = QPRIO, bit 0 = PC
  // For non-contiguous queues, pass PRP1 via addr field
  // The kprobe will inject PRP1, and we'll need to handle PRP2 separately
  cmd.addr = sq_prp1; // PRP1 for non-contiguous queue
  cmd.data_len = 0; // No data transfer for CREATE_SQ
  // TODO: Update kernel kprobe to inject PRP2 for non-contiguous queues

  // Debug: Print what we're sending to the controller
  fprintf(stderr, "CREATE_SQ: queue_id=%u, queue_size=%u, cdw10=0x%08x "
                  "(QSIZE-1=0x%04x in bits 31:16, QID=0x%04x in bits 15:0), "
                  "cdw11=0x%08x (CQID=0x%04x in bits 31:16)\n",
          queue_id, queue_size, cmd.cdw10, (queue_size - 1), queue_id,
          cmd.cdw11, queue_id);
  fprintf(stderr, "  Buffer address: virt=0x%016llx, size=%zu bytes "
                  "(%u entries * %u bytes/entry)\n",
          (unsigned long long)reinterpret_cast<uint64_t>(sq_virt),
          sq_size_bytes, queue_size, NVME_EP_SQE_SIZE);

  ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
  if (ret < 0) {
    fprintf(stderr, "ERROR: Failed to create submission queue: %s\n",
            strerror(errno));
    fprintf(stderr, "ERROR: Cannot proceed - queue creation failed.\n");
    ret = -errno;
    goto cleanup;
  }

  // Check completion status
  // result field contains NVMe status code in lower 16 bits:
  //   Bits 15:1 = Status Code (SC)
  //   Bit 0 = Phase Tag (P)
  // Check if status code is non-zero (any error)
  if (cmd.result & 0xFFFE) {
    uint16_t status_field = cmd.result & 0xFFFF;
    uint8_t sc = NVME_CQE_STATUS_SC(status_field);
    uint8_t sct = NVME_CQE_STATUS_SCT(status_field);
#ifdef USE_LIBNVME
    const char* sc_str = nvme_status_to_string(sc, sct);
    fprintf(stderr,
            "ERROR: CREATE_SQ failed with status code 0x%02x (SCT=%u): %s\n",
            sc, sct, sc_str ? sc_str : "Unknown");
#else
    fprintf(stderr,
            "ERROR: CREATE_SQ failed with status code 0x%02x (SCT=%u)\n", sc,
            sct);
#endif
    if (sc == NVME_SC_INVALID_FIELD) {
      fprintf(stderr,
              "  Error: Invalid field in command (queue_id=%u, queue_size=%u, "
              "CQID=%u)\n",
              queue_id, queue_size, queue_id);
    } else if (sc == NVME_SC_CAP_EXCEEDED) {
      fprintf(
        stderr,
        "  Error: Queue size exceeds controller capabilities (queue_size=%u)\n",
        queue_size);
    }
    fprintf(stderr, "ERROR: Cannot proceed - queue creation failed.\n");
    ret = -EIO;
    goto cleanup;
  }

  fprintf(stderr,
          "Successfully created submission queue (queue_id=%u, size=%u)\n",
          queue_id, queue_size);

  // Calculate doorbell address
  // Doorbell base is typically at BAR0 + 0x1000
  // SQ doorbell: DB_BASE + (2 * qid * doorbell_stride)
  // For now, we'll set a placeholder - caller should get this from device info
  info->doorbell = 0; // TODO: Get from device info

  // Fill output structure
  info->sq_virt = sq_virt;
  info->cq_virt = cq_virt;
  info->sq_gpu = sq_gpu; // GPU-accessible pointer for kernel launch
  info->cq_gpu = cq_gpu; // GPU-accessible pointer for kernel launch
  info->sq_phys = sq_phys;
  info->cq_phys = cq_phys;
  info->sq_dmabuf_fd = sq_dmabuf_fd;
  info->cq_dmabuf_fd = cq_dmabuf_fd;

  // On successful return, queues remain allocated and file descriptors remain open
  // They will be cleaned up when the process exits or when explicitly freed
  // Don't close FDs here - queues need them to remain valid
  return 0;

cleanup:
  // This cleanup section is only reached on error paths (via goto cleanup)
  // On successful return, queues remain allocated and file descriptors remain open
  // They will be cleaned up when the process exits
  
  // Close DRM fd if opened
  if (drm_fd >= 0) {
    close(drm_fd);
  }

  // Unregister from HIP if we registered (non-coherent, non-device
  // allocations)
  // Note: Memory allocated via hipHostMalloc doesn't need unregistering
  // It's automatically managed by HIP. Only unregister if we manually
  // registered memory that wasn't allocated via hipHostMalloc.
  // Since we're using xioAllocateSubmissionQueue/xioAllocateCompletionQueue
  // which use hipHostMalloc, no unregistering is needed.

  // Free PRP lists if allocated (only on error paths)
  // On success, PRP lists remain allocated and will be cleaned up on process exit
  if (ret != 0) {
    if (sq_prp_list_virt != nullptr) {
      if (sq_prp_list_kernel_virt != 0 && kmod_fd >= 0) {
        // Kernel-allocated: unmap and free via IOCTL
        size_t sq_num_pages = (sq_size_bytes + sysconf(_SC_PAGESIZE) - 1) /
                              sysconf(_SC_PAGESIZE);
        size_t prp_list_size = sq_num_pages * sizeof(uint64_t);
        size_t prp_list_size_aligned = 
          (prp_list_size + sysconf(_SC_PAGESIZE) - 1) & 
          ~(sysconf(_SC_PAGESIZE) - 1);
        munmap(sq_prp_list_virt, prp_list_size_aligned);
        rocm_axiio_free_contig_mem_req free_req = {};
        free_req.virt_addr = sq_prp_list_kernel_virt;
        ioctl(kmod_fd, ROCM_XIO_FREE_CONTIG_MEM, &free_req);
      } else {
        // Userspace-allocated: unlock and free
        size_t sq_num_pages = (sq_size_bytes + sysconf(_SC_PAGESIZE) - 1) /
                              sysconf(_SC_PAGESIZE);
        size_t prp_list_size = sq_num_pages * sizeof(uint64_t);
        size_t prp_list_size_aligned = 
          (prp_list_size + sysconf(_SC_PAGESIZE) - 1) & 
          ~(sysconf(_SC_PAGESIZE) - 1);
        munlock(sq_prp_list_virt, prp_list_size_aligned);
        free(sq_prp_list_virt);
      }
    }
    if (cq_prp_list_virt != nullptr) {
      if (cq_prp_list_kernel_virt != 0 && kmod_fd >= 0) {
        // Kernel-allocated: unmap and free via IOCTL
        size_t cq_num_pages = (cq_size_bytes + sysconf(_SC_PAGESIZE) - 1) /
                              sysconf(_SC_PAGESIZE);
        size_t prp_list_size = cq_num_pages * sizeof(uint64_t);
        size_t prp_list_size_aligned = 
          (prp_list_size + sysconf(_SC_PAGESIZE) - 1) & 
          ~(sysconf(_SC_PAGESIZE) - 1);
        munmap(cq_prp_list_virt, prp_list_size_aligned);
        rocm_axiio_free_contig_mem_req free_req = {};
        free_req.virt_addr = cq_prp_list_kernel_virt;
        ioctl(kmod_fd, ROCM_XIO_FREE_CONTIG_MEM, &free_req);
      } else {
        // Userspace-allocated: unlock and free
        size_t cq_num_pages = (cq_size_bytes + sysconf(_SC_PAGESIZE) - 1) /
                              sysconf(_SC_PAGESIZE);
        size_t prp_list_size = cq_num_pages * sizeof(uint64_t);
        size_t prp_list_size_aligned = 
          (prp_list_size + sysconf(_SC_PAGESIZE) - 1) & 
          ~(sysconf(_SC_PAGESIZE) - 1);
        munlock(cq_prp_list_virt, prp_list_size_aligned);
        free(cq_prp_list_virt);
      }
    }
  }

  // Free queues - handle kernel-allocated and HIP-allocated separately
  // Note: Only free if allocation succeeded (sq_virt/cq_virt are valid)
  // IMPORTANT: Only free queues on error paths (ret != 0)
  // On success, queues remain allocated and will be freed by HIP runtime on process exit
  if (ret != 0) {
    if (sq_virt != nullptr) {
      if (sq_uses_kernel_alloc && sq_kernel_virt_addr != 0) {
        // Unmap mmap'd memory first
        size_t sq_size_bytes = queue_size * NVME_EP_SQE_SIZE;
        if (sq_virt != MAP_FAILED) {
          munmap(sq_virt, sq_size_bytes);
        }
        // Free kernel-allocated memory via IOCTL
        if (kmod_fd >= 0) {
          rocm_axiio_free_contig_mem_req free_req = {};
          free_req.virt_addr = sq_kernel_virt_addr;
          ioctl(kmod_fd, ROCM_XIO_FREE_CONTIG_MEM, &free_req);
        }
      } else if (sq_uses_coherent) {
        // Free HIP coherent memory
        (void)hipHostFree(sq_virt);
      } else {
        // Free using standard free function
        xioFreeSubmissionQueue(sq_virt, memory_mode);
      }
    }
    if (cq_virt != nullptr) {
      if (cq_uses_kernel_alloc && cq_kernel_virt_addr != 0) {
        // Unmap mmap'd memory first
        size_t cq_size_bytes = queue_size * NVME_EP_CQE_SIZE;
        if (cq_virt != MAP_FAILED) {
          munmap(cq_virt, cq_size_bytes);
        }
        // Free kernel-allocated memory via IOCTL
        if (kmod_fd >= 0) {
          rocm_axiio_free_contig_mem_req free_req = {};
          free_req.virt_addr = cq_kernel_virt_addr;
          ioctl(kmod_fd, ROCM_XIO_FREE_CONTIG_MEM, &free_req);
        }
      } else if (cq_uses_coherent) {
        // Free HIP coherent memory
        (void)hipHostFree(cq_virt);
      } else {
        // Free using standard free function
        xioFreeCompletionQueue(cq_virt, memory_mode);
      }
    }
  }
  // Cleanup HIP registrations (only if we registered manually)
  // Note: hipHostMalloc memory doesn't need unregistering - it's managed by HIP

  // Close file descriptors only on error paths
  // On successful return (ret == 0), queues remain allocated and FDs remain open
  // They will be cleaned up when the process exits
  if (drm_fd >= 0) {
    close(drm_fd);
  }
  if (nvme_fd >= 0) {
    close(nvme_fd);
  }
  if (kmod_fd >= 0) {
    close(kmod_fd);
  }
  return ret;
}

// Cleanup function to free resources after GPU kernel completes
__host__ int nvme_ep::nvme_cleanup_queue_via_ioctl(
  const char* nvme_device, const char* kernel_module_device, uint16_t queue_id,
  const struct nvme_queue_info* queue_info, unsigned memory_mode) {
  int kmod_fd = -1;
  int nvme_fd = -1;
  int ret = 0;
  struct nvme_passthru_cmd cmd;

  if (!nvme_device || !kernel_module_device || !queue_info) {
    return -EINVAL;
  }

  // Open kernel module device for unregistration
  kmod_fd = open(kernel_module_device, O_RDWR);
  if (kmod_fd < 0) {
    fprintf(stderr, "Warning: Failed to open kernel module device %s for cleanup: %s\n",
            kernel_module_device, strerror(errno));
    // Continue with NVMe queue deletion even if kernel module open fails
  }

  // Open NVMe device for queue deletion
  nvme_fd = open(nvme_device, O_RDWR);
  if (nvme_fd < 0) {
    fprintf(stderr, "Warning: Failed to open NVMe device %s for cleanup: %s\n",
            nvme_device, strerror(errno));
    // Continue with unregistration even if NVMe device open fails
  }

  // Delete NVMe queues (DELETE_SQ first, then DELETE_CQ)
  if (nvme_fd >= 0) {
    // Delete Submission Queue (DELETE_SQ)
    memset(&cmd, 0, sizeof(cmd));
    cmd.opcode = nvme_admin_delete_sq;
    cmd.nsid = 0;         // Admin commands use NSID 0
    cmd.cdw10 = queue_id; // QID
    cmd.data_len = 0;     // No data transfer for DELETE_SQ

    ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
    if (ret < 0) {
      fprintf(stderr, "Warning: DELETE_SQ failed during cleanup: %s\n",
              strerror(errno));
    }

    // Delete Completion Queue (DELETE_CQ)
    memset(&cmd, 0, sizeof(cmd));
    cmd.opcode = nvme_admin_delete_cq;
    cmd.nsid = 0;         // Admin commands use NSID 0
    cmd.cdw10 = queue_id; // QID
    cmd.data_len = 0;     // No data transfer for DELETE_CQ

    ret = ioctl(nvme_fd, NVME_IOCTL_ADMIN_CMD, &cmd);
    if (ret < 0) {
      fprintf(stderr, "Warning: DELETE_CQ failed during cleanup: %s\n",
              strerror(errno));
    }
  }

  // Unregister queue addresses from kernel module
  if (kmod_fd >= 0) {
    rocm_axiio_unregister_queue_addr_req unreg_req;

    // Unregister SQ
    memset(&unreg_req, 0, sizeof(unreg_req));
    unreg_req.virt_addr = reinterpret_cast<uint64_t>(queue_info->sq_virt);
    ret = ioctl(kmod_fd, ROCM_XIO_UNREGISTER_QUEUE_ADDR, &unreg_req);
    if (ret < 0 && errno != ENOENT) {
      fprintf(stderr, "Warning: Failed to unregister SQ address: %s\n",
              strerror(errno));
    }

    // Unregister CQ
    memset(&unreg_req, 0, sizeof(unreg_req));
    unreg_req.virt_addr = reinterpret_cast<uint64_t>(queue_info->cq_virt);
    ret = ioctl(kmod_fd, ROCM_XIO_UNREGISTER_QUEUE_ADDR, &unreg_req);
    if (ret < 0 && errno != ENOENT) {
      fprintf(stderr, "Warning: Failed to unregister CQ address: %s\n",
              strerror(errno));
    }
  }

  // Free memory allocations
  // Note: We use the same allocation functions as creation
  bool sq_is_device = (memory_mode & 0x1) != 0;
  bool cq_is_device = (memory_mode & 0x2) != 0;

  if (queue_info->sq_virt != nullptr) {
    if (sq_is_device) {
      // Device memory - use hipFree
      (void)hipFree(queue_info->sq_virt);
    } else {
      // Host memory - use xioFreeSubmissionQueue
      xioFreeSubmissionQueue(queue_info->sq_virt, memory_mode);
    }
  }

  if (queue_info->cq_virt != nullptr) {
    if (cq_is_device) {
      // Device memory - use hipFree
      (void)hipFree(queue_info->cq_virt);
    } else {
      // Host memory - use xioFreeCompletionQueue
      xioFreeCompletionQueue(queue_info->cq_virt, memory_mode);
    }
  }

  // Close file descriptors
  if (nvme_fd >= 0) {
    close(nvme_fd);
  }
  if (kmod_fd >= 0) {
    close(kmod_fd);
  }

  return 0;
}

#endif // __HIP_DEVICE_COMPILE__
