#include <cstdio>

#include "doca-compatible/doca_gpunetio_dev_verbs_qp.hip.h"
#include "hip/hip_runtime.h"

#define HIP_CHECK(cmd)                                                         \
  do {                                                                         \
    hipError_t _err = (cmd);                                                   \
    if (_err != hipSuccess) {                                                  \
      std::fprintf(stderr, "HIP error %s at %s:%d\n", hipGetErrorString(_err), \
                   __FILE__, __LINE__);                                        \
      return 1;                                                                \
    }                                                                          \
  } while (0)

struct WqeTestResult {
  int wqe_seg_ok;
  int wqe_addr_ok;
  int wqe_write_ok;
  uint32_t got_ctrl_opmod_idx_opcode;
  uint32_t got_ctrl_qpn_ds;
  uint8_t got_ctrl_fm_ce_se;
  uint32_t got_ctrl_imm;
  uint64_t got_raddr;
  uint32_t got_rkey;
  uint64_t got_laddr;
  uint32_t got_lkey;
  uint32_t got_byte_count;
};

__global__ void wqe_test_kernel(struct radaki_dev_wqe* wqe_ring,
                                uint64_t* wqe_seg_target, WqeTestResult* out) {
  if (blockIdx.x != 0 || threadIdx.x != 0)
    return;

  uint64_t wqe_seg_data[2] = {0x1122334455667788ULL, 0x8877665544332211ULL};
  radaki_dev_store_wqe_seg(wqe_seg_target, wqe_seg_data);
  out->wqe_seg_ok = (wqe_seg_target[0] == wqe_seg_data[0]) &&
                    (wqe_seg_target[1] == wqe_seg_data[1]);

  struct radaki_dev_qp qp = {};
  qp.sq_wqe_mask = 3; /* Ring size of 4 */
  qp.sq_wqe_daddr = (uintptr_t)wqe_ring;
  qp.sq_num_shift8_be_3ds = __builtin_bswap32(0x000abc03U);

  const uint16_t wqe_idx = 6; /* Maps to slot 2 */
  struct radaki_dev_wqe* wqe_ptr = radaki_dev_get_wqe_ptr(&qp, wqe_idx);
  out->wqe_addr_ok = (wqe_ptr == &wqe_ring[2]);

  radaki_dev_wqe_prepare_write(&qp, wqe_ptr, wqe_idx,
                               DOCA_GPUNETIO_IB_MLX5_OPCODE_RDMA_WRITE,
                               DOCA_GPUNETIO_IB_MLX5_WQE_CTRL_CQ_UPDATE,
                               0x55aa55aaU, 0x1111222233334444ULL, 0xaabbccddU,
                               0x0123456789abcdefULL, 0x10203040U, 64U);

  struct radaki_dev_wqe_ctrl_seg* ctrl =
    reinterpret_cast<struct radaki_dev_wqe_ctrl_seg*>(wqe_ptr->dseg0);
  struct doca_gpunetio_ib_mlx5_wqe_raddr_seg* rseg =
    reinterpret_cast<struct doca_gpunetio_ib_mlx5_wqe_raddr_seg*>(
      wqe_ptr->dseg1);
  struct doca_gpunetio_ib_mlx5_wqe_data_seg* dseg0 =
    reinterpret_cast<struct doca_gpunetio_ib_mlx5_wqe_data_seg*>(
      wqe_ptr->dseg2);

  uint32_t exp_ctrl = __builtin_bswap32(
    (static_cast<uint32_t>(wqe_idx) << DOCA_GPUNETIO_VERBS_WQE_IDX_SHIFT) |
    DOCA_GPUNETIO_IB_MLX5_OPCODE_RDMA_WRITE);
  uint64_t exp_raddr = __builtin_bswap64(0x1111222233334444ULL);
  uint64_t exp_laddr = __builtin_bswap64(0x0123456789abcdefULL);
  uint32_t exp_bytes = __builtin_bswap32(
    64U & uint32_t(DOCA_GPUNETIO_IB_MLX5_INLINE_SEG - 1));
#if DOCA_GPUNETIO_VERBS_MKEY_SWAPPED == 1
  uint32_t exp_rkey = 0xaabbccddU;
  uint32_t exp_lkey = 0x10203040U;
#else
  uint32_t exp_rkey = __builtin_bswap32(0xaabbccddU);
  uint32_t exp_lkey = __builtin_bswap32(0x10203040U);
#endif

  out->got_ctrl_opmod_idx_opcode = ctrl->opmod_idx_opcode;
  out->got_ctrl_qpn_ds = ctrl->qpn_ds;
  out->got_ctrl_fm_ce_se = ctrl->fm_ce_se;
  out->got_ctrl_imm = ctrl->imm;
  out->got_raddr = rseg->raddr;
  out->got_rkey = rseg->rkey;
  out->got_laddr = dseg0->addr;
  out->got_lkey = dseg0->lkey;
  out->got_byte_count = dseg0->byte_count;
  out->wqe_write_ok = (ctrl->opmod_idx_opcode == exp_ctrl) &&
                      (ctrl->qpn_ds == qp.sq_num_shift8_be_3ds) &&
                      (ctrl->fm_ce_se ==
                       DOCA_GPUNETIO_IB_MLX5_WQE_CTRL_CQ_UPDATE) &&
                      (ctrl->imm == 0x55aa55aaU) && (rseg->rkey == exp_rkey) &&
                      (rseg->raddr == exp_raddr) &&
                      (dseg0->addr == exp_laddr) && (dseg0->lkey == exp_lkey) &&
                      (dseg0->byte_count == exp_bytes);
}

