# Makefile for building librocm-axiio with static linking

TARGET := rocm-axiio
LIBTARGET := lib$(TARGET).a
TESTER := axiio-tester

INCLUDE_DIR := include
BIN_DIR := bin
LIB_DIR := lib

TESTER := $(BIN_DIR)/$(TESTER)
LIBTARGET := $(LIB_DIR)/$(LIBTARGET)	

all: $(TESTER) $(LIBTARGET)

# HIP variables
ROCM_INSTALL_DIR := /opt/rocm
HIP_INCLUDE_DIR  := $(ROCM_INSTALL_DIR)/include
HIPCXX ?= $(ROCM_INSTALL_DIR)/bin/hipcc
AR ?= ar

# Include directories
INCLUDE_DIR := include

# Common variables and flags
CXX_STD   := c++17
CXXFLAGS  ?= -fgpu-rdc -Wall -Wextra -I$(INCLUDE_DIR)
CXXFLAGS += -Wno-unused-parameter

$(LIBTARGET): $(LIB_DIR)/$(TARGET).o
	$(AR) rcsD $@ $^

$(TESTER): $(TESTER).o $(LIBTARGET)
	$(HIPCXX) $(CXXFLAGS) -o $@ $^

$(TESTER).o: tester/axiio-tester.hip
	$(HIPCXX) $(CXXFLAGS) -c -o $@ $^

$(LIB_DIR)/$(TARGET).o: endpoints/test-ep/test-ep.hip
	$(HIPCXX) $(CXXFLAGS) -c -o $@ $^

asm:
	unbuffer /opt/rocm-7.0.2/lib/llvm/bin/llvm-objdump --demangle --disassemble-all lib/librocm-axiio.a | less -R

clean:
	$(RM) $(LIBTARGET) $(TESTER).o $(TESTER) $(LIB_DIR)/$(TARGET).o

.PHONY: all clean asm
