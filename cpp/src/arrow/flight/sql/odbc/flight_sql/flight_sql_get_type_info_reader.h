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

#include <optional>
#include "arrow/flight/sql/odbc/flight_sql/record_batch_transformer.h"

namespace driver {
namespace flight_sql {

using arrow::RecordBatch;

using std::optional;

class GetTypeInfoReader {
 private:
  std::shared_ptr<RecordBatch> record_batch_;
  int64_t current_row_;

 public:
  explicit GetTypeInfoReader(std::shared_ptr<RecordBatch> record_batch);

  bool Next();

  std::string GetTypeName();

  int32_t GetDataType();

  optional<int32_t> GetColumnSize();

  optional<std::string> GetLiteralPrefix();

  optional<std::string> GetLiteralSuffix();

  optional<std::vector<std::string>> GetCreateParams();

  int32_t GetNullable();

  bool GetCaseSensitive();

  int32_t GetSearchable();

  optional<bool> GetUnsignedAttribute();

  bool GetFixedPrecScale();

  optional<bool> GetAutoIncrement();

  optional<std::string> GetLocalTypeName();

  optional<int32_t> GetMinimumScale();

  optional<int32_t> GetMaximumScale();

  int32_t GetSqlDataType();

  optional<int32_t> GetDatetimeSubcode();

  optional<int32_t> GetNumPrecRadix();

  optional<int32_t> GetIntervalPrecision();
};

}  // namespace flight_sql
}  // namespace driver
