# Makefile for building librocm-axiio.a

# The top-level target
TARGET := rocm-axiio

# Define the recursive wildcard function
# $1: list of directories to search in
# $2: list of patterns to match
rwildcard = $(foreach d,$(wildcard $(1:=/*)),$(call rwildcard,$d,$2) \
	$(filter $(subst *,%,$2),$d))

# Directories
INCLUDE_DIR := src/include
BIN_DIR := bin
LIB_DIR := lib
BUILD_DIR ?= build

# Build targets
LIBTARGET := ${LIB_DIR}/lib$(TARGET).a
TESTER := ${BIN_DIR}/axiio-tester
default: build_info $(LIBTARGET)
all: build_info $(LIBTARGET) $(TESTER) kernel-module

# HIP variables
HIP_INCLUDE_DIR  ?= /opt/rocm/include
HIPCXX ?= /opt/rocm/bin/hipcc

# C++ compiler for host-only code (tester)
CXX ?= clang++

# Tool variables
AR ?= ar
OBJDUMP ?= /opt/rocm/lib/llvm/bin/llvm-objdump
CLANGXX ?= /opt/rocm/llvm/bin/clang++
CLANG_FORMAT ?= clang-format

# Project directories
ENDPOINTS_DIR := src/endpoints
ENDPOINTS_COMMON_DIR := src/endpoints/common
COMMON_DIR := src/common
TESTER_DIR := src/tester

# Automatically discover all available endpoints from subdirectories
# Exclude common directory from endpoint list
VALID_ENDPOINTS := $(filter-out common,$(notdir $(wildcard $(ENDPOINTS_DIR)/*)))

# Generated files
ENDPOINT_REGISTRY_GEN := $(INCLUDE_DIR)/axiio-endpoint-registry-gen.h
ENDPOINT_INCLUDES_GEN := $(INCLUDE_DIR)/axiio-endpoint-includes-gen.h

# External headers
EXTERNAL_HEADERS_DIR := $(INCLUDE_DIR)/external
NVME_KERNEL_HEADERS := $(EXTERNAL_HEADERS_DIR)/linux-nvme.h $(EXTERNAL_HEADERS_DIR)/linux-nvme_ioctl.h
NVME_EP_GENERATED := $(INCLUDE_DIR)/nvme-ep-generated.h
RDMA_HEADERS_DIR := $(EXTERNAL_HEADERS_DIR)/rdma
RDMA_HEADERS := $(RDMA_HEADERS_DIR)/ib_user_verbs.h \
                $(RDMA_HEADERS_DIR)/mlx/mlx5dv.h \
                $(RDMA_HEADERS_DIR)/bnxt/bnxt_re_abi.h \
                $(RDMA_HEADERS_DIR)/ionic/ionic.h \
                $(RDMA_HEADERS_DIR)/pvrdma/pvrdma.h

# Auto-generated vendor-specific RDMA headers
RDMA_VENDOR_HEADERS := $(ENDPOINTS_DIR)/rdma-ep/mlx/mlx5-rdma.h \
                       $(ENDPOINTS_DIR)/rdma-ep/bnxt/bnxt-rdma.h \
                       $(ENDPOINTS_DIR)/rdma-ep/ionic/ionic-rdma.h \
                       $(ENDPOINTS_DIR)/rdma-ep/pvrdma/pvrdma-rdma.h

# Find all source files with .hip extension
LIB_HEADERS := $(call rwildcard,$(INCLUDE_DIR) $(ENDPOINTS_DIR),*.h)
# Build all endpoints (automatically find all .hip files)
# Exclude common directory from ENDPOINTS_DIR to avoid duplicates
LIB_SOURCES := $(call rwildcard,$(COMMON_DIR),*.hip) \
               $(call rwildcard,$(ENDPOINTS_COMMON_DIR),*.hip) \
               $(filter-out $(ENDPOINTS_COMMON_DIR)/%,$(call rwildcard,$(ENDPOINTS_DIR),*.hip))
LIB_OBJECTS := $(patsubst %.hip,$(BUILD_DIR)/%.o,$(LIB_SOURCES))

# Tester source file
TESTER_SOURCE := $(TESTER_DIR)/axiio-tester.cpp
TESTER_OBJECT := $(BUILD_DIR)/$(TESTER_SOURCE:.cpp=.o)
# Tester depends on endpoint headers it includes (all endpoint headers)
TESTER_HEADERS := $(call rwildcard,$(ENDPOINTS_DIR),*.h) \
                  $(call rwildcard,$(INCLUDE_DIR),*.h) \
				  $(call rwildcard,$(TESTER_DIR),*.h)

# GPU architecture
OFFLOAD_ARCH ?=
DETECTED_ARCH := $(shell command -v rocminfo >/dev/null 2>&1 && \
  rocminfo 2>/dev/null | grep -o "gfx[0-9a-f]*" | head -1 || echo "")
ifneq ($(OFFLOAD_ARCH),)
  OFFLOAD_ARCH_FLAG := --offload-arch=$(OFFLOAD_ARCH)
  OFFLOAD_ARCH_MSG := $(OFFLOAD_ARCH) (specified)
else
  OFFLOAD_ARCH_FLAG :=
  ifneq ($(DETECTED_ARCH),)
    OFFLOAD_ARCH_MSG := $(DETECTED_ARCH) (auto-detected)
  else
    OFFLOAD_ARCH_MSG := default (hipcc auto-detect)
  endif
endif

# CXX variables and flags
# Only add GPU-specific flags if using hipcc (not regular g++)
ifeq ($(findstring hipcc,$(HIPCXX)),hipcc)
  override CXXFLAGS += -fgpu-rdc -Wall -Wextra -Wno-unused-parameter
  override CXXFLAGS += $(OFFLOAD_ARCH_FLAG)
else
  # For regular C++ compiler (emulate mode), use standard flags
  override CXXFLAGS += -Wall -Wextra -std=c++17
endif
# Add include paths for all discovered endpoints
override CXXFLAGS += $(foreach ep,$(VALID_ENDPOINTS),-I$(ENDPOINTS_DIR)/$(ep))

$(BIN_DIR):
	@mkdir -p $(BIN_DIR)

$(LIB_DIR):
	@mkdir -p $(LIB_DIR)

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

.PHONY: build_info
build_info: $(ENDPOINT_REGISTRY_GEN) $(ENDPOINT_INCLUDES_GEN) \
	$(NVME_EP_GENERATED)
	@echo "Building for GPU architecture: $(OFFLOAD_ARCH_MSG)"

# Generate all endpoint files (registry, includes) from discovered endpoints
# Use a sentinel file to prevent parallel generation
ENDPOINT_GEN_SENTINEL := $(BUILD_DIR)/.endpoint-files-generated

$(ENDPOINT_REGISTRY_GEN) $(ENDPOINT_INCLUDES_GEN): \
	$(ENDPOINT_GEN_SENTINEL)

$(ENDPOINT_GEN_SENTINEL): scripts/build/generate-endpoint-files.sh | \
	$(INCLUDE_DIR) $(ENDPOINTS_COMMON_DIR) $(BUILD_DIR)
	@echo "Generating endpoint files from: $(VALID_ENDPOINTS)"
	@./scripts/build/generate-endpoint-files.sh $(ENDPOINTS_DIR) \
		$(ENDPOINT_REGISTRY_GEN) \
		$(ENDPOINT_INCLUDES_GEN)
	@if command -v $(CLANG_FORMAT) >/dev/null 2>&1; then \
		$(CLANG_FORMAT) -i --style=file $(ENDPOINT_REGISTRY_GEN); \
	fi
	@touch $@

# Download NVMe headers from Linux kernel
$(NVME_KERNEL_HEADERS): scripts/build/fetch-nvme-headers.sh
	@echo "Fetching NVMe headers from Linux kernel repository..."
	@./scripts/build/fetch-nvme-headers.sh $(EXTERNAL_HEADERS_DIR)
	@echo "Generated external headers: $(NVME_KERNEL_HEADERS)"

# Generate NVMe defines from kernel headers
$(NVME_EP_GENERATED): $(EXTERNAL_HEADERS_DIR)/linux-nvme.h scripts/build/extract-nvme-defines.sh
	@echo "Extracting NVMe defines from kernel headers..."
	@./scripts/build/extract-nvme-defines.sh $(EXTERNAL_HEADERS_DIR)/linux-nvme.h $(NVME_EP_GENERATED)
	@if command -v $(CLANG_FORMAT) >/dev/null 2>&1; then \
		$(CLANG_FORMAT) -i --style=file $(NVME_EP_GENERATED); \
	fi
	@echo "Generated: $(NVME_EP_GENERATED)"

.PHONY: fetch-nvme-headers
fetch-nvme-headers: $(NVME_KERNEL_HEADERS) $(NVME_EP_GENERATED)
	@echo ""
	@echo "NVMe kernel headers downloaded to $(EXTERNAL_HEADERS_DIR)/"
	@echo "NVMe defines generated: $(NVME_EP_GENERATED)"

# Download RDMA headers from rdma-core repository
$(RDMA_HEADERS): scripts/build/fetch-rdma-headers.sh
	@echo "Fetching RDMA provider headers from rdma-core repository..."
	@./scripts/build/fetch-rdma-headers.sh $(RDMA_HEADERS_DIR)
	@echo "Generated RDMA headers in $(RDMA_HEADERS_DIR)/"

# Generate vendor-specific RDMA headers from downloaded headers
$(RDMA_VENDOR_HEADERS): $(RDMA_HEADERS) \
	scripts/build/generate-rdma-vendor-headers.sh
	@echo "Generating vendor-specific RDMA headers..."
	@./scripts/build/generate-rdma-vendor-headers.sh $(RDMA_HEADERS_DIR) \
	$(ENDPOINTS_DIR)/rdma-ep

.PHONY: fetch-rdma-headers
fetch-rdma-headers: $(RDMA_HEADERS) $(RDMA_VENDOR_HEADERS)
	@echo ""
	@echo "RDMA provider headers downloaded to $(RDMA_HEADERS_DIR)/"
	@echo "These are for reference only - the rdma-ep definitions are in"
	@echo "  src/endpoints/rdma-ep/rdma-ep.h"
	@echo "Vendor-specific headers auto-generated: mlx/, bnxt/, ionic/, pvrdma/"

.PHONY: fetch-external-headers
fetch-external-headers: fetch-nvme-headers fetch-rdma-headers
	@echo ""
	@echo "All external headers downloaded successfully"

$(LIBTARGET): $(LIB_OBJECTS) $(LIB_HEADERS) | $(LIB_DIR)
	$(AR) rcsD $@ $(LIB_OBJECTS)

# Make tester object depend on headers it includes
$(TESTER_OBJECT): $(TESTER_HEADERS) $(ENDPOINT_REGISTRY_GEN)

# Note: -lhsa-runtime64 is required for GPU doorbell HSA memory lock
# Note: -ldrm -ldrm_amdgpu is required for DRM GEM_USERPTR registration (PCI MMIO bridge)
$(TESTER): $(TESTER_OBJECT) $(LIBTARGET) | $(BIN_DIR)
	$(HIPCXX) $(CXXFLAGS) -I$(INCLUDE_DIR) -o $@ $^ -lhsa-runtime64 -ldrm -ldrm_amdgpu

# Make RDMA endpoint depend on vendor headers
$(BUILD_DIR)/src/endpoints/rdma-ep/rdma-ep.o: $(RDMA_VENDOR_HEADERS)

# Make NVMe endpoint depend on generated defines
$(BUILD_DIR)/src/endpoints/nvme-ep/nvme-ep.o: $(NVME_EP_GENERATED)

# Make common endpoint depend on NVMe generated defines (includes nvme-ep.h)
$(BUILD_DIR)/src/endpoints/common/axiio-endpoint.o: $(NVME_EP_GENERATED)

# Make all object files depend on generated registry
$(BUILD_DIR)/%.o: %.hip $(ENDPOINT_REGISTRY_GEN) | $(BUILD_DIR)
	@mkdir -p $(dir $@)
	$(eval ENDPOINT_DEFINE := $(call get_endpoint_define,$<))
	@if echo "$(HIPCXX)" | grep -q hipcc; then \
		$(HIPCXX) $(CXXFLAGS) $(ENDPOINT_DEFINE) -I$(INCLUDE_DIR) -c -o $@ $<; \
	else \
		$(HIPCXX) $(CXXFLAGS) -D__HIP_PLATFORM_AMD__ $(ENDPOINT_DEFINE) \
		  -I$(INCLUDE_DIR) -I$(HIP_INCLUDE_DIR) \
		  $(foreach ep,$(VALID_ENDPOINTS),-I$(ENDPOINTS_DIR)/$(ep)) \
		  -x c++ -c -o $@ $<; \
	fi

# Rule for .cpp files (tester) - use regular C++ compiler, not hipcc
# Need endpoint include paths and HIP platform define, but not GPU flags
$(BUILD_DIR)/%.o: %.cpp $(ENDPOINT_REGISTRY_GEN) | $(BUILD_DIR)
	@mkdir -p $(dir $@)
	@$(CXX) -std=c++17 -Wall -Wextra -Wno-unused-parameter \
	  -D__HIP_PLATFORM_AMD__ -I$(INCLUDE_DIR) -I$(HIP_INCLUDE_DIR) \
	  $(foreach ep,$(VALID_ENDPOINTS),-I$(ENDPOINTS_DIR)/$(ep)) -c -o $@ $<

# A simple target to dump the assembly of the library
asm: $(LIBTARGET)
	unbuffer $(OBJDUMP) \
	  --demangle --disassemble-all $< | less -R

#A target to list all GPUs supported by hipcc
list:
	@echo "Supported GPUs:"
	@$(CLANGXX) --target=amdgcn --print-supported-cpus 2>&1 | \
		grep -E gfx[1-9] | sort -t'x' -k2,2n | sed 's/^[ \t]*/  /'

clean: kernel-module-clean
	@$(RM) -rf $(BIN_DIR) $(LIB_DIR) $(BUILD_DIR) $(ENDPOINT_REGISTRY_GEN) \
		$(ENDPOINT_INCLUDES_GEN) $(ENDPOINT_GEN_SENTINEL)

clean-external:
	@$(RM) -rf $(EXTERNAL_HEADERS_DIR)
	@echo "Removed external headers. Run 'make fetch-nvme-headers' to re-download."

# Linting targets
lint: lint-format

# Check code formatting with clang-format (matches GitHub CI workflow)
# Uses DoozyX/clang-format-lint-action v0.18.2 compatible behavior
lint-format:
	@echo "Checking code formatting with clang-format..."
	@if ! command -v $(CLANG_FORMAT) >/dev/null 2>&1; then \
		echo "Error: clang-format not found. Install with:"; \
		echo "  sudo apt-get install clang-format"; \
		echo "Or set CLANG_FORMAT variable to the correct path."; \
		exit 1; \
	fi
	@echo "Using $(CLANG_FORMAT): $$($(CLANG_FORMAT) --version | head -1)"
	@$(CLANG_FORMAT) --version >/dev/null 2>&1 || \
	  (echo "Error: clang-format failed to run" && exit 1)
	@find . -type f \( -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \
	    -o -name '*.c' -o -name '*.cc' -o -name '*.hip' \) \
		-not -path './build/*' \
		-not -path './.git/*' \
		-not -path './stebates-*/*' \
		-not -path './stephen-dec5/*' \
		-not -path './src/include/external/*' \
		-not -path './gda-experiments/rocSHMEM/*' \
		-not -name '*.mod.c' \
		-not -name '*.mod' \
		| xargs $(CLANG_FORMAT) --dry-run --Werror --style=file \
		&& echo "✓ All files pass clang-format check" \
		|| (echo "✗ Formatting issues found. Run 'make format' to fix." \
		&& exit 1)

# Automatically fix formatting issues
format:
	@echo "Formatting code with clang-format..."
	@if ! command -v $(CLANG_FORMAT) >/dev/null 2>&1; then \
		echo "Error: clang-format not found. Install with:"; \
		echo "  sudo apt-get install clang-format"; \
		exit 1; \
	fi
	@find . -type f \( -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \
	-o -name '*.c' -o -name '*.cc' -o -name '*.hip' \) \
		-not -path './build/*' \
		-not -path './.git/*' \
		-not -path './stebates-*/*' \
		-not -path './stephen-dec5/*' \
		-not -path './src/include/external/*' \
		-not -path './gda-experiments/rocSHMEM/*' \
		-not -name '*.mod.c' \
		-not -name '*.mod' \
		| xargs $(CLANG_FORMAT) -i --style=file
	@echo "✓ Formatting complete"

# Check spelling in markdown files (requires pyspelling)
lint-spell:
	@echo "Checking spelling in markdown files..."
	@if command -v pyspelling >/dev/null 2>&1; then \
		pyspelling -c .spellcheck.yml; \
	else \
		echo "Error: pyspelling not found. Install with:"; \
		echo "  pip install pyspelling[all]"; \
		echo "  sudo apt-get install aspell aspell-en"; \
		echo ""; \
		echo "Or run spell checking via GitHub Actions workflow."; \
		exit 1; \
	fi

# Run all linting checks (format + spell)
lint-all: lint-format lint-spell
	@echo "✓ All linting checks passed"

# Kernel module
KERNEL_MODULE_DIR := kernel/rocm-axiio
KERNEL_MODULE := $(KERNEL_MODULE_DIR)/rocm-axiio.ko

.PHONY: kernel-module kernel-module-install kernel-module-clean
kernel-module: $(KERNEL_MODULE)

$(KERNEL_MODULE):
	$(MAKE) -C $(KERNEL_MODULE_DIR)

kernel-module-install: $(KERNEL_MODULE)
	$(MAKE) -C $(KERNEL_MODULE_DIR) install

kernel-module-clean:
	$(MAKE) -C $(KERNEL_MODULE_DIR) clean

.PHONY: all default clean asm list build_info lint lint-format format \
	lint-spell lint-all rdma-ep-tester kernel-module kernel-module-install \
	kernel-module-clean
