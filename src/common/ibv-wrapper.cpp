/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/ibv_wrapper.cpp, adapted for rocm-xio.
 */

#include "ibv-wrapper.hpp"

#include <cstdio>
#include <cstring>

#include <dlfcn.h>
#include <hsa/hsa.h>
#include <hsa/hsa_ext_amd.h>
#include <sys/utsname.h>
#include <unistd.h>

namespace rdma_ep {

IBVWrapper ibv;

namespace {

template <typename FuncPtr>
int dlsym_load(FuncPtr& out, void* handle, const char* prefix,
               const char* name) {
  char full_name[256];
  snprintf(full_name, sizeof(full_name), "%s%s", prefix, name);
  out = reinterpret_cast<FuncPtr>(dlsym(handle, full_name));
  if (!out) {
    fprintf(stderr, "rdma_ep: dlsym failed for %s: %s\n", full_name, dlerror());
    return -1;
  }
  return 0;
}

template <typename FuncPtr>
void dlsym_load_optional(FuncPtr& out, void* handle, const char* prefix,
                         const char* name) {
  char full_name[256];
  snprintf(full_name, sizeof(full_name), "%s%s", prefix, name);
  out = reinterpret_cast<FuncPtr>(dlsym(handle, full_name));
}

} // anonymous namespace

IBVWrapper::IBVWrapper() {
#ifdef RDMA_CORE_LIB_DIR
  ibv_handle_ = dlopen(RDMA_CORE_LIB_DIR "/libibverbs.so", RTLD_NOW);
#endif
  if (!ibv_handle_)
    ibv_handle_ = dlopen("libibverbs.so", RTLD_NOW);
  if (!ibv_handle_)
    ibv_handle_ = dlopen("/usr/lib/x86_64-linux-gnu/libibverbs.so", RTLD_NOW);
  if (!ibv_handle_) {
    fprintf(stderr, "rdma_ep: Could not open "
                    "libibverbs.so. "
                    "RDMA endpoint disabled.\n");
    return;
  }

  if (init_function_table() != 0) {
    fprintf(stderr, "rdma_ep: Could not init IBV function table. "
                    "RDMA endpoint disabled.\n");
    return;
  }

  init_dmabuf_support_flag();
  is_initialized = true;
}

IBVWrapper::~IBVWrapper() {
  is_initialized = false;
  if (ibv_handle_) {
    dlclose(ibv_handle_);
  }
}

void IBVWrapper::init_dmabuf_support_flag() {
  if (!dmabuf_enabled_) {
    dmabuf_is_supported_ = 0;
    return;
  }

  if (!funcs_.reg_dmabuf_mr) {
    dmabuf_is_supported_ = 0;
    return;
  }

  const char kernel_opt1[] = "CONFIG_DMABUF_MOVE_NOTIFY=y";
  const char kernel_opt2[] = "CONFIG_PCI_P2PDMA=y";
  int found_opt1 = 0;
  int found_opt2 = 0;
  struct utsname utsname;
  char kernel_conf_file[128];
  char buf[256];

  if (uname(&utsname) == -1) {
    dmabuf_is_supported_ = 0;
    return;
  }

  snprintf(kernel_conf_file, sizeof(kernel_conf_file), "/boot/config-%s",
           utsname.release);
  FILE* fp = fopen(kernel_conf_file, "r");
  if (!fp) {
    dmabuf_is_supported_ = 0;
    return;
  }

  while (fgets(buf, sizeof(buf), fp)) {
    if (strstr(buf, kernel_opt1))
      found_opt1 = 1;
    if (strstr(buf, kernel_opt2))
      found_opt2 = 1;
    if (found_opt1 && found_opt2) {
      dmabuf_is_supported_ = 1;
      fclose(fp);
      return;
    }
  }
  fclose(fp);
  dmabuf_is_supported_ = 0;
}

int IBVWrapper::is_dmabuf_supported() {
  return dmabuf_is_supported_;
}

int IBVWrapper::init_function_table() {
#define LOAD_SYM(field, prefix, name)                                          \
  if (dlsym_load(funcs_.field, ibv_handle_, prefix, name) != 0)                \
    return -1;
#define LOAD_SYM_OPT(field, prefix, name)                                      \
  dlsym_load_optional(funcs_.field, ibv_handle_, prefix, name);

  LOAD_SYM(get_device_list, "ibv_", "get_device_list");
  LOAD_SYM(free_device_list, "ibv_", "free_device_list");
  LOAD_SYM(open_device, "ibv_", "open_device");
  LOAD_SYM(close_device, "ibv_", "close_device");
  LOAD_SYM(get_device_name, "ibv_", "get_device_name");
  LOAD_SYM(query_device, "ibv_", "query_device");
  LOAD_SYM(query_port, "ibv_", "query_port");
  LOAD_SYM(query_gid, "ibv_", "query_gid");
  LOAD_SYM(query_gid_table, "_ibv_", "query_gid_table");
  LOAD_SYM(alloc_pd, "ibv_", "alloc_pd");
  LOAD_SYM(dealloc_pd, "ibv_", "dealloc_pd");
  LOAD_SYM(reg_mr, "ibv_", "reg_mr");
  LOAD_SYM_OPT(reg_dmabuf_mr, "ibv_", "reg_dmabuf_mr");
  LOAD_SYM(reg_mr_iova2, "ibv_", "reg_mr_iova2");
  LOAD_SYM(dereg_mr, "ibv_", "dereg_mr");
  LOAD_SYM(create_cq, "ibv_", "create_cq");
  LOAD_SYM(destroy_cq, "ibv_", "destroy_cq");
  LOAD_SYM(create_qp, "ibv_", "create_qp");
  LOAD_SYM(modify_qp, "ibv_", "modify_qp");
  LOAD_SYM(destroy_qp, "ibv_", "destroy_qp");

#undef LOAD_SYM
#undef LOAD_SYM_OPT
  return 0;
}

struct ibv_device** IBVWrapper::get_device_list(int* num_devices) {
  return funcs_.get_device_list(num_devices);
}

void IBVWrapper::free_device_list(struct ibv_device** list) {
  funcs_.free_device_list(list);
}

struct ibv_context* IBVWrapper::open_device(struct ibv_device* device) {
  return funcs_.open_device(device);
}

int IBVWrapper::close_device(struct ibv_context* context) {
  return funcs_.close_device(context);
}

const char* IBVWrapper::get_device_name(struct ibv_device* device) {
  return funcs_.get_device_name(device);
}

int IBVWrapper::query_device(struct ibv_context* context,
                             struct ibv_device_attr* device_attr) {
  return funcs_.query_device(context, device_attr);
}

int IBVWrapper::query_port(struct ibv_context* context, uint8_t port_num,
                           struct ibv_port_attr* port_attr) {
  struct verbs_context* vctx = verbs_get_ctx_op(context, query_port);
  if (!vctx) {
    memset(port_attr, 0, sizeof(*port_attr));
    return funcs_.query_port(context, port_num, port_attr);
  }
  return vctx->query_port(context, port_num, port_attr, sizeof(*port_attr));
}

ssize_t IBVWrapper::query_gid_table(struct ibv_context* context,
                                    struct ibv_gid_entry* entries,
                                    size_t max_entries, uint32_t flags) {
  return funcs_.query_gid_table(context, entries, max_entries, flags,
                                sizeof(*entries));
}

int IBVWrapper::query_gid(struct ibv_context* context, uint8_t port_num,
                          int index, union ibv_gid* gid) {
  return funcs_.query_gid(context, port_num, index, gid);
}

struct ibv_pd* IBVWrapper::alloc_pd(struct ibv_context* context) {
  return funcs_.alloc_pd(context);
}

struct ibv_pd* IBVWrapper::alloc_parent_domain(
  struct ibv_context* context, struct ibv_parent_domain_init_attr* attr) {
  return ibv_alloc_parent_domain(context, attr);
}

int IBVWrapper::dealloc_pd(struct ibv_pd* pd) {
  return funcs_.dealloc_pd(pd);
}

struct ibv_mr* IBVWrapper::reg_mr(struct ibv_pd* pd, void* addr, size_t length,
                                  int access) {
  if (is_dmabuf_supported()) {
    struct ibv_mr* mr;
    uint64_t offset = 0;
    int fd = 0;

    hsa_status_t status = hsa_amd_portable_export_dmabuf(addr, length, &fd,
                                                         &offset);
    if (status != HSA_STATUS_SUCCESS) {
      fprintf(stderr, "rdma_ep: hsa_amd_portable_export_dmabuf failed: %d\n",
              status);
      return nullptr;
    }

    mr = funcs_.reg_dmabuf_mr(pd, offset, length, (uint64_t)addr, fd, access);
    if (mr)
      dmabuf_fd_map_[(uintptr_t)mr] = fd;

    return mr;
  }

  int is_access_const = __builtin_constant_p(
    ((int)(access)&IBV_ACCESS_OPTIONAL_RANGE) == 0);

  if (is_access_const && (access & IBV_ACCESS_OPTIONAL_RANGE) == 0)
    return funcs_.reg_mr(pd, addr, length, (int)access);
  else
    return funcs_.reg_mr_iova2(pd, addr, length, (uintptr_t)addr, access);
}

struct ibv_mr* IBVWrapper::reg_mr_host(struct ibv_pd* pd, void* addr,
                                       size_t length, int access) {
  int is_access_const = __builtin_constant_p(
    ((int)(access)&IBV_ACCESS_OPTIONAL_RANGE) == 0);
  if (is_access_const && (access & IBV_ACCESS_OPTIONAL_RANGE) == 0)
    return funcs_.reg_mr(pd, addr, length, (int)access);
  else
    return funcs_.reg_mr_iova2(pd, addr, length, (uintptr_t)addr, access);
}

int IBVWrapper::dereg_mr(struct ibv_mr* mr) {
  if (is_dmabuf_supported()) {
    auto it = dmabuf_fd_map_.find((uintptr_t)mr);
    if (it != dmabuf_fd_map_.end()) {
      close(it->second);
      dmabuf_fd_map_.erase(it);
    }
  }
  return funcs_.dereg_mr(mr);
}

struct ibv_cq* IBVWrapper::create_cq(struct ibv_context* context, int cqe,
                                     void* cq_context,
                                     struct ibv_comp_channel* channel,
                                     int comp_vector) {
  return funcs_.create_cq(context, cqe, cq_context, channel, comp_vector);
}

struct ibv_cq_ex* IBVWrapper::create_cq_ex(
  struct ibv_context* context, struct ibv_cq_init_attr_ex* cq_attr) {
  return ibv_create_cq_ex(context, cq_attr);
}

struct ibv_cq* IBVWrapper::cq_ex_to_cq(struct ibv_cq_ex* cq) {
  return ibv_cq_ex_to_cq(cq);
}

int IBVWrapper::destroy_cq(struct ibv_cq* cq) {
  return funcs_.destroy_cq(cq);
}

struct ibv_qp* IBVWrapper::create_qp_ex(
  struct ibv_context* context, struct ibv_qp_init_attr_ex* qp_init_attr_ex) {
  uint32_t mask = qp_init_attr_ex->comp_mask;

  if (mask == IBV_QP_INIT_ATTR_PD)
    return funcs_.create_qp(qp_init_attr_ex->pd,
                            (struct ibv_qp_init_attr*)qp_init_attr_ex);

  struct verbs_context* vctx = verbs_get_ctx_op(context, create_qp_ex);
  if (!vctx) {
    errno = EOPNOTSUPP;
    return nullptr;
  }
  return vctx->create_qp_ex(context, qp_init_attr_ex);
}

int IBVWrapper::modify_qp(struct ibv_qp* qp, struct ibv_qp_attr* attr,
                          int attr_mask) {
  return funcs_.modify_qp(qp, attr, attr_mask);
}

int IBVWrapper::destroy_qp(struct ibv_qp* qp) {
  return funcs_.destroy_qp(qp);
}

} // namespace rdma_ep
