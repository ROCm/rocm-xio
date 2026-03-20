/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/topology.hpp, adapted for rocm-xio.
 * Simplified for the single-endpoint model (no full-mesh PE topology).
 * Provides NIC-GPU proximity detection and GID selection.
 */

#ifndef ROCM_XIO_RDMA_TOPOLOGY_HPP
#define ROCM_XIO_RDMA_TOPOLOGY_HPP

#include <cstdint>
#include <set>
#include <string>
#include <vector>

#include "ibv-core.hpp"

namespace rdma_ep {

enum GidPriority {
  GID_UNKNOWN = -1,
  ROCEV1_LINK_LOCAL = 0,
  ROCEV2_LINK_LOCAL = 1,
  ROCEV1_IPV6 = 2,
  ROCEV2_IPV6 = 3,
  ROCEV1_IPV4 = 4,
  ROCEV2_IPV4 = 5,
};

enum DeviceType {
  DEV_CPU = 0,
  DEV_GPU = 1,
  DEV_NIC = 2,
};

struct PCIeNode {
  std::string address;
  mutable std::string description;
  std::set<PCIeNode> children;

  PCIeNode() = default;
  PCIeNode(std::string const& addr) : address(addr) {
  }
  PCIeNode(std::string const& addr, std::string const& desc)
    : address(addr), description(desc) {
  }

  bool operator<(PCIeNode const& other) const {
    return address < other.address;
  }
};

int ExtractBusNumber(std::string const& pcieAddress);
int GetBusIdDistance(std::string const& pcieAddress1,
                     std::string const& pcieAddress2);

PCIeNode const* GetLcaBetweenNodes(PCIeNode const* root,
                                   std::string const& node1Address,
                                   std::string const& node2Address);

int GetLcaDepth(std::string const& targetBusID, PCIeNode const* const& node,
                int depth = 0);

int InsertPCIePathToTree(std::string const& pcieAddress,
                         std::string const& description, PCIeNode& root);

std::set<int> GetNearestDevicesInTree(
  std::string const& targetBusId,
  std::vector<std::string> const& candidateBusIdList);

std::set<int> GetNearestDevicesInTree(
  std::string const& targetBusId,
  std::vector<std::string> const& candidateBusIdList, PCIeNode const* root);

int GetClosestCpuNumaToGpu(int gpuIndex);
int GetClosestCpuNumaToNic(int nicIndex);

/**
 * Find the NIC closest to the given GPU via PCIe topology.
 *
 * @param gpuIndex  HIP device index of the GPU
 * @param hca_list  Comma-separated include/exclude list (^prefix to exclude),
 *                  or nullptr for auto-detect
 * @param dev_name  Output: device name of the selected NIC
 * @return Index of the selected NIC in the IBV device list, or -1 on failure
 */
int GetClosestNicToGpu(int gpuIndex, const char* hca_list,
                       const char** dev_name);

int GetNumDevices(DeviceType type);

/**
 * Select the best GID index for the given IB context and port.
 * Prefers RoCEv2 IPv4-mapped, falls back through priority list.
 *
 * @param ctx       IB verbs context
 * @param port_num  Port number (1-based)
 * @return GID index, or -1 on failure
 */
int SelectBestGid(struct ibv_context* ctx, uint8_t port_num);

} // namespace rdma_ep

#endif // ROCM_XIO_RDMA_TOPOLOGY_HPP
