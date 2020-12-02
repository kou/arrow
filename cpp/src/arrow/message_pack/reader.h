// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

#pragma once

#include <memory>

#include "arrow/message_pack/options.h"
#include "arrow/result.h"
#include "arrow/util/macros.h"
#include "arrow/util/visibility.h"

namespace arrow {

class MemoryPool;
class Table;

namespace io {
class InputStream;
}  // namespace io

namespace message_pack {

/// A class that reads an entire MessagePack file into a Arrow Table
class ARROW_EXPORT TableReader {
 public:
  virtual ~TableReader() = default;

  /// Read the entire MessagePack file and convert it to a Arrow Table
  virtual Result<std::shared_ptr<Table>> Read() = 0;

  /// Create a TableReader instance
  static Result<std::shared_ptr<TableReader>> Make(MemoryPool* pool,
                                                   std::shared_ptr<io::InputStream> input,
                                                   const Options& options);
};

}  // namespace message_pack
}  // namespace arrow
