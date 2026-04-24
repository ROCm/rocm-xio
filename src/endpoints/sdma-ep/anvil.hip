#include <cstring>
#include <fstream>
#include <iostream>

#include "anvil.hpp"
#include "xio.h"

namespace anvil {

[[maybe_unused]] auto checkHsaError = [](hsa_status_t s, const char* msg,
                                         const char* file, int line) {
  if (s != HSA_STATUS_SUCCESS) {
    const char* hsa_err_msg;
    hsa_status_string(s, &hsa_err_msg);
    throw(std::runtime_error{std::string("HSA error at ") + file +
                             std::string(":") + std::to_string(line) +
                             std::string(" - ") + hsa_err_msg});
  }
};

#define CHECK_HSA_ERROR(cmd) checkHsaError((cmd), #cmd, __FILE__, __LINE__)

#define CHECK_HSAKMT_SUCCESS(call, msg)                                        \
  do {                                                                         \
    if ((call) != HSAKMT_STATUS_SUCCESS) {                                     \
      std::cout << "ERROR code: " << std::dec << call << " " << msg            \
                << " (File: " << __FILE__ << ", Line: " << __LINE__ << ")"     \
                << std::endl;                                                  \
      exit(EXIT_FAILURE);                                                      \
    }                                                                          \
  } while (0)

inline void checkHipError(hipError_t err, const char* msg, const char* file,
                          int line) {
  if (err != hipSuccess) {
    std::cerr << "HIP error at " << file << ":" << line << " — " << msg << "\n"
              << "  Code: " << err << " (" << hipGetErrorString(err) << ")"
              << std::endl;
    std::exit(EXIT_FAILURE);
  }
}

#define CHECK_HIP_ERROR(cmd) checkHipError((cmd), #cmd, __FILE__, __LINE__)

// Allow access to peerDeviceId from deviceId
void EnablePeerAccess(int const deviceId, int const peerDeviceId) {
  int canAccess;
  CHECK_HIP_ERROR(hipDeviceCanAccessPeer(&canAccess, deviceId, peerDeviceId));
  if (!canAccess) {
    std::cerr << "Unable to enable peer access from GPU devices " << deviceId
              << " to " << peerDeviceId << "\n";
  }

  CHECK_HIP_ERROR(hipSetDevice(deviceId));
  hipError_t error = hipDeviceEnablePeerAccess(peerDeviceId, 0);
  if (error != hipSuccess && error != hipErrorPeerAccessAlreadyEnabled) {
    std::cerr << "Unable to enable peer to peer access from " << deviceId
              << "  to " << peerDeviceId << " (" << hipGetErrorString(error)
              << ")\n";
  }
}

// HSA agents
std::vector<hsa_agent_t> cpuAgents_;
std::vector<hsa_agent_t> gpuAgents_;

hsa_status_t rocm_hsa_agent_callback(hsa_agent_t agent,
                                     hsa_device_type_t target_device_type,
                                     [[maybe_unused]] void* vector) {
  std::vector<hsa_agent_t>* agents = static_cast<std::vector<hsa_agent_t>*>(
    vector);
  hsa_device_type_t device_type{};
  hsa_status_t status{
    hsa_agent_get_info(agent, HSA_AGENT_INFO_DEVICE, &device_type)};
  if (status != HSA_STATUS_SUCCESS) {
    printf("Failure to get device type: 0x%x", status);
    return status;
  }
  if (device_type == target_device_type) {
    agents->push_back(agent);
  }
  return status;
}

hsa_status_t rocm_hsa_gpu_agent_callback(hsa_agent_t agent,
                                         [[maybe_unused]] void* context) {
  return rocm_hsa_agent_callback(agent, HSA_DEVICE_TYPE_GPU, context);
}
hsa_status_t rocm_hsa_cpu_agent_callback(hsa_agent_t agent,
                                         [[maybe_unused]] void* context) {
  return rocm_hsa_agent_callback(agent, HSA_DEVICE_TYPE_CPU, context);
}

void SetUpKFD() {
  CHECK_HSAKMT_SUCCESS(hsaKmtOpenKFD(), "hsaKmtOpenKFD() failed!");
  HsaSystemProperties m_SystemProperties;
  std::memset(&m_SystemProperties, 0, sizeof(m_SystemProperties));
  CHECK_HSAKMT_SUCCESS(hsaKmtAcquireSystemProperties(&m_SystemProperties),
                       "Failed!");
}

// True only after init() has run (SetUpKFD). Avoids CloseKFD/hsa_shut_down at
// exit when user never ran sdma-ep (e.g. xio-tester -h).
static bool s_kfd_opened = false;

void CloseKFD() {
  CHECK_HSAKMT_SUCCESS(hsaKmtCloseKFD(), "hsaKmtCloseKFD() failed");
}

// Convert a logical deviceId index to the NVML device minor number
static const std::string getBusId(int deviceId) {
  // On most systems, the PCI bus ID comes back as in the 0000:00:00.0
  // format. Still need to allocate proper space in case PCI domain goes
  // higher.
  char busIdChar[] = "00000000:00:00.0";
  CHECK_HIP_ERROR(hipDeviceGetPCIBusId(busIdChar, sizeof(busIdChar), deviceId));
  // we need the hex in lower case format
  for (size_t i = 0; i < sizeof(busIdChar); i++) {
    busIdChar[i] = std::tolower(busIdChar[i]);
  }
  return std::string(busIdChar);
}

std::ostream& operator<<(std::ostream& os, const SDMA_PKT_COPY_LINEAR& cmd) {
  os << "op: " << cmd.HEADER_UNION.op << " sub_op: " << cmd.HEADER_UNION.sub_op;
  os << " count: " << cmd.COUNT_UNION.count;
  os << " src[31:0] " << cmd.SRC_ADDR_LO_UNION.src_addr_31_0 << " src[63:32] "
     << cmd.SRC_ADDR_HI_UNION.src_addr_63_32;
  os << " dst[31:0] " << cmd.DST_ADDR_LO_UNION.dst_addr_31_0 << " dst[63:32] "
     << cmd.DST_ADDR_HI_UNION.dst_addr_63_32;
  return os;
}

std::ostream& operator<<(std::ostream& os, const SDMA_PKT_ATOMIC& cmd) {
  os << "op: " << cmd.HEADER_UNION.op << " sub_op: " << cmd.HEADER_UNION.sub_op
     << " operation: " << cmd.HEADER_UNION.operation;
  os << " add[31:0] " << cmd.ADDR_LO_UNION.addr_31_0 << " addr[63:32] "
     << cmd.ADDR_HI_UNION.addr_63_32;
  os << " data[31:0] " << cmd.SRC_DATA_LO_UNION.src_data_31_0 << " data[63:32] "
     << cmd.SRC_DATA_HI_UNION.src_data_63_32;
  return os;
}

#if XIO_SDMA_OSS7

std::ostream& operator<<(std::ostream& os,
                         const SDMA_PKT_COPY_LINEAR_PHY_MI4& cmd) {
  os << "MI4_PHY op: " << cmd.HEADER_UNION.op_code
     << " sub_op: " << cmd.HEADER_UNION.sub_op_code
     << " count: " << cmd.COUNT_UNION.count;
  os << " src[31:0] " << cmd.SRC_ADDR_LO_UNION.src_address_lo << " src[63:32] "
     << cmd.SRC_ADDR_HI_UNION.src_address_hi;
  os << " dst[31:0] " << cmd.DST_ADDR_LO_UNION.dst_address_lo << " dst[63:32] "
     << cmd.DST_ADDR_HI_UNION.dst_address_hi;
  return os;
}

std::ostream& operator<<(std::ostream& os,
                         const SDMA_PKT_COPY_LINEAR_WAIT_SIGNAL_MI4& cmd) {
  os << "MI4_WS op: " << cmd.HEADER_UNION.op
     << " sub_op: " << cmd.HEADER_UNION.subop
     << " wait: " << cmd.HEADER_UNION.wait
     << " signal: " << cmd.HEADER_UNION.signal
     << " count: " << cmd.COPY_COUNT_UNION.copy_count;
  os << " src[31:0] " << cmd.SRC_ADDR_LO_UNION.src_addr_31_0 << " src[63:32] "
     << cmd.SRC_ADDR_HI_UNION.src_addr_63_32;
  os << " dst[31:0] " << cmd.DST_ADDR_LO_UNION.dst_addr_31_0 << " dst[63:32] "
     << cmd.DST_ADDR_HI_UNION.dst_addr_63_32;
  if (cmd.HEADER_UNION.signal) {
    os << " sig_op: " << cmd.SIGNAL_CTRL_UNION.signal_operation;
  }
  return os;
}

std::ostream& operator<<(std::ostream& os, const SDMA_PKT_FENCE_MI4& cmd) {
  os << "MI4_FENCE op: " << cmd.HEADER_UNION.op_code
     << " sub_op: " << cmd.HEADER_UNION.sub_op_code
     << " data: " << cmd.DATA_UNION.data;
  os << " addr[31:0] " << cmd.ADDR_LO_UNION.fence_addr_lo << " addr[63:32] "
     << cmd.ADDR_HI_UNION.fence_addr_hi;
  return os;
}

#endif /* XIO_SDMA_OSS7 */

SdmaQueue::SdmaQueue(int localDeviceId, int remoteDeviceId,
                     hsa_agent_t& localAgent, uint32_t engineId,
                     bool allocateOnHost)
    : remoteDeviceId_(remoteDeviceId), hostAllocated_(allocateOnHost) {
  int originalDeviceId;
  CHECK_HIP_ERROR(hipGetDevice(&originalDeviceId));

  uint32_t localNodeId;
  hsa_status_t status = hsa_agent_get_info(localAgent, HSA_AGENT_INFO_NODE,
                                           &localNodeId);
  if (status != HSA_STATUS_SUCCESS) {
    printf("Failure to get device info: 0x%x", status);
    // return status;
  }

  // Allocate SDMA queue buffer
  if (allocateOnHost) {
    // Use pinned host memory for CPU-only access
    CHECK_HIP_ERROR(hipHostMalloc(&queueBuffer_, SDMA_QUEUE_SIZE,
                                  hipHostMallocWriteCombined |
                                      hipHostMallocPortable));
  } else {
    // Use device memory (existing path)
    HsaMemFlags memFlags = {};
    memFlags.ui32.NonPaged = 1;
    memFlags.ui32.HostAccess = 1;
    memFlags.ui32.PageSize = HSA_PAGE_SIZE_4KB;
    memFlags.ui32.NoNUMABind = 1;
    memFlags.ui32.ExecuteAccess = 1;
    memFlags.ui32.Uncached = 1;
    CHECK_HSAKMT_SUCCESS(
        hsaKmtAllocMemory(localNodeId, SDMA_QUEUE_SIZE, memFlags,
                          &queueBuffer_),
        "Failed");
    CHECK_HSAKMT_SUCCESS(hsaKmtMapMemoryToGPU(queueBuffer_, SDMA_QUEUE_SIZE,
                                              NULL),
                         "Failed");
  }

  // Create SDMA Queue
  std::memset(&queue_, 0, sizeof(HsaQueueResource));

  CHECK_HSAKMT_SUCCESS(
      hsaKmtCreateQueueExt(localNodeId, HSA_QUEUE_SDMA_BY_ENG_ID,
                           DEFAULT_QUEUE_PERCENTAGE, DEFAULT_PRIORITY, engineId,
                           queueBuffer_, SDMA_QUEUE_SIZE, nullptr, &queue_),
      "Failed");

  // Initialize host-side state (always needed)
  uint64_t initial_wptr = *queue_.Queue_write_ptr_aql;
  hostCachedWptr_.store(initial_wptr, std::memory_order_relaxed);
  hostCommittedWptr_.store(initial_wptr, std::memory_order_relaxed);
  hostCachedHwReadIndex_ = *queue_.Queue_read_ptr_aql;

  if (allocateOnHost) {
    // Host-only queue: Skip device-side structures
    cachedWptr_ = nullptr;
    committedWptr_ = nullptr;
    deviceHandle_ = nullptr;
  } else {
    // Device queue: Allocate device-side structures for GPU kernel access
    {
      hsa_status_t s;
      s = xio::allocDeviceMemory(sizeof(SdmaQueueDeviceHandle),
                                 (void**)&deviceHandle_, "SDMA queue handle",
                                 XIO_DEVICE_MEM_HIP);
      if (s != HSA_STATUS_SUCCESS)
        throw std::runtime_error("allocDeviceMemory(deviceHandle_) failed");
      s = xio::allocDeviceMemory(sizeof(uint64_t), (void**)&cachedWptr_,
                                 "SDMA cached wptr", XIO_DEVICE_MEM_UNCACHED);
      if (s != HSA_STATUS_SUCCESS)
        throw std::runtime_error("allocDeviceMemory(cachedWptr_) failed");
      s = xio::allocDeviceMemory(sizeof(uint64_t), (void**)&committedWptr_,
                                 "SDMA committed wptr", XIO_DEVICE_MEM_UNCACHED);
      if (s != HSA_STATUS_SUCCESS)
        throw std::runtime_error("allocDeviceMemory(committedWptr_) failed");
    }

  uint64_t cachedWptr = *reinterpret_cast<uint64_t*>(
    queue_.Queue_write_ptr_aql);
  uint64_t committedWptr = *reinterpret_cast<uint64_t*>(
    queue_.Queue_write_ptr_aql);
    SdmaQueueDeviceHandle handle = {
        .queueBuf = static_cast<uint32_t*>(queueBuffer_),
        .rptr = queue_.Queue_read_ptr_aql,
        .wptr = queue_.Queue_write_ptr_aql,
        .doorbell = queue_.Queue_DoorBell_aql,
        .cachedWptr = cachedWptr_,
        .committedWptr = committedWptr_,
        .cachedHwReadIndex = *reinterpret_cast<uint64_t*>(
          queue_.Queue_read_ptr_aql),
        .maxWritePtr = *reinterpret_cast<uint64_t*>(queue_.Queue_read_ptr_aql),
    };

    CHECK_HIP_ERROR(hipMemcpy(deviceHandle_, &handle,
                              sizeof(SdmaQueueDeviceHandle),
                              hipMemcpyHostToDevice));
    CHECK_HIP_ERROR(hipMemcpy(cachedWptr_, &cachedWptr, sizeof(uint64_t),
                              hipMemcpyHostToDevice));
  CHECK_HIP_ERROR(hipMemcpy(committedWptr_, &committedWptr, sizeof(uint64_t),
                              hipMemcpyHostToDevice));
  }
}

SdmaQueue::~SdmaQueue() {
  // TODO catch exception?
  CHECK_HSAKMT_SUCCESS(hsaKmtDestroyQueue(queue_.QueueId),
                       "Failed to destroy queue.");

  // Only free device-side pointers if they were allocated
  if (deviceHandle_ != nullptr) {
    xio::freeDeviceMemory(deviceHandle_, XIO_DEVICE_MEM_HIP);
  }
  if (cachedWptr_ != nullptr) {
    xio::freeDeviceMemory(cachedWptr_, XIO_DEVICE_MEM_UNCACHED);
  }
  if (committedWptr_ != nullptr) {
    xio::freeDeviceMemory(committedWptr_, XIO_DEVICE_MEM_UNCACHED);
  }

  // Free queue buffer based on allocation type
  if (hostAllocated_) {
    CHECK_HIP_ERROR(hipHostFree(queueBuffer_));
  } else {
    CHECK_HSAKMT_SUCCESS(hsaKmtUnmapMemoryToGPU(queueBuffer_), "Failed");
    CHECK_HSAKMT_SUCCESS(hsaKmtFreeMemory(queueBuffer_, SDMA_QUEUE_SIZE),
                         "Failed");
  }
}

SdmaQueueDeviceHandle* SdmaQueue::deviceHandle() const {
  return deviceHandle_;
}

SdmaQueuePythonDeviceCtx SdmaQueue::deviceCtx() const {
  if (deviceHandle_ == nullptr) {
    throw std::runtime_error("deviceCtx() called on host-only queue");
  }
  return {.queueBuf = reinterpret_cast<uintptr_t>(deviceHandle_->queueBuf),
          .rptr = reinterpret_cast<uintptr_t>(deviceHandle_->rptr),
          .wptr = reinterpret_cast<uintptr_t>(deviceHandle_->wptr),
          .doorbell = reinterpret_cast<uintptr_t>(deviceHandle_->doorbell),
          .cachedWptr = reinterpret_cast<uintptr_t>(deviceHandle_->cachedWptr),
          .committedWptr = reinterpret_cast<uintptr_t>(deviceHandle_->committedWptr)};
}

SdmaQueueHostHandle SdmaQueue::hostHandle() const {
  return SdmaQueueHostHandle(const_cast<SdmaQueue*>(this));
}

void SdmaQueue::dump(std::ofstream& logFile) {
  logFile << "Queue "
          //  << " -> " << remoteDeviceId_ << ": "
          << "wptr: " << *deviceHandle_->wptr << ", "
          << "rptr: " << *deviceHandle_->rptr << ", "
          << "doorbell: " << *deviceHandle_->doorbell << ", "
          << "Queue cmd buffer address: " << deviceHandle_->queueBuf << ", "
          << "committedWptr: " << *deviceHandle_->committedWptr << ", "
          << "pendingWptr: " << *deviceHandle_->cachedWptr << ", " << std::endl;

  size_t dw_enqueued = std::min(*deviceHandle_->wptr,
                                (uint64_t)SDMA_QUEUE_SIZE) /
                       sizeof(uint32_t);
  size_t it = 0;
  uint32_t* dwPtr = deviceHandle_->queueBuf;
  uint64_t wrapped_rptr = *deviceHandle_->rptr % SDMA_QUEUE_SIZE;
  uint64_t wrapped_wptr = *deviceHandle_->wptr % SDMA_QUEUE_SIZE;

  logFile << "valid dw: " << dw_enqueued << "\nwrapped rptr : " << wrapped_rptr
          << " dw rptr: " << wrapped_rptr / sizeof(uint32_t)
          << "\nwrapper wptr " << wrapped_wptr
          << " dw wptr: " << wrapped_wptr / sizeof(uint32_t) << std::endl;
  while (it < dw_enqueued) {
    logFile << "[" << it << "] ";
    uint32_t opcode = *dwPtr & 0xFF;
    [[maybe_unused]] uint32_t subop = (*dwPtr >> 8) & 0xFF;
    if (opcode == SDMA_OP_COPY) {
#if XIO_SDMA_OSS7
      if (subop == SDMA_SUBOP_COPY_LINEAR_PHY_MI4) {
        auto* ptr = reinterpret_cast<SDMA_PKT_COPY_LINEAR_PHY_MI4*>(dwPtr);
        logFile << *ptr;
        constexpr size_t dw = sizeof(SDMA_PKT_COPY_LINEAR_PHY_MI4) /
                              sizeof(uint32_t);
        it += dw;
        dwPtr += dw;
      } else if (subop == SDMA_SUBOP_COPY_LINEAR_WAIT_SIGNAL_MI4) {
        auto* ptr = reinterpret_cast<SDMA_PKT_COPY_LINEAR_WAIT_SIGNAL_MI4*>(
          dwPtr);
        logFile << *ptr;
        constexpr size_t dw = sizeof(SDMA_PKT_COPY_LINEAR_WAIT_SIGNAL_MI4) /
                              sizeof(uint32_t);
        it += dw;
        dwPtr += dw;
      } else
#endif /* XIO_SDMA_OSS7 */
      {
        auto* ptr = reinterpret_cast<SDMA_PKT_COPY_LINEAR*>(dwPtr);
        logFile << *ptr;
        size_t dw = sizeof(SDMA_PKT_COPY_LINEAR) / sizeof(uint32_t);
        it += dw;
        dwPtr += dw;
      }
    } else if (opcode == SDMA_OP_ATOMIC) {
      auto* ptr = reinterpret_cast<SDMA_PKT_ATOMIC*>(dwPtr);
      logFile << *ptr;
      size_t dw = sizeof(SDMA_PKT_ATOMIC) / sizeof(uint32_t);
      it += dw;
      dwPtr += dw;
#if XIO_SDMA_OSS7
    } else if (opcode == SDMA_OP_FENCE && subop == SDMA_SUBOP_FENCE_MI4) {
      auto* ptr = reinterpret_cast<SDMA_PKT_FENCE_MI4*>(dwPtr);
      logFile << *ptr;
      constexpr size_t dw = sizeof(SDMA_PKT_FENCE_MI4) / sizeof(uint32_t);
      it += dw;
      dwPtr += dw;
#endif /* XIO_SDMA_OSS7 */
    } else {
      logFile << *dwPtr << std::endl;
      dwPtr++;
      it++;
    }
    logFile << std::endl;
  }
  logFile << "Queue "
          //  << " -> " << remoteDeviceId_ << ": "
          << "wptr: " << *deviceHandle_->wptr << ", "
          << "rptr: " << *deviceHandle_->rptr << ", "
          << "doorbell: " << *deviceHandle_->doorbell << ", "
          << "Queue cmd buffer address: " << deviceHandle_->queueBuf << ", "
          << "committedWptr: " << *deviceHandle_->committedWptr << ", "
          << "pendingWptr: " << *deviceHandle_->cachedWptr << ", " << std::endl;
}

AnvilLib::~AnvilLib() {
  for (auto& p : sdma_channels_) {
    p.second.clear();
  }
  for (auto& p : host_sdma_channels_) {
    p.second.clear();
  }
  if (s_kfd_opened) {
    CloseKFD();
    hsa_shut_down();
  }
}

void AnvilLib::init() {
  std::call_once(init_flag, []() {
    //   std::atexit(CloseKFD); // Register cleanup

    // HSA
    hsa_status_t status{hsa_init()};
    if (status != HSA_STATUS_SUCCESS) {
      printf("Failure to open HSA connection: 0x%x", status);
      // return 1;
    }
    status = hsa_iterate_agents(&rocm_hsa_gpu_agent_callback, &gpuAgents_);
    if (status != HSA_STATUS_SUCCESS && status != HSA_STATUS_INFO_BREAK) {
      printf("Failure to iterate HSA agents: 0x%x", status);
      // return 1;
    }
    status = hsa_iterate_agents(&rocm_hsa_cpu_agent_callback, &cpuAgents_);
    if (status != HSA_STATUS_SUCCESS && status != HSA_STATUS_INFO_BREAK) {
      printf("Failure to iterate HSA agents: 0x%x", status);
      // return 1;
    }

    SetUpKFD();
    s_kfd_opened = true;
  });
}

SdmaQueue* AnvilLib::createSdmaQueue(int srcDeviceId, int dstDeviceId,
                                     uint32_t engineId, int* channelIdx) {
  auto& vec = sdma_channels_[dstDeviceId];
  vec.emplace_back(std::make_unique<SdmaQueue>(srcDeviceId, dstDeviceId,
                                               gpuAgents_[srcDeviceId],
                                               engineId));
  if (channelIdx)
    *channelIdx = static_cast<int>(vec.size() - 1);
  return vec.back().get();
}

bool AnvilLib::connect(int srcDeviceId, int dstDeviceId, int numChannels, bool allocateOnHost) {
  // Use separate storage based on allocation type
  auto& channels = allocateOnHost ? host_sdma_channels_ : sdma_channels_;

  // Check if already connected (idempotent - reuse existing queue 0)
  if (channels.find(dstDeviceId) != channels.end() && !channels[dstDeviceId].empty()) {
    return true; // Already connected
  }

  uint32_t engineId = getSdmaEngineId(srcDeviceId, dstDeviceId);
  std::cout << "Connect from " << srcDeviceId << " to " << dstDeviceId
            << " with 1 channel using engine " << engineId
            << (allocateOnHost ? " (host allocation)" : " (device allocation)")
            << std::endl;

  // Create exactly one channel (queue 0)
  channels[dstDeviceId].emplace_back(
      std::make_unique<SdmaQueue>(srcDeviceId, dstDeviceId, gpuAgents_[srcDeviceId],
                                  engineId, allocateOnHost));

  return true;
}

SdmaQueue* AnvilLib::getSdmaQueue(int srcDeviceId, int dstDeviceId,
                                  int channel_idx) {
  if (sdma_channels_.find(dstDeviceId) == sdma_channels_.end()) {
    return nullptr;
  }

  const auto& channels = sdma_channels_[dstDeviceId];
  if (channel_idx < 0 || static_cast<size_t>(channel_idx) >= channels.size()) {
    return nullptr;
  }

  return channels[static_cast<size_t>(channel_idx)].get();
}

AnvilLib& AnvilLib::getInstance() {
  static AnvilLib instance;
  return instance;
}

int AnvilLib::getOamId(int deviceId) {
  std::string busId = getBusId(deviceId);
  std::string file_str = "/sys/bus/pci/devices/" + busId + "/xgmi_physical_id";
  std::ifstream file(file_str);
  int xgmi_physical_id;
  if (file.is_open()) {
    if (!(file >> xgmi_physical_id)) {
      throw std::runtime_error("Failed to read xGMI physical id from file: " +
                               file_str);
    }
  } else {
    throw std::runtime_error("Failed to open file: " + file_str);
  }
  return xgmi_physical_id;
}

int AnvilLib::getSdmaEngineId(int srcDeviceId, int dstDeviceId) {
  int srcOamId = getOamId(srcDeviceId);
  int dstOamId = getOamId(dstDeviceId);

  // Use even engines only
  return mi300xOamMap[srcOamId][dstOamId] * 2;
}

// ==================== Host API Methods ====================

SdmaQueuePythonDeviceCtx AnvilLib::get_queue_device_ctx(int srcDeviceId, int dstDeviceId) {
  SdmaQueue* queue = getSdmaQueue(srcDeviceId, dstDeviceId, 0);
  if (!queue) {
    throw std::runtime_error("get_queue_device_ctx: queue not found");
  }
  return queue->deviceCtx();
}

SdmaQueueHostHandle AnvilLib::getHostHandle(int srcDeviceId, int dstDeviceId, int channelIdx) {
  // Try host channels first, then device channels
  auto& host_channels = host_sdma_channels_;
  if (host_channels.find(dstDeviceId) != host_channels.end() &&
      static_cast<size_t>(channelIdx) < host_channels[dstDeviceId].size()) {
    return host_channels[dstDeviceId][channelIdx]->hostHandle();
  }

  // Fallback to device channels
  SdmaQueue* queue = getSdmaQueue(srcDeviceId, dstDeviceId, channelIdx);
  if (!queue) {
    throw std::runtime_error("getHostHandle: queue not found");
  }
  return queue->hostHandle();
}

void AnvilLib::host_put(int srcDevice, int dstDevice, int channelIdx, void* src, void* dst, size_t size) {
  SdmaQueueHostHandle handle = getHostHandle(srcDevice, dstDevice, channelIdx);
  handle.put(src, dst, size);
}

template <typename T>
void AnvilLib::host_atomic_add(int srcDevice, int dstDevice, int channelIdx, T* ptr, T value) {
  SdmaQueueHostHandle handle = getHostHandle(srcDevice, dstDevice, channelIdx);
  handle.atomic_add(ptr, value);
}

void AnvilLib::host_atomic_add_u32(int srcDevice, int dstDevice, int channelIdx, void* ptr, uint32_t value) {
  host_atomic_add(srcDevice, dstDevice, channelIdx, static_cast<uint32_t*>(ptr), value);
}

void AnvilLib::host_atomic_add_u64(int srcDevice, int dstDevice, int channelIdx, void* ptr, uint64_t value) {
  host_atomic_add(srcDevice, dstDevice, channelIdx, static_cast<uint64_t*>(ptr), value);
}

void AnvilLib::host_timestamp(int srcDevice, int dstDevice, int channelIdx, void* timestamp_ptr) {
  SdmaQueueHostHandle handle = getHostHandle(srcDevice, dstDevice, channelIdx);
  handle.timestamp(static_cast<uint64_t*>(timestamp_ptr));
}

void AnvilLib::host_put_tile(int srcDevice, int dstDevice, int channelIdx, const Tile& tile, void* dst_ptr,
                             size_t dst_stride) {
  SdmaQueueHostHandle handle = getHostHandle(srcDevice, dstDevice, channelIdx);
  handle.put_tile(tile, dst_ptr, dst_stride);
}

void AnvilLib::host_put_signal_u32(int srcDevice, int dstDevice, int channelIdx, void* src, void* dst, size_t size,
                                   void* flag_ptr, uint32_t flag_value) {
  SdmaQueueHostHandle handle = getHostHandle(srcDevice, dstDevice, channelIdx);
  handle.put_signal(src, dst, size, static_cast<uint32_t*>(flag_ptr), flag_value);
}

void AnvilLib::host_put_tile_signal_u32(int srcDevice, int dstDevice, int channelIdx, const Tile& tile, void* dst_ptr,
                                        size_t dst_stride, void* flag_ptr, uint32_t flag_value) {
  SdmaQueueHostHandle handle = getHostHandle(srcDevice, dstDevice, channelIdx);
  handle.put_tile_signal(tile, dst_ptr, dst_stride, static_cast<uint32_t*>(flag_ptr), flag_value);
}

void AnvilLib::host_wait_flag_then_put_u32(int srcDevice, int dstDevice, int channelIdx, void* flag_ptr,
                                           uint32_t expected_value, void* src, void* dst, size_t size) {
  SdmaQueueHostHandle handle = getHostHandle(srcDevice, dstDevice, channelIdx);
  handle.wait_flag_then_put(static_cast<uint32_t*>(flag_ptr), expected_value, src, dst, size);
}

void AnvilLib::host_wait_flag_then_put_tile_u32(int srcDevice, int dstDevice, int channelIdx, void* flag_ptr,
                                                uint32_t expected_value, const Tile& tile, void* dst_ptr,
                                                size_t dst_stride) {
  SdmaQueueHostHandle handle = getHostHandle(srcDevice, dstDevice, channelIdx);
  handle.wait_flag_then_put_tile(static_cast<uint32_t*>(flag_ptr), expected_value, tile, dst_ptr, dst_stride);
}

void AnvilLib::host_wait_flag_then_put_tiles_u32(int srcDevice, int dstDevice, int channelIdx, void* flag_ptr,
                                                 uint32_t expected_value, const std::vector<Tile>& tiles,
                                                 const std::vector<void*>& dst_ptrs,
                                                 const std::vector<size_t>& dst_strides) {
  SdmaQueueHostHandle handle = getHostHandle(srcDevice, dstDevice, channelIdx);
  handle.wait_flag_then_put_tiles(static_cast<uint32_t*>(flag_ptr), expected_value, tiles, dst_ptrs, dst_strides);
}

void AnvilLib::host_quiet(int srcDevice, int dstDevice, int channelIdx) {
  SdmaQueueHostHandle handle = getHostHandle(srcDevice, dstDevice, channelIdx);
  handle.quiet();
}

AnvilLib& anvil = anvil.getInstance();

} // namespace anvil
