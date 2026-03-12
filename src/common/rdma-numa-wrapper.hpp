/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/numa_wrapper.hpp, adapted for rocm-xio.
 * NUMA API wrapper loaded via dlopen -- no link dependency on libnuma.
 */

#ifndef ROCM_XIO_RDMA_NUMA_WRAPPER_HPP
#define ROCM_XIO_RDMA_NUMA_WRAPPER_HPP

#include <cstddef>

struct bitmask;

namespace rdma_ep {

class NUMAWrapper {
public:
  explicit NUMAWrapper();
  virtual ~NUMAWrapper();

  bool is_initialized{false};

  int bitmask_isbitset(const struct bitmask *bmp, unsigned int n);
  struct bitmask *get_mems_allowed();
  void set_preferred(int node);
  int num_configured_nodes();
  int num_configured_cpus();
  int node_of_cpu(int cpu);
  int max_node();
  long move_pages(int pid, unsigned long count, void **pages,
                  const int *nodes, int *status, int flags);
  int distance(int node1, int node2);

private:
  struct numa_funcs_t {
    int (*bitmask_isbitset)(const struct bitmask *bmp, unsigned int n);
    struct bitmask *(*get_mems_allowed)();
    void (*set_preferred)(int node);
    int (*num_configured_nodes)();
    int (*num_configured_cpus)();
    int (*node_of_cpu)(int cpu);
    int (*max_node)();
    long (*move_pages)(int pid, unsigned long count, void **pages,
                       const int *nodes, int *status, int flags);
    int (*distance)(int node1, int node2);
  };

  struct numa_funcs_t funcs_{};
  void *numa_handle_{nullptr};

  int init_function_table();
};

extern NUMAWrapper numa;

} // namespace rdma_ep

#endif // ROCM_XIO_RDMA_NUMA_WRAPPER_HPP
