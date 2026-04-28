/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * SDMA Endpoint -- GPU-initiated DMA via AMD SDMA engines
 *
 * This header provides the complete public API for the SDMA
 * endpoint, including:
 *   - Host-side setup: init, connect, queue creation
 *   - Device-side operations: put, signal, wait, flush (via sdma_device.hpp)
 *   - Host-side operations: put, put_signal, put_tile, signal, quiet, etc.
 *
 * The device handle (SdmaQueueHandle) and all device-side
 * operations are derived from the anvil library (AMD RAD).
 */

#ifndef SDMA_EP_H
#define SDMA_EP_H

#include <cassert>
#include <cstdint>
#include <string>
#include <vector>

#include <hip/hip_ext.h>
#include <hip/hip_runtime.h>

namespace sdma_ep {

/* ================================================================
 * Host-Side Setup Types
 * ================================================================ */

/**
 * @brief Information about an established SDMA connection.
 *
 * Returned by createConnection(). Contains the resolved
 * SDMA engine ID for the GPU pair, which is determined by
 * the XGMI/Infinity Fabric topology (MI300X OAM map).
 */
struct SdmaConnectionInfo {
  int srcDeviceId;   /**< Source HIP device ID. */
  int dstDeviceId;   /**< Destination HIP device ID. */
  uint32_t engineId; /**< XGMI-optimal SDMA engine ID
                          for this GPU pair. */
};

/**
 * @brief Information about a created SDMA queue.
 *
 * Returned by createQueue(). The deviceHandle pointer
 * is GPU-accessible and should be passed to GPU kernels
 * that use the device-side SDMA operations (put, signal,
 * waitSignal, flush, quiet).
 */
struct SdmaQueueInfo {
  void* deviceHandle; /**< GPU-accessible pointer to a
                           SdmaQueueHandle. Cast to
                           SdmaQueueHandle* in kernel
                           code. */
  int srcDeviceId;    /**< Source HIP device ID. */
  int dstDeviceId;    /**< Destination HIP device ID. */
  int channelIdx;     /**< Channel index within the
                           connection (0-based). */
};

/**
 * @brief Tile representation for 2D transfers.
 *
 * Describes a 2D tile within a larger buffer, used for
 * strided sub-window copy operations.
 */
struct Tile {
  int32_t pid_m;     /**< Tile coordinate in M dimension */
  int32_t pid_n;     /**< Tile coordinate in N dimension */
  int32_t block_m;   /**< Block size in M dimension */
  int32_t block_n;   /**< Block size in N dimension */
  void* data;        /**< Pointer to tile data */
  size_t elem_size;  /**< Element size in bytes (e.g., 4 for float) */
  size_t src_stride; /**< Source row stride in bytes (0 = contiguous) */