int main() {
  int rc = 0;
  int device_count = 0;
  HIP_CHECK(hipGetDeviceCount(&device_count));
  if (device_count == 0) {
    std::fprintf(stderr, "No HIP device found.\n");
    return 1;
  }

  struct radaki_dev_wqe* wqe_ring = nullptr;
  uint64_t* wqe_seg_target = nullptr;
  WqeTestResult* dev_result = nullptr;
  WqeTestResult host_result = {};

  HIP_CHECK(hipMalloc(&wqe_ring, 4 * sizeof(*wqe_ring)));
  HIP_CHECK(hipMemset(wqe_ring, 0, 4 * sizeof(*wqe_ring)));
  HIP_CHECK(hipMalloc(&wqe_seg_target, 2 * sizeof(*wqe_seg_target)));
  HIP_CHECK(hipMemset(wqe_seg_target, 0, 2 * sizeof(*wqe_seg_target)));
  HIP_CHECK(
    hipMalloc(reinterpret_cast<void**>(&dev_result), sizeof(*dev_result)));
  HIP_CHECK(hipMemset(dev_result, 0, sizeof(*dev_result)));

  hipLaunchKernelGGL(wqe_test_kernel, dim3(1), dim3(1), 0, 0, wqe_ring,
                     wqe_seg_target, dev_result);
  HIP_CHECK(hipGetLastError());
  HIP_CHECK(hipDeviceSynchronize());
  HIP_CHECK(hipMemcpy(&host_result, dev_result, sizeof(host_result),
                      hipMemcpyDeviceToHost));

  const bool passed = (host_result.wqe_seg_ok == 1) &&
                      (host_result.wqe_addr_ok == 1) &&
                      (host_result.wqe_write_ok == 1);

  if (!passed) {
    std::fprintf(stderr,
                 "FAILED wqe_seg=%d wqe_addr=%d wqe_write=%d "
                 "ctrl(opmod=0x%x qpn_ds=0x%x fm=0x%x imm=0x%x) "
                 "raddr=0x%llx rkey=0x%x laddr=0x%llx lkey=0x%x bytes=0x%x\n",
                 host_result.wqe_seg_ok, host_result.wqe_addr_ok,
                 host_result.wqe_write_ok,
                 host_result.got_ctrl_opmod_idx_opcode,
                 host_result.got_ctrl_qpn_ds, host_result.got_ctrl_fm_ce_se,
                 host_result.got_ctrl_imm,
                 static_cast<unsigned long long>(host_result.got_raddr),
                 host_result.got_rkey,
                 static_cast<unsigned long long>(host_result.got_laddr),
                 host_result.got_lkey, host_result.got_byte_count);
    rc = 2;
  } else {
    std::printf("PASS: WQE low-level test\n");
  }

  if (dev_result != nullptr)
    HIP_CHECK(hipFree(dev_result));
  if (wqe_seg_target != nullptr)
    HIP_CHECK(hipFree(wqe_seg_target));
  if (wqe_ring != nullptr)
    HIP_CHECK(hipFree(wqe_ring));

  return rc;
}
