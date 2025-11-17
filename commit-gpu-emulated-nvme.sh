#!/bin/bash
#
# Commit script for GPU to Emulated NVMe P2P via IOVA Mappings
#

set -e

echo "========================================"
echo "GPU to Emulated NVMe P2P - Commit Script"
echo "========================================"
echo ""

# Navigate to project root
cd "$(dirname "$0")"

echo "Staging files..."
echo ""

# Stage main documentation
git add STEPHEN_DID_GPU_TO_EMULATED_NVME.md

# Stage test programs
git add gda-experiments/test_iova_with_hsa.hip
git add gda-experiments/test_vm_p2p_doorbell.hip
git add gda-experiments/test_hardcoded_iova.hip
git add gda-experiments/test_hip_debug.hip
git add gda-experiments/test_vm_nvme_gda.cpp
git add gda-experiments/test_vm_p2p_mapped_doorbell.hip

# Stage VM launch scripts
git add gda-experiments/test-p2p-working-config.sh
git add gda-experiments/test-nvme-p2p.sh

# Stage documentation
git add gda-experiments/VM_GPU_PASSTHROUGH_STATUS.md
git add gda-experiments/QEMU_IOVA_MAPPING_DESIGN.md
git add gda-experiments/QEMU_IOVA_PATCH_COMPLETE.md
git add gda-experiments/QEMU_P2P_QUICKSTART.md
git add gda-experiments/DYNAMIC_P2P_APPROACHES.md
git add gda-experiments/QEMU_PATCH_COMPARISON.md

# Stage this commit script
git add commit-gpu-emulated-nvme.sh

echo "Files staged:"
git status --short

echo ""
echo "========================================"
echo "Ready to commit!"
echo "========================================"
echo ""
echo "To commit, run:"
echo "  git commit -F commit-message-gpu-emulated-nvme.txt"
echo ""
echo "Or run interactively:"
echo "  git commit"
echo ""

