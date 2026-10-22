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

/** @brief Runtime-loaded libibverbs facade used by rdma-ep. */
class IBVWrapper {
public:
  /** @brief Load libibverbs and resolve required symbols. */
  explicit IBVWrapper();

  /** @brief Close the libibverbs handle. */
  virtual ~IBVWrapper();

  bool is_initialized{false}; /**< true when required symbols are resolved. */

  /**
   * @brief Check whether DMA-BUF memory registration is available.
   * @return 1 if supported and enabled, 0 if unavailable, -1 on error.
   */
  int is_dmabuf_supported();

  /**
   * @brief Forward to ibv_get_device_list().
   * @param num_devices Output number of returned devices.
   * @return Null-terminated device list, or nullptr on failure.
   */
  struct ibv_device** get_device_list(int* num_devices);
  /**
   * @brief Forward to ibv_free_device_list().
   * @param list Device list returned by get_device_list().
   */
  void free_device_list(struct ibv_device** list);

  /**
   * @brief Forward to ibv_open_device().
   * @param device Device handle to open.
   * @return Opened verbs context, or nullptr on failure.
   */
  struct ibv_context* open_device(struct ibv_device* device);
  /**
   * @brief Forward to ibv_close_device().
   * @param context Verbs context to close.
   * @return 0 on success, nonzero on failure.
   */
  int close_device(struct ibv_context* context);

  /**
   * @brief Forward to ibv_get_device_name().
   * @param device Device handle to query.
   * @return Provider device name string.
   */
  const char* get_device_name(struct ibv_device* device);
  /**
   * @brief Forward to ibv_query_device().
   * @param context Verbs context to query.
   * @param device_attr Output device attributes.
   * @return 0 on success, nonzero on failure.
   */
  int query_device(struct ibv_context* context,
                   struct ibv_device_attr* device_attr);
  /**
   * @brief Forward to ibv_query_port().
   * @param context Verbs context to query.
   * @param port_num One-based port number.
   * @param port_attr Output port attributes.
   * @return 0 on success, nonzero on failure.
   */
  int query_port(struct ibv_context* context, uint8_t port_num,
                 struct ibv_port_attr* port_attr);
  /**
   * @brief Forward to ibv_query_gid_table().
   * @param context Verbs context to query.
   * @param entries Output GID table entries.
   * @param max_entries Maximum entries in @p entries.
   * @param flags Query flags.
   * @return Number of entries written, or negative errno on failure.
   */
  ssize_t query_gid_table(struct ibv_context* context,
                          struct ibv_gid_entry* entries, size_t max_entries,
                          uint32_t flags);
  /**
   * @brief Forward to ibv_query_gid().
   * @param context Verbs context to query.
   * @param port_num One-based port number.
   * @param index GID table index.
   * @param gid Output GID value.
   * @return 0 on success, nonzero on failure.
   */
  int query_gid(struct ibv_context* context, uint8_t port_num, int index,
                union ibv_gid* gid);

  /**
   * @brief Forward to ibv_alloc_pd().
   * @param context Verbs context owning the PD.
   * @return Allocated protection domain, or nullptr on failure.
   */
  struct ibv_pd* alloc_pd(struct ibv_context* context);
  /**
   * @brief Forward to ibv_alloc_parent_domain().
   * @param context Verbs context owning the parent domain.
   * @param attr Parent-domain initialization attributes.
   * @return Allocated parent domain, or nullptr on failure.
   */
  struct ibv_pd* alloc_parent_domain(struct ibv_context* context,
                                     struct ibv_parent_domain_init_attr* attr);
  /**
   * @brief Forward to ibv_dealloc_pd().
   * @param pd Protection domain to deallocate.
   * @return 0 on success, nonzero on failure.
   */
  int dealloc_pd(struct ibv_pd* pd);

