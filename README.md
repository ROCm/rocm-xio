# rocm-xio

[![MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://github.com/ROCm/rocm-xio/blob/main/LICENSE.md)
[![Build](https://github.com/ROCm/rocm-xio/actions/workflows/build-check.yml/badge.svg)](https://github.com/ROCm/rocm-xio/actions/workflows/build-check.yml)
[![Docs](https://github.com/ROCm/rocm-xio/actions/workflows/docs-check.yml/badge.svg)](https://github.com/ROCm/rocm-xio/actions/workflows/docs-check.yml)
[![Test](https://github.com/ROCm/rocm-xio/actions/workflows/test-emulate.yml/badge.svg)](https://github.com/ROCm/rocm-xio/actions/workflows/test-emulate.yml)
[![Spelling](https://github.com/ROCm/rocm-xio/actions/workflows/spell-check.yml/badge.svg)](https://github.com/ROCm/rocm-xio/actions/workflows/spell-check.yml)
[![Platform](https://img.shields.io/badge/platform-linux-lightgrey.svg)](INSTALL.md)
[![ROCm](https://img.shields.io/badge/ROCm-supported-green.svg)](https://rocm.docs.amd.com)
[![Language](https://img.shields.io/badge/language-HIP%20%7C%20C%2B%2B-orange.svg)](https://rocm.docs.amd.com/projects/HIP/en/latest/)
[![nvme-ep](https://img.shields.io/badge/nvme--ep-supported-green.svg)][ep-nvme]
[![rdma-ep](https://img.shields.io/badge/rdma--ep-supported-green.svg)][ep-rdma]
[![sdma-ep](https://img.shields.io/badge/sdma--ep-supported-green.svg)][ep-sdma]
[![test-ep](https://img.shields.io/badge/test--ep-supported-green.svg)][ep-test]

> [!CAUTION]
> This release is an *early-access* software technology preview. Running
> production workloads is *not* recommended.

ROCm library for Accelerator-Initiated IO (XIO). Enables AMD GPUs to perform
direct IO to NVMe SSDs, RDMA NICs, and SDMA engines from `__device__` code
without CPU intervention.

## Installing and Using rocm-xio

See [INSTALL.md](INSTALL.md) for dependencies, supported hardware, and build
instructions.

## Documentation

Full documentation lives in the [`docs/`](docs/) directory and covers
building, endpoints, the kernel module, memory modes, and the API
reference. A hosted version is available at the [documentation
site][docs-site].

<!-- References -->

[docs-site]: https://rocm.docs.amd.com/projects/rocm-xio/en/beta-0.1.0/
[ep-nvme]: https://rocm.docs.amd.com/projects/rocm-xio/en/beta-0.1.0/reference/endpoints.html#nvme-ep-nvme-endpoint
[ep-rdma]: https://rocm.docs.amd.com/projects/rocm-xio/en/beta-0.1.0/reference/endpoints.html#rdma-ep-rdma-endpoint
[ep-sdma]: https://rocm.docs.amd.com/projects/rocm-xio/en/beta-0.1.0/reference/endpoints.html#sdma-ep-sdma-endpoint
[ep-test]: https://rocm.docs.amd.com/projects/rocm-xio/en/beta-0.1.0/reference/endpoints.html#test-ep-test-endpoint

## License

[MIT](LICENSE.md)
