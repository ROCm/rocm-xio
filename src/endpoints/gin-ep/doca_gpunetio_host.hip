/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>
#include <string>
#include <unordered_map>

#include "doca_gpunetio_high_level.hip.h"
#include "doca_gpunetio_host.hip.h"
#include "hip/hip_runtime.h"

struct doca_gpu {
  int device_ordinal;
  std::string pci_bus_id;
};

namespace {

struct AllocationRecord {
  enum doca_gpu_mem_type type;
  void* gpu_ptr;
  void* cpu_ptr;
};

std::mutex g_alloc_mu;
std::unordered_map<void*, AllocationRecord> g_allocs;

bool isPowerOfTwo(size_t value) {
  return value != 0 && (value & (value - 1)) == 0;
}

doca_error_t fromHipError(hipError_t err) {
  if (err == hipSuccess)
    return DOCA_SUCCESS;
  if (err == hipErrorOutOfMemory)
    return DOCA_ERROR_NO_MEMORY;
  return DOCA_ERROR_DRIVER;
}

doca_error_t setU16(uint16_t* out, uint32_t value) {
  if (out == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  if (value > 0xffffU)
    return DOCA_ERROR_INVALID_VALUE;
  *out = static_cast<uint16_t>(value);
  return DOCA_SUCCESS;
}

doca_error_t notSupported() {
  return DOCA_ERROR_NOT_SUPPORTED;
}

} // namespace

extern "C" {

doca_error_t doca_gpu_create(const char* gpu_bus_id,
                             struct doca_gpu** gpu_dev) {
  if (gpu_dev == nullptr || gpu_bus_id == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  *gpu_dev = nullptr;

  int device_count = 0;
  hipError_t err = hipGetDeviceCount(&device_count);
  if (err != hipSuccess)
    return fromHipError(err);

  int selected = -1;
  char bus_id[32] = {0};
  for (int d = 0; d < device_count; ++d) {
    if (hipDeviceGetPCIBusId(bus_id, sizeof(bus_id), d) != hipSuccess)
      continue;
    if (std::strcmp(bus_id, gpu_bus_id) == 0) {
      selected = d;
      break;
    }
  }
  if (selected < 0)
    return DOCA_ERROR_NOT_FOUND;

  doca_gpu* gpu = new (std::nothrow) doca_gpu();
  if (gpu == nullptr)
    return DOCA_ERROR_NO_MEMORY;
  gpu->device_ordinal = selected;
  gpu->pci_bus_id = gpu_bus_id;
  *gpu_dev = gpu;
  return DOCA_SUCCESS;
}

doca_error_t doca_gpu_destroy(struct doca_gpu* gpu_dev) {
  if (gpu_dev == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  delete gpu_dev;
  return DOCA_SUCCESS;
}

doca_error_t doca_gpu_mem_alloc(struct doca_gpu* gpu_dev, size_t size,
                                size_t alignment, enum doca_gpu_mem_type mtype,
                                void** memptr_gpu, void** memptr_cpu) {
  if (gpu_dev == nullptr || memptr_gpu == nullptr || size == 0)
    return DOCA_ERROR_INVALID_VALUE;
  if (alignment != 0 && !isPowerOfTwo(alignment))
    return DOCA_ERROR_INVALID_VALUE;

  *memptr_gpu = nullptr;
  if (memptr_cpu != nullptr)
    *memptr_cpu = nullptr;

  int current_device = -1;
  hipError_t err = hipGetDevice(&current_device);
  if (err != hipSuccess)
    return fromHipError(err);
  err = hipSetDevice(gpu_dev->device_ordinal);
  if (err != hipSuccess)
    return fromHipError(err);

  void* gpu_ptr = nullptr;
  void* cpu_ptr = nullptr;
  doca_error_t status = DOCA_SUCCESS;

  switch (mtype) {
    case DOCA_GPU_MEM_TYPE_GPU:
      err = hipMalloc(&gpu_ptr, size);
      status = fromHipError(err);
      break;
    case DOCA_GPU_MEM_TYPE_GPU_CPU:
      err = hipMallocManaged(&gpu_ptr, size, hipMemAttachGlobal);
      cpu_ptr = gpu_ptr;
      status = fromHipError(err);
      break;
    case DOCA_GPU_MEM_TYPE_CPU_GPU:
      err = hipHostMalloc(&cpu_ptr, size, hipHostMallocMapped);
      if (err == hipSuccess)
        err = hipHostGetDevicePointer(&gpu_ptr, cpu_ptr, 0);
      status = fromHipError(err);
      if (status != DOCA_SUCCESS && cpu_ptr != nullptr) {
        static_cast<void>(hipHostFree(cpu_ptr));
        cpu_ptr = nullptr;
      }
      break;
    default:
      status = DOCA_ERROR_INVALID_VALUE;
      break;
  }

  static_cast<void>(hipSetDevice(current_device));
  if (status != DOCA_SUCCESS)
    return status;

  {
    std::lock_guard<std::mutex> lk(g_alloc_mu);
    g_allocs[gpu_ptr] = AllocationRecord{mtype, gpu_ptr, cpu_ptr};
  }

  *memptr_gpu = gpu_ptr;
  if (memptr_cpu != nullptr)
    *memptr_cpu = cpu_ptr;
  return DOCA_SUCCESS;
}

doca_error_t doca_gpu_mem_free(struct doca_gpu* gpu, void* memptr_gpu) {
  if (gpu == nullptr || memptr_gpu == nullptr)
    return DOCA_ERROR_INVALID_VALUE;

  AllocationRecord rec{};
  {
    std::lock_guard<std::mutex> lk(g_alloc_mu);
    auto it = g_allocs.find(memptr_gpu);
    if (it == g_allocs.end())
      return DOCA_ERROR_NOT_FOUND;
    rec = it->second;
    g_allocs.erase(it);
  }

  int current_device = -1;
  hipError_t err = hipGetDevice(&current_device);
  if (err != hipSuccess)
    return fromHipError(err);
  err = hipSetDevice(gpu->device_ordinal);
  if (err != hipSuccess)
    return fromHipError(err);

  if (rec.type == DOCA_GPU_MEM_TYPE_CPU_GPU) {
    err = hipHostFree(rec.cpu_ptr);
  } else {
    err = hipFree(rec.gpu_ptr);
  }

  static_cast<void>(hipSetDevice(current_device));
  return fromHipError(err);
}

doca_error_t doca_gpu_verbs_export_qp(
  struct doca_gpu* gpu_dev, struct doca_verbs_qp* qp,
  doca_gpu_dev_verbs_nic_handler nic_handler, void* gpu_qp_umem_dev_ptr,
  struct doca_verbs_cq* cq_sq,
  enum doca_gpu_verbs_send_dbr_mode_ext send_dbr_mode_ext,
  struct doca_gpu_verbs_qp** qp_out) {
  (void)gpu_dev;
  (void)qp;
  (void)nic_handler;
  (void)gpu_qp_umem_dev_ptr;
  (void)cq_sq;
  (void)send_dbr_mode_ext;
  if (qp_out == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  *qp_out = nullptr;
  return notSupported();
}

doca_error_t doca_gpu_verbs_unexport_qp(struct doca_gpu* gpu_dev,
                                        struct doca_gpu_verbs_qp* qp) {
  (void)gpu_dev;
  (void)qp;
  return notSupported();
}

doca_error_t doca_gpu_verbs_get_qp_dev(struct doca_gpu_verbs_qp* qp,
                                       struct radaki_dev_qp** qp_gpu) {
  if (qp == nullptr || qp_gpu == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  *qp_gpu = qp->qp_gpu;
  return DOCA_SUCCESS;
}

doca_error_t doca_gpu_dmabuf_fd(struct doca_gpu* gpu_dev, void* memptr_gpu,
                                size_t size, int* dmabuf_fd) {
  (void)gpu_dev;
  (void)memptr_gpu;
  (void)size;
  if (dmabuf_fd == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  *dmabuf_fd = -1;
  return notSupported();
}

doca_error_t doca_gpu_verbs_can_gpu_register_uar(void* db,
                                                 bool* out_can_register) {
  (void)db;
  if (out_can_register == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  *out_can_register = false;
  return DOCA_SUCCESS;
}

doca_error_t doca_gpu_verbs_export_uar(uint64_t* sq_db,
                                       uint64_t** uar_addr_gpu) {
  if (sq_db == nullptr || uar_addr_gpu == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  *uar_addr_gpu = nullptr;
  return notSupported();
}

doca_error_t doca_gpu_verbs_unexport_uar(uint64_t* uar_addr_gpu) {
  (void)uar_addr_gpu;
  return DOCA_SUCCESS;
}

doca_error_t doca_gpu_verbs_cpu_proxy_progress(
  struct doca_gpu_verbs_qp* qp_cpu) {
  if (qp_cpu == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  if (qp_cpu->sq_db == nullptr || qp_cpu->cpu_db == nullptr)
    return DOCA_SUCCESS;
  const uint64_t db = ((qp_cpu->sq_wqe_pi_last & 0x00ffffffULL) << 8) |
                      static_cast<uint64_t>(
                        __builtin_bswap32(qp_cpu->sq_num_shift8_be));
  *qp_cpu->sq_db = db;
  *qp_cpu->cpu_db = qp_cpu->sq_wqe_pi_last;
  return DOCA_SUCCESS;
}

doca_error_t doca_gpu_verbs_create_service(
  doca_gpu_verbs_service_t* out_service) {
  if (out_service == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  *out_service = nullptr;
  return notSupported();
}

doca_error_t doca_gpu_verbs_service_monitor_qp(doca_gpu_verbs_service_t service,
                                               struct doca_gpu_verbs_qp* qp) {
  (void)service;
  (void)qp;
  return notSupported();
}

doca_error_t doca_gpu_verbs_destroy_service(doca_gpu_verbs_service_t service) {
  (void)service;
  return DOCA_SUCCESS;
}

doca_error_t doca_gpu_verbs_query_last_error(
  struct doca_gpu_verbs_qp* qp,
  struct doca_gpu_verbs_qp_error_info* error_info) {
  if (qp == nullptr || error_info == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  std::memset(error_info, 0, sizeof(*error_info));
  return DOCA_SUCCESS;
}

doca_error_t doca_gpu_verbs_export_multi_qps_dev(
  struct doca_gpu* gpu_dev, struct doca_gpu_verbs_qp** qps,
  unsigned int num_qps, struct radaki_dev_qp** out_qp_gpus) {
  (void)gpu_dev;
  (void)qps;
  (void)num_qps;
  if (out_qp_gpus == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  *out_qp_gpus = nullptr;
  return notSupported();
}

doca_error_t doca_gpu_verbs_unexport_multi_qps_dev(
  struct doca_gpu* gpu_dev, struct doca_gpu_verbs_qp** qps,
  unsigned int num_qps, struct radaki_dev_qp* qp_gpus) {
  (void)gpu_dev;
  (void)qps;
  (void)num_qps;
  (void)qp_gpus;
  return notSupported();
}

doca_error_t doca_verbs_qp_attr_create(
  struct doca_verbs_qp_attr** verbs_qp_attr) {
  if (verbs_qp_attr == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  *verbs_qp_attr = static_cast<doca_verbs_qp_attr*>(
    std::calloc(1, sizeof(struct doca_verbs_qp_attr)));
  if (*verbs_qp_attr == nullptr)
    return DOCA_ERROR_NO_MEMORY;
  return DOCA_SUCCESS;
}

doca_error_t doca_verbs_qp_attr_destroy(
  struct doca_verbs_qp_attr* verbs_qp_attr) {
  std::free(verbs_qp_attr);
  return DOCA_SUCCESS;
}

doca_error_t doca_verbs_qp_attr_set_next_state(
  struct doca_verbs_qp_attr* verbs_qp_attr,
  enum doca_verbs_qp_state next_state) {
  if (verbs_qp_attr == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  verbs_qp_attr->next_state = next_state;
  return DOCA_SUCCESS;
}

doca_error_t doca_verbs_qp_attr_set_path_mtu(
  struct doca_verbs_qp_attr* verbs_qp_attr, enum doca_verbs_mtu_size path_mtu) {
  if (verbs_qp_attr == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  verbs_qp_attr->path_mtu = path_mtu;
  return DOCA_SUCCESS;
}

doca_error_t doca_verbs_qp_attr_set_rq_psn(
  struct doca_verbs_qp_attr* verbs_qp_attr, uint32_t rq_psn) {
  if (verbs_qp_attr == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  verbs_qp_attr->rq_psn = rq_psn;
  return DOCA_SUCCESS;
}

doca_error_t doca_verbs_qp_attr_set_sq_psn(
  struct doca_verbs_qp_attr* verbs_qp_attr, uint32_t sq_psn) {
  if (verbs_qp_attr == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  verbs_qp_attr->sq_psn = sq_psn;
  return DOCA_SUCCESS;
}

doca_error_t doca_verbs_qp_attr_set_port_num(
  struct doca_verbs_qp_attr* verbs_qp_attr, uint16_t port_num) {
  if (verbs_qp_attr == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  return setU16(&verbs_qp_attr->port_num, port_num);
}

doca_error_t doca_verbs_qp_attr_set_ack_timeout(
  struct doca_verbs_qp_attr* verbs_qp_attr, uint16_t ack_timeout) {
  if (verbs_qp_attr == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  return setU16(&verbs_qp_attr->ack_timeout, ack_timeout);
}

doca_error_t doca_verbs_qp_attr_set_retry_cnt(
  struct doca_verbs_qp_attr* verbs_qp_attr, uint16_t retry_cnt) {
  if (verbs_qp_attr == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  return setU16(&verbs_qp_attr->retry_cnt, retry_cnt);
}

doca_error_t doca_verbs_qp_attr_set_rnr_retry(
  struct doca_verbs_qp_attr* verbs_qp_attr, uint16_t rnr_retry) {
  if (verbs_qp_attr == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  return setU16(&verbs_qp_attr->rnr_retry, rnr_retry);
}

doca_error_t doca_verbs_qp_attr_set_min_rnr_timer(
  struct doca_verbs_qp_attr* verbs_qp_attr, uint16_t min_rnr_timer) {
  if (verbs_qp_attr == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  return setU16(&verbs_qp_attr->min_rnr_timer, min_rnr_timer);
}

doca_error_t doca_verbs_qp_attr_set_allow_remote_write(
  struct doca_verbs_qp_attr* verbs_qp_attr, int allow_remote_write) {
  if (verbs_qp_attr == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  verbs_qp_attr->allow_remote_write = allow_remote_write ? 1 : 0;
  return DOCA_SUCCESS;
}

doca_error_t doca_verbs_qp_attr_set_allow_remote_read(
  struct doca_verbs_qp_attr* verbs_qp_attr, int allow_remote_read) {
  if (verbs_qp_attr == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  verbs_qp_attr->allow_remote_read = allow_remote_read ? 1 : 0;
  return DOCA_SUCCESS;
}

doca_error_t doca_verbs_qp_attr_set_allow_remote_atomic(
  struct doca_verbs_qp_attr* verbs_qp_attr,
  enum doca_verbs_qp_atomic_type allow_remote_atomic) {
  if (verbs_qp_attr == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  verbs_qp_attr->allow_remote_atomic = allow_remote_atomic;
  return DOCA_SUCCESS;
}

doca_error_t doca_verbs_qp_attr_set_ah_attr(
  struct doca_verbs_qp_attr* verbs_qp_attr,
  struct doca_verbs_ah_attr* verbs_ah) {
  if (verbs_qp_attr == nullptr || verbs_ah == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  verbs_qp_attr->ah_attr = verbs_ah;
  return DOCA_SUCCESS;
}

doca_error_t doca_verbs_qp_attr_set_dest_qp_num(
  struct doca_verbs_qp_attr* verbs_qp_attr, uint32_t dest_qp_num) {
  if (verbs_qp_attr == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  verbs_qp_attr->dest_qp_num = dest_qp_num;
  return DOCA_SUCCESS;
}

doca_error_t doca_verbs_qp_attr_set_pkey_index(
  struct doca_verbs_qp_attr* verbs_qp_attr, uint16_t pkey_index) {
  if (verbs_qp_attr == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  return setU16(&verbs_qp_attr->pkey_index, pkey_index);
}

doca_error_t doca_verbs_qp_modify(struct doca_verbs_qp* qp,
                                  struct doca_verbs_qp_attr* verbs_qp_attr,
                                  uint64_t attr_mask) {
  (void)qp;
  (void)verbs_qp_attr;
  (void)attr_mask;
  return notSupported();
}

uint32_t doca_verbs_qp_get_qpn(struct doca_verbs_qp* qp) {
  if (qp == nullptr)
    return 0;
  return qp->qpn;
}

doca_error_t doca_verbs_ah_attr_create(struct ibv_context* context,
                                       struct doca_verbs_ah_attr** verbs_ah) {
  if (verbs_ah == nullptr || context == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  *verbs_ah = static_cast<doca_verbs_ah_attr*>(
    std::calloc(1, sizeof(struct doca_verbs_ah_attr)));
  if (*verbs_ah == nullptr)
    return DOCA_ERROR_NO_MEMORY;
  (*verbs_ah)->context = context;
  return DOCA_SUCCESS;
}

doca_error_t doca_verbs_ah_attr_destroy(struct doca_verbs_ah_attr* verbs_ah) {
  std::free(verbs_ah);
  return DOCA_SUCCESS;
}

doca_error_t doca_verbs_ah_attr_set_gid(struct doca_verbs_ah_attr* verbs_ah,
                                        struct doca_verbs_gid gid) {
  if (verbs_ah == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  std::memcpy(verbs_ah->gid.raw, gid.raw, sizeof(gid.raw));
  verbs_ah->has_gid = true;
  return DOCA_SUCCESS;
}

doca_error_t doca_verbs_ah_attr_set_addr_type(
  struct doca_verbs_ah_attr* verbs_ah, enum doca_verbs_addr_type addr_type) {
  if (verbs_ah == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  verbs_ah->addr_type = addr_type;
  return DOCA_SUCCESS;
}

doca_error_t doca_verbs_ah_attr_set_dlid(struct doca_verbs_ah_attr* verbs_ah,
                                         uint32_t dlid) {
  if (verbs_ah == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  verbs_ah->dlid = dlid;
  return DOCA_SUCCESS;
}

doca_error_t doca_verbs_ah_attr_set_sl(struct doca_verbs_ah_attr* verbs_ah,
                                       uint8_t sl) {
  if (verbs_ah == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  verbs_ah->sl = sl;
  return DOCA_SUCCESS;
}

doca_error_t doca_verbs_ah_attr_set_sgid_index(
  struct doca_verbs_ah_attr* verbs_ah, uint8_t sgid_index) {
  if (verbs_ah == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  verbs_ah->sgid_index = sgid_index;
  return DOCA_SUCCESS;
}

doca_error_t doca_verbs_ah_attr_set_hop_limit(
  struct doca_verbs_ah_attr* verbs_ah, uint8_t hop_limit) {
  if (verbs_ah == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  verbs_ah->hop_limit = hop_limit;
  return DOCA_SUCCESS;
}

doca_error_t doca_verbs_ah_attr_set_traffic_class(
  struct doca_verbs_ah_attr* verbs_ah, uint8_t traffic_class) {
  if (verbs_ah == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  verbs_ah->traffic_class = traffic_class;
  return DOCA_SUCCESS;
}

doca_error_t doca_gpu_verbs_create_qp_hl(
  struct doca_gpu_verbs_qp_init_attr_hl* qp_init_attr,
  struct doca_gpu_verbs_qp_hl** qp) {
  (void)qp_init_attr;
  if (qp == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  *qp = nullptr;
  return notSupported();
}

doca_error_t doca_gpu_verbs_destroy_qp_hl(struct doca_gpu_verbs_qp_hl* qp) {
  (void)qp;
  return DOCA_SUCCESS;
}

doca_error_t doca_gpu_verbs_create_qp_group_hl(
  struct doca_gpu_verbs_qp_init_attr_hl* qp_init_attr,
  struct doca_gpu_verbs_qp_group_hl** qpg) {
  (void)qp_init_attr;
  if (qpg == nullptr)
    return DOCA_ERROR_INVALID_VALUE;
  *qpg = nullptr;
  return notSupported();
}

doca_error_t doca_gpu_verbs_destroy_qp_group_hl(
  struct doca_gpu_verbs_qp_group_hl* qpg) {
  (void)qpg;
  return DOCA_SUCCESS;
}

} // extern "C"
