/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#include "xio-cli-options.h"

#include <string>

static std::string transferSizeTransform(std::string& s) {
  if (s.empty())
    return "Transfer size cannot be empty";
  size_t start = s.find_first_not_of(" \t");
  if (start == std::string::npos)
    return "Invalid transfer size";
  size_t end = s.find_last_not_of(" \t");
  std::string val = s.substr(start, end - start + 1);
  if (val.empty())
    return "Invalid transfer size";
  unsigned long long mult = 1;
  char last = val.back();
  if (last == 'k' || last == 'K') {
    mult = 1024ULL;
    val.pop_back();
  } else if (last == 'm' || last == 'M') {
    mult = 1024ULL * 1024;
    val.pop_back();
  } else if (last == 'g' || last == 'G') {
    mult = 1024ULL * 1024 * 1024;
    val.pop_back();
  }
  if (val.empty())
    return "Invalid transfer size (missing number)";
  unsigned long long num = 0;
  try {
    num = std::stoull(val, nullptr, 0);
  } catch (...) {
    return "Transfer size must be a number (e.g. 4096 or 1M)";
  }
  if (num == 0)
    return "Transfer size must be > 0";
  unsigned long long result = num * mult;
  if (mult != 0 && result / mult != num)
    return "Transfer size overflow";
  s = std::to_string(result);
  return "";
}

void registerTestEpCliOptions(CLI::App& app, xio::test_ep::TestEpConfig* cfg) {
  app
    .add_option("-n,--iterations", cfg->iterations, "Number of I/O operations")
    ->default_val(128)
    ->group("Endpoint Options");
  app
    .add_option("--doorbell", cfg->doorbell,
                "Enable doorbell mode with specified queue length (0=disabled)")
    ->default_val(0)
    ->group("Endpoint Options");
  app
    .add_flag("--emulate", cfg->emulate,
              "Run kernel code on CPU instead of GPU"
              " (for testing)")
    ->group("Endpoint Options");
  app
    .add_flag("--verify", cfg->verify,
              "Verify LFSR data pattern each"
              " iteration")
    ->group("Endpoint Options");
  app.add_option("--seed", cfg->seed, "LFSR seed for data pattern")
    ->default_val(1)
    ->group("Endpoint Options");
}

void registerNvmeEpCliOptions(CLI::App& app, xio::nvme_ep::nvmeEpConfig* cfg) {
  const std::string nvme_group = "NVMe Endpoint Options";

  app
    .add_option("--access-pattern", cfg->ioParams.accessPattern,
                "IO access pattern: 'sequential' or 'random'.")
    ->default_val("random")
    ->check(CLI::IsMember({"sequential", "random"}))
    ->group(nvme_group);
  app
    .add_option("--data-buffer-size", cfg->bufferParams.bufferSize,
                "Size of data buffers for NVMe IO (bytes).")
    ->default_val(1024 * 1024)
    ->check(CLI::PositiveNumber)
    ->group(nvme_group);
  app
    .add_option("--controller", cfg->controller,
                "NVMe controller device path (required).")
    ->required()
    ->group(nvme_group);
  app
    .add_option("--base-lba", cfg->ioParams.baseLba,
                "Starting LBA for I/O operations (default: 0)")
    ->default_val(0)
    ->group(nvme_group);
  app
    .add_option("--lfsr-seed", cfg->ioParams.lfsrSeed,
                "Seed for LFSR pattern generation (0 = derive from LBA).")
    ->default_val(0)
    ->group(nvme_group);
  app
    .add_option("--read-io", cfg->ioParams.readIo,
                "Number of read I/O to perform. Negative values "
                "accepted for backward compatibility (converted "
                "to positive).")
    ->default_val(0)
    ->group(nvme_group);
  app
    .add_option("--queue-id", cfg->queueId,
                "NVMe queue ID to use (0=admin queue, 1+=IO queues). "
                "If not specified, auto-detects and uses the last available "
                "I/O queue.")
    ->default_val(0)
    ->check(CLI::Range(0, 65535))
    ->group(nvme_group);
  app
    .add_option("--queue-length", cfg->queueLength,
                "NVMe queue length in entries (must be power of 2, max 32768).")
    ->default_val(1024)
    ->check([](const std::string& str) {
      uint16_t val;
      try {
        val = static_cast<uint16_t>(std::stoul(str));
      } catch (...) {
        return std::string("Invalid number");
      }
      if (val == 0 || val > 65535) {
        return std::string("Queue length must be between 1 and 65535");
      }
      if ((val & (val - 1)) != 0) {
        return std::string("Queue length must be a power of 2");
      }
      return std::string();
    })
    ->group(nvme_group);
  app
    .add_option("--num-queues", cfg->numQueues,
                "Number of independent NVMe I/O queues. "
                "Each queue is driven by its own GPU "
                "kernel on a separate HIP stream. "
                "Default: 1.")
    ->default_val(1)
    ->check(CLI::PositiveNumber)
    ->group(nvme_group);
  app
    .add_option("--namespace", cfg->ioParams.nsid,
                "NVMe namespace ID (must be > 0, default: 1).")
    ->default_val(1)
    ->check(CLI::PositiveNumber)
    ->group(nvme_group);

  app
    .add_option("--lbas-per-io", cfg->ioParams.lbasPerIo,
                "Number of LBAs per I/O operation (default: 1).")
    ->default_val(1)
    ->check(CLI::PositiveNumber)
    ->group(nvme_group);
  app
    .add_option("--write-io", cfg->ioParams.writeIo,
                "Number of write I/O to perform. Negative values "
                "accepted for backward compatibility (converted "
                "to positive).")
    ->default_val(0)
    ->group(nvme_group);
  app
    .add_flag("--infinite", cfg->ioParams.infiniteMode,
              "Infinite mode: run forever. Requires exactly one "
              "of --read-io or --write-io to be non-zero.")
    ->group(nvme_group);
  app
    .add_option("--batch-size", cfg->ioParams.batchSize,
                "Number of SQEs to submit per doorbell ring. "
                "1 = sequential (one I/O at a time), "
                "0 = all at once, N = N SQEs per doorbell. "
                "When N > 1, each SQE is prepared by a "
                "separate GPU thread; may span multiple "
                "wavefronts. Max is queue_length - 1.")
    ->default_val(1)
    ->check(CLI::NonNegativeNumber)
    ->group(nvme_group);
  app
    .add_flag("--verify", cfg->verify,
              "Verify LFSR data pattern after "
              "read-back (requires --write-io and "
              "--read-io)")
    ->group(nvme_group);
}

