# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# The vfu-doorbell servers (ringee and ringer), ready to run. The binary is
# built in, and run in, the libvfio-user fork image, so it is linked against
# exactly the library it runs with and a stack needs no host build or mount.
#
#   docker build -f tools/vfu-doorbell/Dockerfile -t rocm-xio-vfu-doorbell .
#   docker run --rm rocm-xio-vfu-doorbell /opt/vfu/vfu-doorbell --role ringee \
#       --socket /run/vfu/ringee.sock
#
# The build context is the repository root: vfu-ring shares an ioctl header
# with kernel/vfu-dma, which CMake looks for while configuring. Only the
# server is built; vfu-ring is a guest tool and is built in the guest.

# The libvfio-user fork image the pinned QEMU is built against (vfu.3719c3a). It
# has vfu_mmio_write(), which the ringer's default write path needs: against
# upstream libvfio-user the ringer builds without it and only its "sgl" path
# works. It is on Docker Hub, so this builds without any local image.
ARG BASE=docker.io/sbates130272/batesste-ci-images-ubuntu-libvfio-user-sbates-fork:vfu.3719c3a

FROM ${BASE} AS build
COPY tools/vfu-doorbell /src/tools/vfu-doorbell
COPY kernel/vfu-dma /src/kernel/vfu-dma
RUN cmake -S /src/tools/vfu-doorbell -B /build \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS=-fno-omit-frame-pointer \
    && cmake --build /build --target vfu-doorbell -j"$(nproc)"

FROM ${BASE}
COPY --from=build /build/vfu-doorbell /opt/vfu/vfu-doorbell
# The commit the binary was built from, so a pulled image says what it is.
ARG REVISION=unknown
LABEL org.opencontainers.image.source="https://github.com/ROCm/rocm-xio" \
      org.opencontainers.image.revision="${REVISION}"
