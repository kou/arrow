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

#include "arrow/message_pack/reader.h"

namespace arrow {

namespace message_pack {

class TableReaderImpl : public TableReader,
                        public std::enable_shared_from_this<TableReaderImpl> {
};

Result<std::shared_ptr<TableReader>> TableReader::Make(
    MemoryPool* pool, std::shared_ptr<io::InputStream> input,
    const Options& options) {
  auto impl = std::make_shared<TableReaderImpl>(pool, input, options);
  RETURN_NOT_OK(impl->Init(input));
  return impl;
}

}  // namespace message_pack
}  // namespace arrow
