<!--
Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
SPDX-License-Identifier: MIT
-->

## Base revision

The patches apply on top of:

```
remote: https://github.com/sbates130272/qemu
branch: dev/stephen/pci-mmio-bridge-submit
```

## Applying

The patches are standard `git format-patch` output and apply with `patch`,
matching the apply style used by the kernel driver series in this repo
(`patch -p1 --fuzz=3`):

```bash
git clone https://github.com/sbates130272/qemu qemu
cd qemu
git checkout dev/stephen/pci-mmio-bridge-submit
for p in <path-to>/qemu/patches/0*.patch; do
    patch -p1 --fuzz=3 < "$p"
done
```

They also apply cleanly with `git am` if you want to preserve authorship and
commit messages in the resulting tree:

```bash
git am <path-to>/qemu/patches/0*.patch
```

After applying, build as usual:

```bash
./configure --target-list=x86_64-softmmu --enable-kvm
make -j"$(nproc)"
```
