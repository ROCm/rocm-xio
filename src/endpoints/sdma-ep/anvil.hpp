#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <vector>
#include <utility>

// Only include device header when compiling with HIP compiler
#ifdef __HIPCC__
#include "anvil_device.hpp"
#else
// Forward declarations for host-only compilation
namespace anvil { struct SdmaQueueDeviceHandle; }
#endif

#include "sdma-host-queue.h"
#include "hsa/hsa_ext_amd.h"
#include "hsakmt/hsakmt.h"
#include "hsakmt/hsakmttypes.h"

namespace anvil {

class SdmaQueue {
public:
  SdmaQueue(int localDeviceId, int remoteDeviceId, hsa_agent_t& localAgent,
            uint32_t engineId, bool allocateOnHost = false);
  ~SdmaQueue();

  SdmaQueueDeviceHandle* deviceHandle() const;
  SdmaQueuePythonDeviceCtx deviceCtx() const;
  SdmaQueueHostHandle hostHandle() const;

  void dump(std::ofstream&);

private:
  friend class SdmaQueueHostHandle;

  int remoteDeviceId_;
  bool hostAllocated_;
  uint64_t* cachedWptr_;      // Device-side pointer
  uint64_t* committedWptr_;   // Device-side pointer
  void* queueBuffer_;
  HsaQueueResource queue_;
  SdmaQueueDeviceHandle* deviceHandle_;

  // Host-side state
  std::atomic<uint64_t> hostCachedWptr_;
  std::atomic<uint64_t> hostCommittedWptr_;
  uint64_t hostCachedHwReadIndex_;
};

class AnvilLib {
private:
  // Make constructor private
  AnvilLib() = default;

public:
  ~AnvilLib();
  // access to singleton
  static AnvilLib& getInstance();

  AnvilLib(const AnvilLib&) = delete;
  AnvilLib& operator=(const AnvilLib&) = delete;

public:
  void init();
  bool connect(int srcDeviceId, int dstDeviceId, int numChannels = 1, bool allocateOnHost = false);
  SdmaQueue* getSdmaQueue(int srcDeviceId, int dstDeviceId, int channelIdx = 0);
  SdmaQueue* createSdmaQueue(int srcDeviceId, int dstDeviceId,
                             uint32_t engineId, int* channelIdx = nullptr);
  int getSdmaEngineId(int srcDeviceId, int dstDeviceId);
  SdmaQueuePythonDeviceCtx get_queue_device_ctx(int srcDeviceId, int dstDeviceId);
  SdmaQueueHostHandle getHostHandle(int srcDeviceId, int dstDeviceId, int channelIdx = 0);

  // Host-initiated SDMA operations (Python API)
  void put(int srcDevice, int dstDevice, int channelIdx, void* src, void* dst, size_t size);

  void timestamp(int srcDevice, int dstDevice, int channelIdx, void* timestamp_ptr);

  void put_tile(int srcDevice, int dstDevice, int channelIdx, const Tile& tile, void* dst_ptr,
                size_t dst_stride);

  void put_tiles(int srcDevice, int dstDevice, int channelIdx, const std::vector<Tile>& tiles,
                 const std::vector<void*>& dst_ptrs, const std::vector<size_t>& dst_strides);

  // Combined put + atomic_add in one SDMA submission (linear memory)
  void put_signal(int srcDevice, int dstDevice, int channelIdx, void* src, void* dst, size_t size,
                  void* flag_ptr, uint64_t flag_value, int flag_bits = 32);

  // Combined put_tile + atomic_add in one SDMA submission
  void put_tile_signal(int srcDevice, int dstDevice, int channelIdx, const Tile& tile, void* dst_ptr,
                       size_t dst_stride, void* flag_ptr, uint64_t flag_value, int flag_bits = 32);

  // Combined put_tiles + atomic_add in one SDMA submission
  void put_tiles_signal(int srcDevice, int dstDevice, int channelIdx, const std::vector<Tile>& tiles,
                        const std::vector<void*>& dst_ptrs, const std::vector<size_t>& dst_strides,
                        void* flag_ptr, uint64_t flag_value, int flag_bits = 32);

  // Wait on flag, then perform put (POLL + COPY in one submission)
  void wait_flag_then_put(int srcDevice, int dstDevice, int channelIdx, void* flag_ptr,
                          uint32_t expected_value, void* src, void* dst, size_t size, int flag_bits = 32);

  // Wait on flag, then perform put_tile (POLL + SUB_WINDOW_COPY in one submission)
  void wait_flag_then_put_tile(int srcDevice, int dstDevice, int channelIdx, void* flag_ptr,
                                uint32_t expected_value, const Tile& tile, void* dst_ptr, size_t dst_stride,
                                int flag_bits = 32);

  // Wait on flag, then perform many put_tile operations in one submission
  void wait_flag_then_put_tiles(int srcDevice, int dstDevice, int channelIdx, void* flag_ptr,
                                 uint32_t expected_value, const std::vector<Tile>& tiles,
                                 const std::vector<void*>& dst_ptrs, const std::vector<size_t>& dst_strides,
                                 int flag_bits = 32);

  void signal(int srcDevice, int dstDevice, int channelIdx, void* flag_ptr, uint64_t flag_value,
              int flag_bits = 32);

  // Wait for all SDMA operations to complete
  void quiet(int srcDevice, int dstDevice, int channelIdx);

private:
  using ChannelKey = std::pair<int, int>;
  struct ChannelKeyHash {
    std::size_t operator()(const ChannelKey& key) const noexcept {
      const auto a = static_cast<std::uint32_t>(key.first);
      const auto b = static_cast<std::uint32_t>(key.second);
      return (static_cast<std::size_t>(a) << 32) ^ static_cast<std::size_t>(b);
    }
  };
  using ChannelVector = std::vector<std::unique_ptr<SdmaQueue>>;

  /*
   * MI300X OAM MAP (XGMI topology -> SDMA engine)
   * src\dst  0  1  2  3  4  5  6  7
   * 0        0  7  6  1  2  4  5  3
   * 1        7  0  1  5  4  2  3  6
   * 2        5  1  0  6  7  3  2  4
   * 3        1  6  5  0  3  7  4  2
   * 4        2  4  7  3  0  5  6  1
   * 5        4  2  3  7  6  0  1  5
   * 6        5  3  2  4  6  1  0  7
   * 7        3  6  4  2  1  5  7  0
   */
  std::array<std::array<int, 8>, 8> mi300xOamMap = {{{0, 7, 6, 1, 2, 4, 5, 3},
                                                     {7, 0, 1, 5, 4, 2, 3, 6},
                                                     {5, 1, 0, 6, 7, 3, 2, 4},
                                                     {1, 6, 5, 0, 3, 7, 4, 2},
                                                     {2, 4, 7, 3, 0, 5, 6, 1},
                                                     {4, 2, 3, 7, 6, 0, 1, 5},
                                                     {5, 3, 2, 4, 6, 1, 0, 7},
                                                     {3, 6, 4, 2, 1, 5, 7, 0}}};

  int getOamId(int deviceId);

  std::once_flag init_flag;
  std::unordered_map<ChannelKey, ChannelVector, ChannelKeyHash> sdma_channels_;
  std::unordered_map<ChannelKey, ChannelVector, ChannelKeyHash> host_sdma_channels_;
};

extern AnvilLib& anvil;

void EnablePeerAccess(int deviceId, int peerDeviceId);

} // namespace anvil