  /**
   * @brief Register memory using the best available verbs path.
   * @param pd Protection domain for the MR.
   * @param addr Buffer base address.
   * @param length Buffer size in bytes.
   * @param access Verbs access flags.
   * @return Registered memory region, or nullptr on failure.
   */
  struct ibv_mr* reg_mr(struct ibv_pd* pd, void* addr, size_t length,
                        int access);
  /**
   * @brief Register a range that is already exported as a dmabuf fd.
   *
   * The fd can come from any exporter (HIP's hipMemGetHandleForAddressRange
   * handles VMM-mapped memory that HSA's export rejects). The MR holds its
   * own reference, so the caller may close the fd afterwards.
   *
   * @param pd Protection domain for the MR.
   * @param addr Base address of the range (used as the IOVA).
   * @param length Range size in bytes.
   * @param fd dmabuf file descriptor for the range.
   * @param access Verbs access flags.
   * @return Registered memory region, or nullptr on failure.
   */
  struct ibv_mr* reg_dmabuf_fd(struct ibv_pd* pd, void* addr, size_t length,
                               int fd, int access);
  /**
   * @brief Register host memory with stable IOVA semantics.
   * @param pd Protection domain for the MR.
   * @param addr Buffer base address.
   * @param length Buffer size in bytes.
   * @param access Verbs access flags.
   * @return Registered memory region, or nullptr on failure.
   */
  struct ibv_mr* reg_mr_host(struct ibv_pd* pd, void* addr, size_t length,
                             int access);
  /**
   * @brief Forward to ibv_dereg_mr().
   * @param mr Memory region to deregister.
   * @return 0 on success, nonzero on failure.
   */
  int dereg_mr(struct ibv_mr* mr);

  /**
   * @brief Forward to ibv_create_cq().
   * @param context Verbs context owning the CQ.
   * @param cqe Requested completion depth.
   * @param cq_context User context pointer.
   * @param channel Optional completion channel.
   * @param comp_vector Completion vector index.
   * @return Created CQ, or nullptr on failure.
   */
  struct ibv_cq* create_cq(struct ibv_context* context, int cqe,
                           void* cq_context, struct ibv_comp_channel* channel,
                           int comp_vector);
  /**
   * @brief Forward to ibv_create_cq_ex().
   * @param context Verbs context owning the CQ.
   * @param cq_attr Extended CQ initialization attributes.
   * @return Created extended CQ, or nullptr on failure.
   */
  struct ibv_cq_ex* create_cq_ex(struct ibv_context* context,
                                 struct ibv_cq_init_attr_ex* cq_attr);
  /**
   * @brief Convert an extended CQ handle to a base CQ handle.
   * @param cq Extended CQ handle.
   * @return Base CQ handle, or nullptr when @p cq is nullptr.
   */
  struct ibv_cq* cq_ex_to_cq(struct ibv_cq_ex* cq);
  /**
   * @brief Forward to ibv_destroy_cq().
   * @param cq CQ to destroy.
   * @return 0 on success, nonzero on failure.
   */
  int destroy_cq(struct ibv_cq* cq);

  /**
   * @brief Forward to ibv_create_qp_ex().
   * @param context Verbs context owning the QP.
   * @param qp_init_attr Extended QP initialization attributes.
   * @return Created QP, or nullptr on failure.
   */
  struct ibv_qp* create_qp_ex(struct ibv_context* context,
                              struct ibv_qp_init_attr_ex* qp_init_attr);
  /**
   * @brief Forward to ibv_modify_qp().
   * @param qp QP to modify.
   * @param attr Attribute values to apply.
   * @param attr_mask Bit mask selecting attributes in @p attr.
   * @return 0 on success, nonzero on failure.
   */
  int modify_qp(struct ibv_qp* qp, struct ibv_qp_attr* attr, int attr_mask);
  /**
   * @brief Forward to ibv_destroy_qp().
   * @param qp QP to destroy.
   * @return 0 on success, nonzero on failure.
   */
  int destroy_qp(struct ibv_qp* qp);

private:
  /** @cond INTERNAL */
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
  /** @endcond */
};

extern IBVWrapper ibv;

} // namespace rdma_ep
} // namespace xio

#endif // ROCM_XIO_IBV_WRAPPER_HPP
