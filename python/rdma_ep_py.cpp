#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>

#include <nanobind/nanobind.h>
#include <nanobind/stl/pair.h>
#include <nanobind/stl/string.h>
#include <nanobind/stl/vector.h>

#include "rdma-ep-host.h"

namespace nb = nanobind;
using namespace nb::literals;
using xio::rdma_ep::Endpoint;
using xio::rdma_ep::EndpointInfo;

namespace {

nb::dict infoToDict(const EndpointInfo& i) {
  nb::dict d;
  d["lid"] = i.lid;
  d["qpn"] = i.qpn;
  d["psn"] = i.psn;
  d["gid"] = nb::bytes(reinterpret_cast<const char*>(i.gid), sizeof(i.gid));
  d["rkey"] = i.rkey;
  d["addr"] = i.addr;
  return d;
}

EndpointInfo infoFromDict(nb::dict d) {
  EndpointInfo i;
  i.lid = nb::cast<uint32_t>(d["lid"]);
  i.qpn = nb::cast<uint32_t>(d["qpn"]);
  i.psn = nb::cast<uint32_t>(d["psn"]);
  nb::bytes gid = nb::cast<nb::bytes>(d["gid"]);
  if (gid.size() != sizeof(i.gid))
    throw std::invalid_argument("gid must be 16 bytes");
  std::memcpy(i.gid, gid.c_str(), sizeof(i.gid));
  i.rkey = nb::cast<uint32_t>(d["rkey"]);
  i.addr = nb::cast<uint64_t>(d["addr"]);
  return i;
}

} // namespace

void register_rdma_ep(nb::module_& m) {
  nb::class_<Endpoint>(m, "Endpoint",
                       "One reliable-connected RDMA QP driven from the GPU.")
    .def(
      nb::init<const std::string&, const std::string&, int, int, int, bool>(),
      "provider"_a = "mlx5", "device"_a = "", "gpu"_a = 0, "sq_depth"_a = 256,
      "cq_depth"_a = 256, "device_queues"_a = false,
      "Open the device and create the QP and CQ (device_queues=True: in GPU "
      "memory, mlx5 only).")
    .def(
      "register_buffer",
      [](Endpoint& e, uintptr_t ptr, size_t size, bool device) {
        e.registerBuffer(reinterpret_cast<void*>(ptr), size, device);
      },
      "ptr"_a, "size"_a, "device"_a = true,
      "Register the buffer the peer writes to (device=True: GPU memory via "
      "dmabuf).")
    .def(
      "local_info",
      [](const Endpoint& e) {
        return infoToDict(e.localInfo());
      },
      "Connection info to send to the peer (after register_buffer).")
    .def(
      "connect",
      [](Endpoint& e, nb::dict remote) {
        e.connect(infoFromDict(remote));
      },
      "remote"_a, "Bring the QP to RTS against the peer's local_info().")
    .def(
      "put_signal",
      [](Endpoint& e, uint64_t remoteAddr, uintptr_t local, size_t bytes,
         uint64_t signalAddr, int64_t value) {
        nb::gil_scoped_release release;
        e.putSignal(remoteAddr, reinterpret_cast<const void*>(local), bytes,
                    signalAddr, value);
      },
      "remote_addr"_a, "local"_a, "nbytes"_a, "signal_addr"_a, "value"_a = 1,
      "RDMA WRITE then an atomic add to a remote 8-byte word on the same QP; "
      "returns when both completed.")
    .def(
      "host_post_write",
      [](Endpoint& e, uint64_t remoteAddr, uintptr_t local, size_t bytes,
         bool signaled) {
        return e.hostPostWrite(remoteAddr, reinterpret_cast<const void*>(local),
                               bytes, signaled);
      },
      "remote_addr"_a, "local"_a, "nbytes"_a, "signaled"_a = true,
      "CPU-post an RDMA WRITE into the GPU-memory send queue, dormant until "
      "host_ring(). Returns the slot index.")
    .def("host_post_atomic_add", &Endpoint::hostPostAtomicAdd, "remote_addr"_a,
         "value"_a, "signaled"_a = true,
         "CPU-post an RDMA atomic fetch-add, dormant until host_ring().")
    .def("host_flush", &Endpoint::hostFlush,
         "Drain the CPU's writes into the GPU-memory queues to the device (HDP "
         "flush); call after posting and before arming a DMA engine to ring.")
    .def("host_ring", &Endpoint::hostRing,
         "Make everything posted visible to the NIC: doorbell record, HDP "
         "flush, doorbell.")
    .def(
      "host_staged",
      [](const Endpoint& e) {
        uint32_t rec = 0;
        uint64_t val = 0;
        e.hostStaged(&rec, &val);
        return std::make_pair(rec, val);
      },
      "(doorbell record big-endian, control header) that would ring "
      "everything posted so far.")
    .def(
      "host_addresses",
      [](const Endpoint& e) {
        uint64_t a = 0, g = 0, c = 0;
        e.hostAddresses(&a, &g, &c);
        nb::dict d;
        d["dbrec"] = a;
        d["gpu_doorbell"] = g;
        d["cpu_doorbell"] = c;
        return d;
      },
      "Addresses a DMA engine needs to ring the doorbell.")
    .def(
      "host_poll",
      [](Endpoint& e, unsigned maxCompletions) {
        nb::gil_scoped_release release;
        return e.hostPoll(maxCompletions);
      },
      "max"_a = 1, "Consume up to max completions (error completion raises).")
    .def("host_outstanding", &Endpoint::hostOutstanding,
         "Work requests posted but not yet completed.")
    .def(
      "device_context",
      [](Endpoint& e) {
        return e.deviceContext();
      },
      "Words a kernel needs to post WQEs on this QP itself (mlx5): see "
      "DEVICE_CTX_WORDS. Call after register_buffer() and connect().")
    .def(
      "put",
      [](Endpoint& e, uint64_t remoteAddr, uintptr_t local, size_t bytes) {
        nb::gil_scoped_release release;
        e.put(remoteAddr, reinterpret_cast<const void*>(local), bytes);
      },
      "remote_addr"_a, "local"_a, "nbytes"_a,
      "GPU-initiated RDMA WRITE; returns when it has completed.");
}

NB_MODULE(rdma_ep_py, m) {
  m.doc() = "GPU-initiated RDMA endpoint (rdma-ep) for Python";
  m.attr("DEVICE_CTX_WORDS") = Endpoint::kDeviceCtxWords;
  register_rdma_ep(m);
}