  size_t width_bytes() const { return block_n * elem_size; }
  size_t height() const { return block_m; }
  size_t offset_m() const { return pid_m * block_m; }
  size_t offset_n() const { return pid_n * block_n; }
  size_t src_pitch() const { return src_stride > 0 ? src_stride : width_bytes(); }
};

/**
 * @brief Python device context structure for SDMA queue.
 *
 * Contains device-accessible pointers encoded as uintptr_t
 * for safe passing through Python bindings.
 */
struct SdmaQueuePythonDeviceCtx {
  uintptr_t queueBuf;
  uintptr_t rptr;
  uintptr_t wptr;
  uintptr_t doorbell;
  uintptr_t cachedWptr;
  uintptr_t committedWptr;
};

static_assert(sizeof(SdmaQueuePythonDeviceCtx) == 48,
              "SdmaQueuePythonDeviceCtx must be 48 bytes (6 * sizeof(uintptr_t))");

/* ================================================================
 * Device-Side Operations
 * ================================================================
 * For device-side SDMA operations (put, signal, waitSignal, etc.),
 * include sdma_device.hpp in your HIP kernel code. This header
 * contains type definitions and host-side APIs only.
 */

/* ================================================================
 * Host-Side Setup Functions
 * ================================================================ */

/**
 * @brief Initialize the SDMA endpoint subsystem.
 *
 * Sets up the HSA runtime, enumerates GPU and CPU
 * agents, and opens the KFD (Kernel Fusion Driver)
 * interface. Must be called before createConnection()
 * or createQueue().
 *
 * Idempotent: safe to call multiple times; subsequent
 * calls are no-ops.
 *
 * @return 0 on success, negative error code on failure.
 */
__host__ int initEndpoint();

/**
 * @brief Mark the SDMA endpoint subsystem as inactive.
 *
 * Resets the internal initialization flag so that
 * subsequent createConnection() / createQueue() calls
 * will fail until initEndpoint() is called again.
 *
 * @note This does NOT destroy existing SDMA queues or
 *       shut down HSA/KFD. Queue and HSA resources are
 *       released when the AnvilLib singleton is
 *       destroyed at process exit. Call destroyQueue()
 *       on individual queues for explicit cleanup.
 * @note Because the underlying HSA init uses
 *       std::call_once, calling initEndpoint() after
 *       shutdownEndpoint() re-enables the flag but
 *       does not re-run HSA/KFD initialization.
 */
__host__ void shutdownEndpoint();

/**
 * @brief Create an SDMA connection between two GPUs.
 *
 * Enables P2P peer access from the source GPU to the
 * destination GPU and resolves the XGMI-topology-
 * optimal SDMA engine ID for this GPU pair (using the
 * MI300X OAM map). For bidirectional transfers, call
 * once for each direction.
 *
 * Must be called after initEndpoint() and before
 * createQueue() for the same GPU pair.
 *
 * @param srcDeviceId Source HIP device ID.
 * @param dstDeviceId Destination HIP device ID.
 * @param info        Output connection information.
 * @return 0 on success, negative error code on failure.
 */
__host__ int createConnection(int srcDeviceId, int dstDeviceId,
                              SdmaConnectionInfo* info);

/**
 * @brief Create an SDMA queue for a GPU pair.
 *
 * Allocates a 1 MiB ring buffer in device memory,
 * creates an SDMA queue via hsakmt, and populates a
 * GPU-accessible device handle (SdmaQueueHandle).
 *
 * Must be called after createConnection() for the same
 * GPU pair. The returned SdmaQueueInfo::deviceHandle is
 * a pointer in device memory that can be passed directly
 * to GPU kernels.
 *
 * @param srcDeviceId Source HIP device ID.
 * @param dstDeviceId Destination HIP device ID.
 * @param info        Output queue information.
 * @return 0 on success, negative error code on failure.
 */
__host__ int createQueue(int srcDeviceId, int dstDeviceId, SdmaQueueInfo* info);

/**
 * @brief Create a host-initiated SDMA queue for a GPU pair.
 *
 * Similar to createQueue(), but allocates the ring buffer in
 * host memory instead of device memory. This enables CPU-side
 * SDMA operations via the host-initiated transfer functions.
 *
 * Must be called after initEndpoint(). For bidirectional
 * transfers, call once for each direction.
 *
 * @param srcDeviceId Source HIP device ID.
 * @param dstDeviceId Destination HIP device ID.
 * @param info        Output queue information (deviceHandle will be nullptr).
 * @return 0 on success, negative error code on failure.
 */
__host__ int createHostQueue(int srcDeviceId, int dstDeviceId, SdmaQueueInfo* info);

/**
 * @brief Destroy an SDMA queue.
 *
 * Releases the ring buffer, device handle memory, and
 * hsakmt queue resources associated with the given
 * queue.
 *
 * @param info Queue information from createQueue().
 *             The deviceHandle becomes invalid after
 *             this call.
 */
__host__ void destroyQueue(SdmaQueueInfo* info);

__host__ SdmaQueuePythonDeviceCtx get_queue_device_ctx(int srcDeviceId, int dstDeviceId);


/* ================================================================
 * Host-Side Data Transfer Operations
 * ================================================================ */

__host__ void put(int srcDeviceId, int dstDeviceId, int channelIdx,
                  void* src, void* dst, size_t size);

__host__ void put_signal(int srcDeviceId, int dstDeviceId, int channelIdx,
                         void* src, void* dst, size_t size,
                         void* flag_ptr, uint64_t flag_value, int flag_bits = 64);

__host__ void put_tile(int srcDeviceId, int dstDeviceId, int channelIdx,
                       const Tile& tile, void* dst_ptr, size_t dst_stride);

__host__ void put_tiles(int srcDeviceId, int dstDeviceId, int channelIdx,
                        const std::vector<Tile>& tiles,
                        const std::vector<void*>& dst_ptrs,
                        const std::vector<size_t>& dst_strides);

__host__ void put_tile_signal(int srcDeviceId, int dstDeviceId, int channelIdx,
                               const Tile& tile, void* dst_ptr, size_t dst_stride,
                               void* flag_ptr, uint64_t flag_value, int flag_bits = 32);

__host__ void put_tiles_signal(int srcDeviceId, int dstDeviceId, int channelIdx,
                                const std::vector<Tile>& tiles,
                                const std::vector<void*>& dst_ptrs,
                                const std::vector<size_t>& dst_strides,
                                void* flag_ptr, uint64_t flag_value, int flag_bits = 32);

__host__ void wait_flag_then_put(int srcDeviceId, int dstDeviceId, int channelIdx,
                                  void* flag_ptr, uint32_t expected_value,
                                  void* src, void* dst, size_t size, int flag_bits = 32);

__host__ void wait_flag_then_put_tile(int srcDeviceId, int dstDeviceId, int channelIdx,
                                       void* flag_ptr, uint32_t expected_value,
                                       const Tile& tile, void* dst_ptr,
                                       size_t dst_stride, int flag_bits = 32);

__host__ void wait_flag_then_put_tiles(int srcDeviceId, int dstDeviceId, int channelIdx,
                                        void* flag_ptr, uint32_t expected_value,
                                        const std::vector<Tile>& tiles,
                                        const std::vector<void*>& dst_ptrs,
                                        const std::vector<size_t>& dst_strides,
                                        int flag_bits = 32);

__host__ void signal(int srcDeviceId, int dstDeviceId, int channelIdx,
                     void* flag_ptr, uint64_t flag_value, int flag_bits = 32);

__host__ void timestamp(int srcDeviceId, int dstDeviceId, int channelIdx,
                        void* timestamp_ptr);

__host__ void quiet(int srcDeviceId, int dstDeviceId, int channelIdx);

} // namespace sdma_ep

#endif // SDMA_EP_H