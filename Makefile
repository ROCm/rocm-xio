# Makefile for building librocm-axiio.a

# The top-level target
TARGET := rocm-axiio

# Define the recursive wildcard function
# $1: list of directories to search in
# $2: list of patterns to match
rwildcard = $(foreach d,$(wildcard $(1:=/*)),$(call rwildcard,$d,$2) \
	$(filter $(subst *,%,$2),$d))

# Directories
INCLUDE_DIR := include
BIN_DIR := bin
LIB_DIR := lib
BUILD_DIR ?= build

# Build targets
LIBTARGET := ${LIB_DIR}/lib$(TARGET).a
TESTER := ${BIN_DIR}/axiio-tester
default: $(LIBTARGET)
all: $(LIBTARGET) $(TESTER)

# HIP variables
HIP_INCLUDE_DIR  ?= /opt/rocm/include
HIPCXX ?= /opt/rocm/bin/hipcc

# Tool variables
AR ?= ar
OBJDUMP ?= /opt/rocm/lib/llvm/bin/llvm-objdump
CLANGXX ?= /opt/rocm/llvm/bin/clang++

# Project directories
ENDPOINTS_DIR := endpoints
COMMON_DIR := common
TESTER_DIR := tester

# Find all source files with .hip extension
LIB_HEADERS := $(call rwildcard,$(INCLUDE_DIR) $(ENDPOINTS_DIR),*.h)
LIB_SOURCES := $(call rwildcard,$(ENDPOINTS_DIR) $(COMMON_DIR),*.hip)
LIB_OBJECTS := $(patsubst %.hip,$(BUILD_DIR)/%.o,$(LIB_SOURCES))

# Tester source file
TESTER_SOURCE := $(TESTER_DIR)/axiio-tester.hip
TESTER_OBJECT := $(BUILD_DIR)/$(TESTER_SOURCE:.hip=.o)

# CXX variables and flags
override CXXFLAGS  += -fgpu-rdc -Wall -Wextra -Wno-unused-parameter

$(BIN_DIR):
	@mkdir -p $(BIN_DIR)

$(LIB_DIR):
	@mkdir -p $(LIB_DIR)

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

$(LIBTARGET): $(LIB_OBJECTS) $(LIB_HEADERS) | $(LIB_DIR)
	$(AR) rcsD $@ $(LIB_OBJECTS)

$(TESTER): $(TESTER_OBJECT) $(LIBTARGET) | $(BIN_DIR)
	$(HIPCXX) $(CXXFLAGS) -I$(INCLUDE_DIR) -o $@ $^

$(BUILD_DIR)/%.o: %.hip | $(BUILD_DIR)
	@mkdir -p $(dir $@)
	$(HIPCXX) $(CXXFLAGS) -I$(INCLUDE_DIR) -c -o $@ $<

asm: $(LIBTARGET)
	unbuffer $(OBJDUMP) \
	  --demangle --disassemble-all $< | less -R

list:
	@echo "Supported GPUs:"
	@$(CLANGXX) --target=amdgcn --print-supported-cpus 2>&1 | \
		grep -E gfx[1-9] | sort -t'x' -k2,2n | sed 's/^[ \t]*/  /'

clean:
	@$(RM) -rf $(BIN_DIR) $(LIB_DIR) $(BUILD_DIR)

.PHONY: all default clean asm list
