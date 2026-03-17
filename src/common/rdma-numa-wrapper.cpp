/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/numa_wrapper.cpp, adapted for rocm-xio.
 * Soft dependency on libnuma via dlopen.
 */

#include "rdma-numa-wrapper.hpp"

#include <cstdio>

#include <dlfcn.h>

namespace rdma_ep {

NUMAWrapper numa;

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

} // anonymous namespace

NUMAWrapper::NUMAWrapper() {
  numa_handle_ = dlopen("libnuma.so", RTLD_NOW);
  if (!numa_handle_) {
    numa_handle_ = dlopen("libnuma.so.1", RTLD_NOW);
  }
  if (!numa_handle_) {
    fprintf(stderr, "rdma_ep: Could not open libnuma.so. "
                    "NUMA topology detection disabled.\n");
    return;
  }

  if (init_function_table() != 0) {
    fprintf(stderr, "rdma_ep: Could not init libnuma function table.\n");
    dlclose(numa_handle_);
    numa_handle_ = nullptr;
    return;
  }

  is_initialized = true;
}

NUMAWrapper::~NUMAWrapper() {
  is_initialized = false;
  if (numa_handle_) {
    dlclose(numa_handle_);
  }
}

int NUMAWrapper::init_function_table() {
#define LOAD_SYM(field, prefix, name)                                          \
  if (dlsym_load(funcs_.field, numa_handle_, prefix, name) != 0)               \
    return -1;

  LOAD_SYM(bitmask_isbitset, "numa_", "bitmask_isbitset");
  LOAD_SYM(get_mems_allowed, "numa_", "get_mems_allowed");
  LOAD_SYM(set_preferred, "numa_", "set_preferred");
  LOAD_SYM(num_configured_nodes, "numa_", "num_configured_nodes");
  LOAD_SYM(num_configured_cpus, "numa_", "num_configured_cpus");
  LOAD_SYM(node_of_cpu, "numa_", "node_of_cpu");
  LOAD_SYM(max_node, "numa_", "max_node");
  LOAD_SYM(move_pages, "", "move_pages");
  LOAD_SYM(distance, "numa_", "distance");

#undef LOAD_SYM
  return 0;
}

int NUMAWrapper::bitmask_isbitset(const struct bitmask* bmp, unsigned int n) {
  return funcs_.bitmask_isbitset(bmp, n);
}

struct bitmask* NUMAWrapper::get_mems_allowed() {
  return funcs_.get_mems_allowed();
}

void NUMAWrapper::set_preferred(int node) {
  funcs_.set_preferred(node);
}

int NUMAWrapper::num_configured_nodes() {
  return funcs_.num_configured_nodes();
}

int NUMAWrapper::num_configured_cpus() {
  return funcs_.num_configured_cpus();
}

int NUMAWrapper::node_of_cpu(int cpu) {
  return funcs_.node_of_cpu(cpu);
}

int NUMAWrapper::max_node() {
  return funcs_.max_node();
}

long NUMAWrapper::move_pages(int pid, unsigned long count, void** pages,
                             const int* nodes, int* status, int flags) {
  return funcs_.move_pages(pid, count, pages, nodes, status, flags);
}

int NUMAWrapper::distance(int node1, int node2) {
  return funcs_.distance(node1, node2);
}

} // namespace rdma_ep
