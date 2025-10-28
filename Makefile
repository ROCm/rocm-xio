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

  # Include directories
INCLUDE_DIR := include

  # Library header files
LIB_HEADERS := $(call rwildcard, $(INCLUDE_DIR), *.h)
LIB_SOURCES := $(call rwildcard, endpoints, *.hip)

# CXX variables and flags
CXX_STD := c++17
override CXXFLAGS  += -fgpu-rdc -Wall -Wextra -Wno-unused-parameter

$(LIBTARGET): $(LIB_DIR)/$(TARGET).o
	$(AR) rcsD $@ $<

$(TESTER): $(TESTER).o $(LIBTARGET)
	$(HIPCXX) $(CXXFLAGS) -I$(INCLUDE_DIR) -o $@ $^

$(TESTER).o: tester/axiio-tester.hip $(LIB_HEADERS)
	$(HIPCXX) $(CXXFLAGS) -I$(INCLUDE_DIR) -c -o $@ $<

$(LIB_DIR)/$(TARGET).o: $(LIB_SOURCES) $(LIB_HEADERS)
	$(HIPCXX) $(CXXFLAGS) -I$(INCLUDE_DIR) -c -o $@ $<

asm: $(LIBTARGET)
	unbuffer $(OBJDUMP) \
	  --demangle --disassemble-all $< | less -R

list:
	@echo "Supported GPUs:"
	@$(CLANGXX) --target=amdgcn --print-supported-cpus 2>&1 | \
		grep -E gfx[1-9] | sort -t'x' -k2,2n | sed 's/^[ \t]*/  /'

clean:
	$(RM) $(LIBTARGET) $(TESTER).o $(TESTER) $(LIB_DIR)/$(TARGET).o

.PHONY: all default clean asm list