void registerRdmaEpCliOptions(CLI::App& app, rdma_ep::RdmaEpConfig* cfg) {
  const std::string group = "RDMA Endpoint Options";

  app
    .add_option("-n,--iterations", cfg->iterations,
                "Number of RDMA operations (0 = infinite)")
    ->default_val(128)
    ->group(group);

  app
    .add_option("--provider", cfg->providerStr,
                "RDMA provider: bnxt, mlx5, ionic,"
                " or ernic")
    ->default_val("bnxt")
    ->check(CLI::IsMember({"bnxt", "bnxt_re", "mlx5", "ionic", "pensando",
                           "ernic", "rocm_ernic", "rocm-ernic"},
                          CLI::ignore_case))
    ->group(group);

  app
    .add_option("--device", cfg->deviceName,
                "RDMA device name"
                " (e.g. rocm-rdma-bnxt0)")
    ->default_val("")
    ->group(group);

  app.add_option("--sq-depth", cfg->sqDepth, "Send queue depth (power of 2)")
    ->default_val(256)
    ->group(group);

  app.add_option("--cq-depth", cfg->cqDepth, "Completion queue depth")
    ->default_val(256)
    ->group(group);

  app
    .add_option("--transfer-size", cfg->transferSize,
                "Transfer size per operation"
                " in bytes")
    ->default_val(4096)
    ->check(CLI::PositiveNumber)
    ->group(group);

  app
    .add_option("--inline-threshold", cfg->inlineThreshold,
                "Max bytes for inline sends")
    ->default_val(28)
    ->group(group);

  app
    .add_flag("--loopback,!--no-loopback", cfg->loopback,
              "Connect QP to itself (default: on)")
    ->group(group);

  const std::string twonode_group = "2-Node Mode";

  auto* server_flag = app
                        .add_flag("--server", cfg->isServer,
                                  "Run as 2-node server (TCP listener)")
                        ->group(twonode_group);

  auto* client_flag = app
                        .add_flag("--client", cfg->isClient,
                                  "Run as 2-node client (connects to server)")
                        ->group(twonode_group);

  server_flag->excludes(client_flag);
  client_flag->excludes(server_flag);

  app
    .add_option("--server-host", cfg->serverHost,
                "Server hostname/IP (required with --client)")
    ->needs(client_flag)
    ->group(twonode_group);

  app
    .add_option("--pingpong-size", cfg->ppSize,
                "Ping-pong buffer in bytes"
                " (min 16: 8-byte seq + payload)")
    ->default_val(64)
    ->check(CLI::Range(static_cast<uint32_t>(16),
                       static_cast<uint32_t>(16 * 1024 * 1024)))
    ->group(twonode_group);

  app
    .add_option("--pingpong-iters", cfg->ppIters,
                "Number of ping-pong round trips")
    ->default_val(100)
    ->check(CLI::PositiveNumber)
    ->group(twonode_group);

  app
    .add_option("--batch-size", cfg->batchSize,
                "Number of WQEs per doorbell ring. "
                "1 = sequential (one WQE at a time), "
                "N = N WQEs per doorbell. When N > 1, "
                "each WQE is prepared by a separate "
                "GPU thread. Max is sq-depth - 1. "
                "Loopback only.")
    ->default_val(1)
    ->check(CLI::NonNegativeNumber)
    ->group(group);

  app
    .add_option("--num-queues", cfg->numQueues,
                "Number of independent RDMA QPs. "
                "Each QP is driven by its own GPU "
                "kernel on a separate HIP stream. "
                "Loopback only. Default: 1.")
    ->default_val(1)
    ->check(CLI::PositiveNumber)
    ->group(group);

  app
    .add_flag("--infinite", cfg->infiniteMode,
              "Run forever until SIGINT "
              "(equivalent to --iterations 0)")
    ->group(group);

  app.add_option("--gpu-device", cfg->gpuDeviceId, "HIP GPU device ID")
    ->default_val(0)
    ->group(group);

  app
    .add_flag("--pcie-relaxed-ordering", cfg->pcieRelaxedOrdering,
              "Enable PCIe relaxed ordering")
    ->group(group);

  app
    .add_option("--traffic-class", cfg->trafficClass, "Traffic class for QP AH")
    ->default_val(0)
    ->group(group);

  app
    .add_flag("--verify", cfg->verify,
              "Verify data with LFSR pattern"
              " after each run")
    ->group(group);

  app.add_option("--seed", cfg->seed, "LFSR seed for data pattern")
    ->default_val(1)
    ->check(CLI::PositiveNumber)
    ->group(group);
}

