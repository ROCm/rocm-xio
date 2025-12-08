# Makefile for simple GPU-CPU communication test

HIPCXX ?= /opt/rocm/bin/hipcc
TARGET := simple-test
BIN_DIR := ./bin

CXXFLAGS := -Wall -Wextra -std=c++17

$(BIN_DIR):
	@mkdir -p $(BIN_DIR)

all: $(BIN_DIR)/$(TARGET)

$(BIN_DIR)/$(TARGET): simple-test.hip simple-test.h | $(BIN_DIR)
	$(HIPCXX) $(CXXFLAGS) -lhsa-runtime64 -o $@ $<

clean:
	@rm -f $(BIN_DIR)/$(TARGET)

.PHONY: all clean
