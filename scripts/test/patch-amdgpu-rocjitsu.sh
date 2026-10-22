#!/bin/bash
# Patch the amdgpu DKMS source to suppress WARN_ONs that fire on
# rocjitsu emulated GPU and corrupt the guest page cache.
#
# On rocjitsu, amdgpu fires several WARN_ON/WARN_ONCE calls because:
#  - amdgpu_vm_make_compute fires when VM already is compute (repeat acquire)
#  - WARN_ONCE fires about CPU update mode with small BAR
#  - WARN_ON_ONCE fires about !is_compute_context during TLB fence
#
# These corrupt the guest page cache, causing all subsequent test
# processes to segfault in shared libraries.  Suppressing them makes
# the emulated GPU path reliable for testing.

set -euo pipefail

DKMS_SRC=$(ls -d /usr/src/amdgpu-* 2>/dev/null | head -1)
if [ -z "$DKMS_SRC" ]; then
    echo "ERROR: no amdgpu DKMS source found in /usr/src/" >&2
    exit 1
fi
echo "Patching amdgpu DKMS source: $DKMS_SRC"

AMDGPU_VM="$DKMS_SRC/amd/amdgpu/amdgpu_vm.c"
if [ ! -f "$AMDGPU_VM" ]; then
    echo "ERROR: $AMDGPU_VM not found" >&2
    exit 1
fi

sudo python3 << PYEOF
import sys

with open("$AMDGPU_VM", "r") as f:
    txt = f.read()

patches = [
    # 1. Make amdgpu_vm_make_compute idempotent
    (
        "int amdgpu_vm_make_compute(struct amdgpu_device *adev, struct amdgpu_vm *vm)\n{\n\tint r;",
        "int amdgpu_vm_make_compute(struct amdgpu_device *adev, struct amdgpu_vm *vm)\n{\n\tint r;\n\n\t/* Already compute: idempotent for rocjitsu emulated GPU */\n\tif (vm->is_compute_context)\n\t\treturn 0;"
    ),
    # 2. Suppress WARN_ONCE about CPU update mode on small BAR
    (
        "WARN_ONCE((vm->use_cpu_for_update &&\n\t\t   !amdgpu_gmc_vram_full_visible(&adev->gmc)),\n\t\t  \"CPU update of VM recommended only for large BAR system\\n\");",
        "/* rocjitsu: suppress CPU-update/small-BAR WARN_ONCE */"
    ),
    # 3. Suppress WARN_ON_ONCE(!is_compute_context) in TLB fence path
    (
        "WARN_ON_ONCE(!vm->is_compute_context);",
        "/* rocjitsu: suppress is_compute_context WARN_ON_ONCE */"
    ),
]

count = 0
for old, new in patches:
    n = txt.count(old)
    if n > 0:
        txt = txt.replace(old, new)
        print(f"  applied patch ({n} replacements): {old[:50]!r}...")
        count += n
    else:
        print(f"  skipped (not found or already applied): {old[:50]!r}...")

with open("$AMDGPU_VM", "w") as f:
    f.write(txt)
print(f"Total: {count} patch(es) applied")
PYEOF

# Rebuild and install
KVER=$(uname -r)
DKMS_VER=$(basename "$DKMS_SRC" | sed 's/amdgpu-//')
echo "Rebuilding amdgpu/$DKMS_VER for kernel $KVER..."
sudo dkms build -m amdgpu -v "$DKMS_VER" -k "$KVER" --force 2>&1 | tail -5
sudo dkms install -m amdgpu -v "$DKMS_VER" -k "$KVER" --force 2>&1 | tail -3
echo "Done. Reload amdgpu to activate patches."
