// Copyright 2018 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Ported from cel-go common/overloads/overloads.go.

/// Overload ids and function names of the standard library, as defined by cel-go.
///
/// The type checker records these ids on call expressions and the interpreter dispatches on them.
package enum Overloads {
  // Boolean logic overloads
  package static let conditional = "conditional"
  package static let logicalAnd = "logical_and"
  package static let logicalOr = "logical_or"
  package static let logicalNot = "logical_not"
  package static let notStrictlyFalse = "not_strictly_false"
  package static let equals = "equals"
  package static let notEquals = "not_equals"
  package static let lessBool = "less_bool"
  package static let lessInt64 = "less_int64"
  package static let lessInt64Double = "less_int64_double"
  package static let lessInt64Uint64 = "less_int64_uint64"
  package static let lessUint64 = "less_uint64"
  package static let lessUint64Double = "less_uint64_double"
  package static let lessUint64Int64 = "less_uint64_int64"
  package static let lessDouble = "less_double"
  package static let lessDoubleInt64 = "less_double_int64"
  package static let lessDoubleUint64 = "less_double_uint64"
  package static let lessString = "less_string"
  package static let lessBytes = "less_bytes"
  package static let lessTimestamp = "less_timestamp"
  package static let lessDuration = "less_duration"
  package static let lessEqualsBool = "less_equals_bool"
  package static let lessEqualsInt64 = "less_equals_int64"
  package static let lessEqualsInt64Double = "less_equals_int64_double"
  package static let lessEqualsInt64Uint64 = "less_equals_int64_uint64"
  package static let lessEqualsUint64 = "less_equals_uint64"
  package static let lessEqualsUint64Double = "less_equals_uint64_double"
  package static let lessEqualsUint64Int64 = "less_equals_uint64_int64"
  package static let lessEqualsDouble = "less_equals_double"
  package static let lessEqualsDoubleInt64 = "less_equals_double_int64"
  package static let lessEqualsDoubleUint64 = "less_equals_double_uint64"
  package static let lessEqualsString = "less_equals_string"
  package static let lessEqualsBytes = "less_equals_bytes"
  package static let lessEqualsTimestamp = "less_equals_timestamp"
  package static let lessEqualsDuration = "less_equals_duration"
  package static let greaterBool = "greater_bool"
  package static let greaterInt64 = "greater_int64"
  package static let greaterInt64Double = "greater_int64_double"
  package static let greaterInt64Uint64 = "greater_int64_uint64"
  package static let greaterUint64 = "greater_uint64"
  package static let greaterUint64Double = "greater_uint64_double"
  package static let greaterUint64Int64 = "greater_uint64_int64"
  package static let greaterDouble = "greater_double"
  package static let greaterDoubleInt64 = "greater_double_int64"
  package static let greaterDoubleUint64 = "greater_double_uint64"
  package static let greaterString = "greater_string"
  package static let greaterBytes = "greater_bytes"
  package static let greaterTimestamp = "greater_timestamp"
  package static let greaterDuration = "greater_duration"
  package static let greaterEqualsBool = "greater_equals_bool"
  package static let greaterEqualsInt64 = "greater_equals_int64"
  package static let greaterEqualsInt64Double = "greater_equals_int64_double"
  package static let greaterEqualsInt64Uint64 = "greater_equals_int64_uint64"
  package static let greaterEqualsUint64 = "greater_equals_uint64"
  package static let greaterEqualsUint64Double = "greater_equals_uint64_double"
  package static let greaterEqualsUint64Int64 = "greater_equals_uint64_int64"
  package static let greaterEqualsDouble = "greater_equals_double"
  package static let greaterEqualsDoubleInt64 = "greater_equals_double_int64"
  package static let greaterEqualsDoubleUint64 = "greater_equals_double_uint64"
  package static let greaterEqualsString = "greater_equals_string"
  package static let greaterEqualsBytes = "greater_equals_bytes"
  package static let greaterEqualsTimestamp = "greater_equals_timestamp"
  package static let greaterEqualsDuration = "greater_equals_duration"

  // Math overloads
  package static let addInt64 = "add_int64"
  package static let addUint64 = "add_uint64"
  package static let addDouble = "add_double"
  package static let addString = "add_string"
  package static let addBytes = "add_bytes"
  package static let addList = "add_list"
  package static let addTimestampDuration = "add_timestamp_duration"
  package static let addDurationTimestamp = "add_duration_timestamp"
  package static let addDurationDuration = "add_duration_duration"
  package static let subtractInt64 = "subtract_int64"
  package static let subtractUint64 = "subtract_uint64"
  package static let subtractDouble = "subtract_double"
  package static let subtractTimestampTimestamp = "subtract_timestamp_timestamp"
  package static let subtractTimestampDuration = "subtract_timestamp_duration"
  package static let subtractDurationDuration = "subtract_duration_duration"
  package static let multiplyInt64 = "multiply_int64"
  package static let multiplyUint64 = "multiply_uint64"
  package static let multiplyDouble = "multiply_double"
  package static let divideInt64 = "divide_int64"
  package static let divideUint64 = "divide_uint64"
  package static let divideDouble = "divide_double"
  package static let moduloInt64 = "modulo_int64"
  package static let moduloUint64 = "modulo_uint64"
  package static let negateInt64 = "negate_int64"
  package static let negateDouble = "negate_double"

  // Index overloads
  package static let indexList = "index_list"
  package static let indexMap = "index_map"
  package static let indexMessage = "index_message"

  // In operators
  package static let deprecatedIn = "in"
  package static let inList = "in_list"
  package static let inMap = "in_map"
  package static let inMessage = "in_message"

  // Size overloads
  package static let size = "size"
  package static let sizeString = "size_string"
  package static let sizeBytes = "size_bytes"
  package static let sizeList = "size_list"
  package static let sizeMap = "size_map"
  package static let sizeStringInst = "string_size"
  package static let sizeBytesInst = "bytes_size"
  package static let sizeListInst = "list_size"
  package static let sizeMapInst = "map_size"

  // String function names.
  package static let contains = "contains"
  package static let endsWith = "endsWith"
  package static let matches = "matches"
  package static let startsWith = "startsWith"

  // Extension function overloads with complex behaviors that need to be referenced in runtime and
  // static analysis cost computations.
  package static let extQuoteString = "strings_quote"

  // String function overload names.
  package static let containsString = "contains_string"
  package static let endsWithString = "ends_with_string"
  package static let matchesString = "matches_string"
  package static let startsWithString = "starts_with_string"

  // Extension function overloads with complex behaviors that need to be referenced in runtime and
  // static analysis cost computations.
  package static let extFormatString = "string_format"

  // Time-based functions.
  package static let timeGetFullYear = "getFullYear"
  package static let timeGetMonth = "getMonth"
  package static let timeGetDayOfYear = "getDayOfYear"
  package static let timeGetDate = "getDate"
  package static let timeGetDayOfMonth = "getDayOfMonth"
  package static let timeGetDayOfWeek = "getDayOfWeek"
  package static let timeGetHours = "getHours"
  package static let timeGetMinutes = "getMinutes"
  package static let timeGetSeconds = "getSeconds"
  package static let timeGetMilliseconds = "getMilliseconds"

  // Timestamp overloads for time functions without timezones.
  package static let timestampToYear = "timestamp_to_year"
  package static let timestampToMonth = "timestamp_to_month"
  package static let timestampToDayOfYear = "timestamp_to_day_of_year"
  package static let timestampToDayOfMonthZeroBased = "timestamp_to_day_of_month"
  package static let timestampToDayOfMonthOneBased = "timestamp_to_day_of_month_1_based"
  package static let timestampToDayOfWeek = "timestamp_to_day_of_week"
  package static let timestampToHours = "timestamp_to_hours"
  package static let timestampToMinutes = "timestamp_to_minutes"
  package static let timestampToSeconds = "timestamp_to_seconds"
  package static let timestampToMilliseconds = "timestamp_to_milliseconds"

  // Timestamp overloads for time functions with timezones.
  package static let timestampToYearWithTz = "timestamp_to_year_with_tz"
  package static let timestampToMonthWithTz = "timestamp_to_month_with_tz"
  package static let timestampToDayOfYearWithTz = "timestamp_to_day_of_year_with_tz"
  package static let timestampToDayOfMonthZeroBasedWithTz = "timestamp_to_day_of_month_with_tz"
  package static let timestampToDayOfMonthOneBasedWithTz = "timestamp_to_day_of_month_1_based_with_tz"
  package static let timestampToDayOfWeekWithTz = "timestamp_to_day_of_week_with_tz"
  package static let timestampToHoursWithTz = "timestamp_to_hours_with_tz"
  package static let timestampToMinutesWithTz = "timestamp_to_minutes_with_tz"
  package static let timestampToSecondsWithTz = "timestamp_to_seconds_tz"
  package static let timestampToMillisecondsWithTz = "timestamp_to_milliseconds_with_tz"

  // Duration overloads for time functions.
  package static let durationToHours = "duration_to_hours"
  package static let durationToMinutes = "duration_to_minutes"
  package static let durationToSeconds = "duration_to_seconds"
  package static let durationToMilliseconds = "duration_to_milliseconds"

  // Type conversion methods and overloads
  package static let typeConvertInt = "int"
  package static let typeConvertUint = "uint"
  package static let typeConvertDouble = "double"
  package static let typeConvertBool = "bool"
  package static let typeConvertString = "string"
  package static let typeConvertBytes = "bytes"
  package static let typeConvertTimestamp = "timestamp"
  package static let typeConvertDuration = "duration"
  package static let typeConvertType = "type"
  package static let typeConvertDyn = "dyn"

  // Int conversion functions.
  package static let intToInt = "int64_to_int64"
  package static let uintToInt = "uint64_to_int64"
  package static let doubleToInt = "double_to_int64"
  package static let stringToInt = "string_to_int64"
  package static let timestampToInt = "timestamp_to_int64"
  package static let durationToInt = "duration_to_int64"

  // Uint conversion functions.
  package static let uintToUint = "uint64_to_uint64"
  package static let intToUint = "int64_to_uint64"
  package static let doubleToUint = "double_to_uint64"
  package static let stringToUint = "string_to_uint64"

  // Double conversion functions.
  package static let doubleToDouble = "double_to_double"
  package static let intToDouble = "int64_to_double"
  package static let uintToDouble = "uint64_to_double"
  package static let stringToDouble = "string_to_double"

  // Bool conversion functions.
  package static let boolToBool = "bool_to_bool"
  package static let stringToBool = "string_to_bool"

  // Bytes conversion functions.
  package static let bytesToBytes = "bytes_to_bytes"
  package static let stringToBytes = "string_to_bytes"

  // String conversion functions.
  package static let stringToString = "string_to_string"
  package static let boolToString = "bool_to_string"
  package static let intToString = "int64_to_string"
  package static let uintToString = "uint64_to_string"
  package static let doubleToString = "double_to_string"
  package static let bytesToString = "bytes_to_string"
  package static let timestampToString = "timestamp_to_string"
  package static let durationToString = "duration_to_string"

  // Timestamp conversion functions
  package static let timestampToTimestamp = "timestamp_to_timestamp"
  package static let stringToTimestamp = "string_to_timestamp"
  package static let intToTimestamp = "int64_to_timestamp"

  // Convert duration from string
  package static let durationToDuration = "duration_to_duration"
  package static let stringToDuration = "string_to_duration"

  // Convert to dyn
  package static let toDyn = "to_dyn"

  // Comprehensions helper methods, not directly accessible via a developer.
  package static let iterator = "@iterator"
  package static let hasNext = "@hasNext"
  package static let next = "@next"

  /// Whether the function is a standard library type conversion function.
  package static func isTypeConversionFunction(_ function: String) -> Bool {
    switch function {
    case typeConvertBool, typeConvertBytes, typeConvertDouble, typeConvertDuration, typeConvertDyn,
      typeConvertInt, typeConvertString, typeConvertTimestamp, typeConvertType, typeConvertUint:
      return true
    default:
      return false
    }
  }
}
