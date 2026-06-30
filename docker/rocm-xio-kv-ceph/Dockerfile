# syntax=docker/dockerfile:1
# Self-contained NVMe-KV reproduction image. Ports the proven deploy/ host-side
# KV stack (Ceph + SPDK kvdev_rados) and adds an in-image QEMU-fork build
# (pci-mmio-bridge + vfio-user-pci client) plus gen-vm tooling.
ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 SPDK_DIR=/opt/spdk

# ---- Fork pins (override: --build-arg NAME=value) ----
ARG SPDK_REPO=https://github.com/mmgaggle/spdk.git
ARG SPDK_BRANCH=rados-nkv
ARG SPDK_COMMIT=18d1d8dab
# Default: Stephen Bates' upstream QEMU branch.
ARG QEMU_FORK_REMOTE=https://github.com/sbates130272/qemu
ARG QEMU_FORK_REF=dev/stephen/pci-mmio-bridge-submit

# ---- Deps: deploy/Dockerfile apt list + QEMU-build + gen-vm tooling ----
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates curl gnupg sudo procps kmod udev jq xxd \
        build-essential meson ninja-build pkg-config \
        python3 python3-pip python3-venv \
        python3-pyelftools python3-tabulate python3-jinja2 \
        python3-configshell-fb \
        libcmocka-dev libssl-dev libnuma-dev libaio-dev uuid-dev \
        libfuse3-dev libjson-c-dev libcunit1-dev libncurses-dev \
        librados-dev librbd-dev \
        ceph ceph-common ceph-mon ceph-osd ceph-mgr ceph-mds \
        rados-objclass-dev \
        libglib2.0-dev libpixman-1-dev libslirp-dev flex bison \
        qemu-utils cloud-image-utils openssh-client iproute2 \
        ansible \
        ovmf \
        pciutils \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

# ---- SPDK: clone fork, init submodules (NON-recursive), pkgdep, configure, build ----
RUN git clone --branch "${SPDK_BRANCH}" "${SPDK_REPO}" "${SPDK_DIR}" \
    && cd "${SPDK_DIR}" \
    && if [ -n "${SPDK_COMMIT}" ]; then git checkout "${SPDK_COMMIT}"; fi \
    && git submodule update --init
RUN cd "${SPDK_DIR}" && ./scripts/pkgdep.sh || true ; rm -rf /var/lib/apt/lists/*
RUN cd "${SPDK_DIR}" \
    && ./configure --with-rbd --with-vfio-user --without-nvme-cuse \
    && make -j"$(nproc)" && test -x build/bin/nvmf_tgt

# ---- Build the fork's kv_rados_host client (used by selftest); patch --no-huge ----
RUN cd "${SPDK_DIR}/test/nvmf/kv_rados" \
    && if ! grep -q 'opts.no_huge = true' kv_rados_host.c; then \
         sed -i 's/\(opts\.iova_mode\s*=\s*"va";\)/opts.no_huge = true;\n\topts.mem_size = 512;\n\t\/* \1 *\//' kv_rados_host.c; \
       fi \
    && make

# ---- QEMU fork: client-side vfio-user-pci is default-on (CONFIG_VFIO_USER); do NOT
#      pass --enable-vfio-user-server (it enables the unused server side + pulls a
#      libvfio-user subproject that can fail the build). ----
RUN git clone "${QEMU_FORK_REMOTE}" /opt/qemu \
    && cd /opt/qemu && git checkout "${QEMU_FORK_REF}" \
    && test -f hw/pci/pci-mmio-bridge.c \
    && ./configure --target-list=x86_64-softmmu --enable-kvm --enable-slirp \
    && make -j"$(nproc)" \
    && test -x build/qemu-system-x86_64

# ---- Install our scripts ----
COPY lib/ /opt/kv/lib/
COPY entrypoint.sh /opt/kv/entrypoint.sh
RUN chmod +x /opt/kv/entrypoint.sh /opt/kv/lib/*.sh

ENV QEMU_BIN=/opt/qemu/build/qemu-system-x86_64
WORKDIR /opt/kv
ENTRYPOINT ["/opt/kv/entrypoint.sh"]
CMD ["serve"]
