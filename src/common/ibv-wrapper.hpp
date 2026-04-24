/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/ibv_wrapper.hpp, adapted for rocm-xio.
 * Canonical location for the InfiniBand verbs wrapper used by rdma-ep.
 * All libibverbs calls are resolved at runtime via dlopen -- no link
 * dependency.
 */

#ifndef ROCM_XIO_IBV_WRAPPER_HPP
#define ROCM_XIO_IBV_WRAPPER_HPP

#include <map>

#include <sys/types.h>

#include "ibv-core.hpp"

namespace xio {
namespace rdma_ep {

class IBVWrapper {
public:
  explicit IBVWrapper();
  virtual ~IBVWrapper();

  bool is_initialized{false};

  int is_dmabuf_supported();

  struct ibv_device** get_device_list(int* num_devices);
  void free_device_list(struct ibv_device** list);

  struct ibv_context* open_device(struct ibv_device* device);
  int close_device(struct ibv_context* context);

  const char* get_device_name(struct ibv_device* device);
  int query_device(struct ibv_context* context,
                   struct ibv_device_attr* device_attr);
  int query_port(struct ibv_context* context, uint8_t port_num,
                 struct ibv_port_attr* port_attr);
  ssize_t query_gid_table(struct ibv_context* context,
                          struct ibv_gid_entry* entries, size_t max_entries,
                          uint32_t flags);
  int query_gid(struct ibv_context* context, uint8_t port_num, int index,
                union ibv_gid* gid);

  struct ibv_pd* alloc_pd(struct ibv_context* context);
  struct ibv_pd* alloc_parent_domain(struct ibv_context* context,
                                     struct ibv_parent_domain_init_attr* attr);
  int dealloc_pd(struct ibv_pd* pd);

  struct ibv_mr* reg_mr(struct ibv_pd* pd, void* addr, size_t length,
                        int access);
  struct ibv_mr* reg_mr_host(struct ibv_pd* pd, void* addr, size_t length,
                             int access);
  int dereg_mr(struct ibv_mr* mr);

  struct ibv_cq* create_cq(struct ibv_context* context, int cqe,
                           void* cq_context, struct ibv_comp_channel* channel,
                           int comp_vector);
  struct ibv_cq_ex* create_cq_ex(struct ibv_context* context,
                                 struct ibv_cq_init_attr_ex* cq_attr);
  struct ibv_cq* cq_ex_to_cq(struct ibv_cq_ex* cq);
  int destroy_cq(struct ibv_cq* cq);

  struct ibv_qp* create_qp_ex(struct ibv_context* context,
                              struct ibv_qp_init_attr_ex* qp_init_attr);
  int modify_qp(struct ibv_qp* qp, struct ibv_qp_attr* attr, int attr_mask);
  int destroy_qp(struct ibv_qp* qp);

private:
  struct ibv_funcs_t {
    struct ibv_device** (*get_device_list)(int* num_devices);
    void (*free_device_list)(struct ibv_device** list);

    struct ibv_context* (*open_device)(struct ibv_device* device);
    int (*close_device)(struct ibv_context* context);

    const char* (*get_device_name)(struct ibv_device* device);
    int (*query_device)(struct ibv_context* context,
                        struct ibv_device_attr* device_attr);
    int (*query_port)(struct ibv_context* context, uint8_t port_num,
                      struct ibv_port_attr* port_attr);
    ssize_t (*query_gid_table)(struct ibv_context* context,
                               struct ibv_gid_entry* entries,
                               size_t max_entries, uint32_t flags,
                               size_t entry_size);
    int (*query_gid)(struct ibv_context* context, uint8_t port_num, int index,
                     union ibv_gid* gid);

    struct ibv_pd* (*alloc_pd)(struct ibv_context* context);
    struct ibv_pd* (*alloc_parent_domain)(
      struct ibv_context* context, struct ibv_parent_domain_init_attr* attr);
    int (*dealloc_pd)(struct ibv_pd* pd);

    struct ibv_mr* (*reg_mr)(struct ibv_pd* pd, void* addr, size_t length,
                             int access);
    struct ibv_mr* (*reg_dmabuf_mr)(struct ibv_pd* pd, uint64_t offset,
                                    size_t length, uint64_t iova, int fd,
                                    int access);
    struct ibv_mr* (*reg_mr_iova2)(struct ibv_pd* pd, void* addr, size_t length,
                                   uint64_t iova, unsigned int access);
    int (*dereg_mr)(struct ibv_mr* mr);

    struct ibv_cq* (*create_cq)(struct ibv_context* context, int cqe,
                                void* cq_context,
                                struct ibv_comp_channel* channel,
                                int comp_vector);
    struct ibv_cq_ex* (*create_cq_ex)(struct ibv_context* context,
                                      struct ibv_cq_init_attr_ex* cq_attr);
    int (*destroy_cq)(struct ibv_cq* cq);

    struct ibv_qp* (*create_qp)(struct ibv_pd* pd,
                                struct ibv_qp_init_attr* qp_init_attr);
    int (*modify_qp)(struct ibv_qp* qp, struct ibv_qp_attr* attr,
                     int attr_mask);
    int (*destroy_qp)(struct ibv_qp* qp);
  };

  struct ibv_funcs_t funcs_ {};
  void* ibv_handle_{nullptr};

  int init_function_table();
  void init_dmabuf_support_flag();

  int dmabuf_is_supported_{-1};
  bool dmabuf_enabled_{true};

  std::map<uintptr_t, int> dmabuf_fd_map_;
};

extern IBVWrapper ibv;

} // namespace rdma_ep
} // namespace xio

#endif // ROCM_XIO_IBV_WRAPPER_HPP