void registerSdmaEpCliOptions(CLI::App& app, sdma_ep::SdmaEpConfig* cfg) {
  app
    .add_option("-n,--iterations", cfg->iterations, "Number of SDMA transfers")
    ->default_val(128)
    ->group("Endpoint Options");
  app
    .add_option("-s,--transfer-size", cfg->transferSize,
                "Transfer size per iteration: number or "
                "4k/1M/2G (binary, power-of-2; default 4096)")
    ->default_val(4096)
    ->transform(CLI::Validator(transferSizeTransform,
                               "4k/1M/2G (binary) or bytes", "SIZE"))
    ->group("Endpoint Options");

  app
    .add_option("--src-gpu", cfg->srcDeviceId,
                "Source HIP device ID (-1=auto, defaults to 0)")
    ->default_val(-1)
    ->group("Endpoint Options");
  app
    .add_option("--dst-gpu", cfg->dstDeviceId,
                "Destination HIP device ID for P2P "
                "(-1=auto, defaults to 1 for P2P, 0 for --to-host)")
    ->default_val(-1)
    ->group("Endpoint Options");

  CLI::App* p2p =
    app.add_subcommand("p2p", "Simple P2P between GPU -> GPU or GPU -> Host");
  p2p
    ->add_flag("--to-host", cfg->useHostDst,
               "Use pinned host memory as destination "
               "(single GPU only)")
    ->group("Endpoint Options");
  p2p
    ->add_flag("--verify", cfg->verifyData,
               "Verify destination buffer after transfer")
    ->group("Endpoint Options");

  CLI::App* pingPong =
    app.add_subcommand("ping-pong", "Bidirectional ping-pong transfer between "
                                    "two GPUs");
  pingPong
    ->add_flag("--use-counter", cfg->useCounter, "Use counter-based completion")
    ->group("Endpoint Options");
  pingPong->add_flag("--use-flush", cfg->useFlush, "Use flush-based completion")
    ->group("Endpoint Options");

  CLI::App* bufferReuse = app.add_subcommand("buffer-reuse",
                                             "Test buffer reuse patterns");
  bufferReuse
    ->add_flag("--use-counter", cfg->useCounter, "Use counter-based completion")
    ->group("Endpoint Options");
  bufferReuse
    ->add_flag("--use-flush", cfg->useFlush, "Use flush-based completion")
    ->group("Endpoint Options");
}

void detectSdmaTestType(CLI::App& app, sdma_ep::SdmaEpConfig* cfg) {
  for (auto* sub : app.get_subcommands({})) {
    std::string name = sub->get_name();
    if ((name == "p2p" || name == "ping-pong" || name == "buffer-reuse") &&
        sub->parsed()) {
      cfg->testType = name;
      return;
    }
  }
}
