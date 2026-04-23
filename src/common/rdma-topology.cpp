/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Derived from ROCm/rocSHMEM src/gda/topology.cpp, adapted for rocm-xio.
 * Simplified for the single-endpoint model. Full PCIe tree analysis from
 * rocshmem is partially ported; the rest can be enhanced as needed.
 */

#include "rdma-topology.hpp"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <set>
#include <sstream>
#include <vector>

#include <hip/hip_runtime.h>

#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>

#include "ibv-wrapper.hpp"
#include "rdma-numa-wrapper.hpp"

namespace xio { namespace rdma_ep {

[[maybe_unused]] static const char* GidPriorityStr[] = {
  "RoCEv1 Link-local", "RoCEv2 Link-local",  "RoCEv1 IPv6",
  "RoCEv2 IPv6",       "RoCEv1 IPv4-mapped", "RoCEv2 IPv4-mapped"};

struct IbvDeviceInfo {
  ibv_device* devicePtr;
  std::string name;
  std::string busId;
  bool hasActivePort;
  int numaNode;
  int gidIndex;
  std::string gidDescriptor;
  bool isRoce;
};

static bool IsConfiguredGid(union ibv_gid const& gid) {
  const struct in6_addr* a = (struct in6_addr*)gid.raw;
  int trailer = (a->s6_addr32[1] | a->s6_addr32[2] | a->s6_addr32[3]);
  if (((a->s6_addr32[0] | trailer) == 0UL) ||
      ((a->s6_addr32[0] == htonl(0xfe800000)) && (trailer == 0UL))) {
    return false;
  }
  return true;
}

static bool LinkLocalGid(union ibv_gid const& gid) {
  const struct in6_addr* a = (struct in6_addr*)gid.raw;
  return (a->s6_addr32[0] == htonl(0xfe800000) && a->s6_addr32[1] == 0UL);
}

static bool IsIPv4MappedIPv6(const union ibv_gid& gid) {
  return (gid.global.subnet_prefix == 0 && gid.raw[8] == 0 && gid.raw[9] == 0 &&
          gid.raw[10] == 0xff && gid.raw[11] == 0xff);
}

static int GetRoceVersionNumber(struct ibv_context* context, int portNum,
                                int gidIndex, int& version) {
  const char* deviceName = ibv.get_device_name(context->device);
  char gidRoceVerStr[16] = {};
  char roceTypePath[PATH_MAX] = {};
  snprintf(roceTypePath, sizeof(roceTypePath),
           "/sys/class/infiniband/%s/ports/%d/gid_attrs/types/%d", deviceName,
           portNum, gidIndex);

  int fd = open(roceTypePath, O_RDONLY);
  if (fd == -1)
    return -1;

  int ret = read(fd, gidRoceVerStr, 15);
  close(fd);
  if (ret == -1)
    return -1;

  if (strlen(gidRoceVerStr)) {
    if (strncmp(gidRoceVerStr, "IB/RoCE v1", strlen("IB/RoCE v1")) == 0 ||
        strncmp(gidRoceVerStr, "RoCE v1", strlen("RoCE v1")) == 0) {
      version = 1;
    } else if (strncmp(gidRoceVerStr, "RoCE v2", strlen("RoCE v2")) == 0) {
      version = 2;
    }
  }
  return 0;
}

static int AutoSelectGidIndex(struct ibv_context* context, int gidTblLen,
                              int portNum) {
  union ibv_gid gid;
  GidPriority highestPriority = GID_UNKNOWN;
  int bestGidIndex = -1;

  for (int i = 0; i < gidTblLen; ++i) {
    if (ibv.query_gid(context, portNum, i, &gid) != 0)
      continue;
    if (!IsConfiguredGid(gid))
      continue;

    int roceVersion = 0;
    if (GetRoceVersionNumber(context, portNum, i, roceVersion) != 0)
      continue;

    GidPriority currPriority;
    if (IsIPv4MappedIPv6(gid)) {
      currPriority = (roceVersion == 2) ? ROCEV2_IPV4 : ROCEV1_IPV4;
    } else if (!LinkLocalGid(gid)) {
      currPriority = (roceVersion == 2) ? ROCEV2_IPV6 : ROCEV1_IPV6;
    } else {
      currPriority = (roceVersion == 2) ? ROCEV2_LINK_LOCAL : ROCEV1_LINK_LOCAL;
    }

    if (currPriority > highestPriority) {
      highestPriority = currPriority;
      bestGidIndex = i;
    }
  }

  return bestGidIndex;
}

static std::vector<IbvDeviceInfo>& GetIbvDeviceList() {
  static bool isInitialized = false;
  static std::vector<IbvDeviceInfo> ibvDeviceList;

  if (!isInitialized) {
    int numIbvDevices = 0;
    ibv_device** deviceList = ibv.get_device_list(&numIbvDevices);
    if (!deviceList || numIbvDevices == 0) {
      fprintf(stderr, "rdma_ep: No InfiniBand devices found.\n");
      if (deviceList)
        ibv.free_device_list(deviceList);
      isInitialized = true;
      return ibvDeviceList;
    }

    for (int i = 0; i < numIbvDevices; i++) {
      IbvDeviceInfo info;
      info.devicePtr = deviceList[i];
      info.name = deviceList[i]->name;
      info.hasActivePort = false;
      info.numaNode = -1;
      info.gidIndex = -1;
      info.isRoce = false;

      struct ibv_context* context = ibv.open_device(info.devicePtr);
      if (context) {
        struct ibv_device_attr deviceAttr;
        if (!ibv.query_device(context, &deviceAttr)) {
          for (int port = 1; port <= deviceAttr.phys_port_cnt; ++port) {
            struct ibv_port_attr portAttr;
            if (ibv.query_port(context, port, &portAttr))
              continue;
            if (portAttr.state == IBV_PORT_ACTIVE) {
              info.hasActivePort = true;
              if (portAttr.link_layer == IBV_LINK_LAYER_ETHERNET) {
                info.isRoce = true;
                info.gidIndex = AutoSelectGidIndex(context,
                                                   portAttr.gid_tbl_len, port);
                if (info.gidIndex >= 0 &&
                    static_cast<int>(static_cast<GidPriority>(ROCEV2_IPV4)) >=
                      0) {
                  info.gidDescriptor = "auto-selected";
                }
              }
              break;
            }
          }
        }
        ibv.close_device(context);
      }

      info.busId = "";
      std::string device_path(info.devicePtr->dev_path);
      if (std::filesystem::exists(device_path)) {
        std::error_code ec;
        auto pciPath =
          std::filesystem::canonical(device_path + "/device", ec).string();
        if (!ec) {
          auto pos = pciPath.find_last_of('/');
          if (pos != std::string::npos) {
            info.busId = pciPath.substr(pos + 1);
          }
        }
      }

      std::string numaPath = "/sys/bus/pci/devices/" + info.busId +
                             "/numa_node";
      if (!info.busId.empty() && std::filesystem::exists(numaPath)) {
        std::ifstream file(numaPath);
        if (file.is_open()) {
          std::string numaStr;
          std::getline(file, numaStr);
          int val;
          if (sscanf(numaStr.c_str(), "%d", &val) == 1)
            info.numaNode = val;
        }
      }

      ibvDeviceList.push_back(info);
    }

    ibv.free_device_list(deviceList);
    isInitialized = true;
  }
  return ibvDeviceList;
}

int ExtractBusNumber(std::string const& pcieAddress) {
  int domain, bus, device, function;
  char delimiter;
  std::istringstream iss(pcieAddress);
  iss >> std::hex >> domain >> delimiter >> bus >> delimiter >> device >>
    delimiter >> function;
  if (iss.fail())
    return -1;
  return bus;
}

int GetBusIdDistance(std::string const& pcieAddress1,
                     std::string const& pcieAddress2) {
  int bus1 = ExtractBusNumber(pcieAddress1);
  int bus2 = ExtractBusNumber(pcieAddress2);
  return (bus1 < 0 || bus2 < 0) ? -1 : std::abs(bus1 - bus2);
}

int GetNumDevices(DeviceType type) {
  switch (type) {
    case DEV_CPU:
      if (numa.is_initialized)
        return numa.num_configured_nodes();
      return 1;
    case DEV_GPU: {
      int count = 0;
      hipError_t status = hipGetDeviceCount(&count);
      if (status != hipSuccess)
        count = 0;
      return count;
    }
    case DEV_NIC:
      return static_cast<int>(GetIbvDeviceList().size());
    default:
      return 0;
  }
}

static bool hasExactMatch(const std::string& namesList,
                          const std::string& name) {
  std::stringstream ss(namesList);
  std::string token;
  while (std::getline(ss, token, ',')) {
    if (token == name)
      return true;
  }
  return false;
}

int GetClosestNicToGpu(int gpuIndex, const char* hca_list,
                       const char** dev_name) {
  auto const& ibvDeviceList = GetIbvDeviceList();
  int numGpus = GetNumDevices(DEV_GPU);
  if (gpuIndex < 0 || gpuIndex >= numGpus)
    return -1;

  char hipPciBusId[64];
  if (hipDeviceGetPCIBusId(hipPciBusId, sizeof(hipPciBusId), gpuIndex) !=
      hipSuccess) {
    return -1;
  }

  std::string excludeList((hca_list && hca_list[0] == '^') ? &hca_list[1] : "");
  std::string includeList((hca_list && hca_list[0] != '^') ? hca_list : "");

  int closestIdx = -1;
  int minDistance = std::numeric_limits<int>::max();

  for (size_t i = 0; i < ibvDeviceList.size(); i++) {
    auto const& dev = ibvDeviceList[i];
    if (!dev.hasActivePort || dev.busId.empty())
      continue;

    auto is_excluded = hasExactMatch(excludeList, dev.name) ||
                       (includeList.length() &&
                        !hasExactMatch(includeList, dev.name));
    if (is_excluded)
      continue;

    int distance = GetBusIdDistance(hipPciBusId, dev.busId);
    if (distance >= 0 && distance < minDistance) {
      minDistance = distance;
      closestIdx = static_cast<int>(i);
    }
  }

  if (dev_name && closestIdx >= 0) {
    *dev_name = strdup(ibvDeviceList[closestIdx].name.c_str());
  }

  return closestIdx;
}

int GetClosestCpuNumaToGpu(int gpuIndex) {
  (void)gpuIndex;
  return -1;
}

int GetClosestCpuNumaToNic(int nicIndex) {
  auto const& list = GetIbvDeviceList();
  if (nicIndex < 0 || nicIndex >= static_cast<int>(list.size()))
    return -1;
  return list[nicIndex].numaNode;
}

int SelectBestGid(struct ibv_context* ctx, uint8_t port_num) {
  struct ibv_port_attr portAttr;
  if (ibv.query_port(ctx, port_num, &portAttr) != 0)
    return -1;
  return AutoSelectGidIndex(ctx, portAttr.gid_tbl_len, port_num);
}

PCIeNode const* GetLcaBetweenNodes(PCIeNode const* root,
                                   std::string const& node1Address,
                                   std::string const& node2Address) {
  (void)root;
  (void)node1Address;
  (void)node2Address;
  return nullptr;
}

int GetLcaDepth(std::string const& targetBusID, PCIeNode const* const& node,
                int depth) {
  if (!node)
    return -1;
  if (targetBusID == node->address)
    return depth;
  for (auto const& child : node->children) {
    int d = GetLcaDepth(targetBusID, &child, depth + 1);
    if (d != -1)
      return d;
  }
  return -1;
}

int InsertPCIePathToTree(std::string const& pcieAddress,
                         std::string const& description, PCIeNode& root) {
  (void)pcieAddress;
  (void)description;
  (void)root;
  return 0;
}

std::set<int> GetNearestDevicesInTree(
  std::string const& targetBusId,
  std::vector<std::string> const& candidateBusIdList) {
  (void)targetBusId;
  (void)candidateBusIdList;
  return {};
}

std::set<int> GetNearestDevicesInTree(
  std::string const& targetBusId,
  std::vector<std::string> const& candidateBusIdList, PCIeNode const* root) {
  (void)targetBusId;
  (void)candidateBusIdList;
  (void)root;
  return {};
}

} // namespace rdma_ep
} // namespace xio
