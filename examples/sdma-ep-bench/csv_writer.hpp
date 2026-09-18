/* Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <fstream>
#include <string>
#include <vector>

class CsvWriter {
public:
  explicit CsvWriter(const std::string& path) : stream_(path) {
  }

  void writeHeader(const std::vector<std::string>& columns) {
    bool first = true;
    for (const auto& column : columns)
      writeValue(column, first);
    stream_ << '\n';
  }

  template <typename... Values>
  void writeRow(const Values&... values) {
    bool first = true;
    (writeValue(values, first), ...);
    stream_ << '\n';
  }

private:
  void writeValue(const std::string& value, bool& first) {
    writeSeparator(first);
    const bool quoted = value.find_first_of(",\"\n") != std::string::npos;
    if (quoted)
      stream_ << '"';
    for (char character : value) {
      if (character == '"')
        stream_ << '"';
      stream_ << character;
    }
    if (quoted)
      stream_ << '"';
  }

  template <typename Value>
  void writeValue(const Value& value, bool& first) {
    writeSeparator(first);
    stream_ << value;
  }

  void writeSeparator(bool& first) {
    if (!first)
      stream_ << ',';
    first = false;
  }

  std::ofstream stream_;
};
