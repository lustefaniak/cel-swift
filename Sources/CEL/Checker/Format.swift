// Copyright 2023 Google LLC
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

// Ported from cel-go checker/format.go (FormatCELType and the function signature formatting).
// FormatCheckedType, which formats `cel.expr.Type` protos, is not ported: the core has no protobuf
// types, and FormatCELType produces the same strings.

extension CELType {
  /// The type as the checker writes it in debug output and error messages (cel-go `FormatCELType`):
  /// `int`, `list(string)`, `map(string, dyn)`, `wrapper(int)`, `!error!`, `_var0`, `type(int)`.
  ///
  /// Unlike ``description``, type parameters are not wrapped in angle brackets, `null_type` is
  /// `null` and the well-known types use their short names.
  package var checkerDescription: String {
    switch kind {
    case .any:
      return "any"
    case .duration:
      return "duration"
    case .error:
      return "!error!"
    case .nullType:
      return "null"
    case .timestamp:
      return "timestamp"
    case .typeParam:
      return runtimeTypeName
    case .opaque:
      if runtimeTypeName == "function" {
        let params = parameters
        if let result = params.first {
          return formatFunctionDeclType(
            resultType: result, argumentTypes: Array(params.dropFirst()), isInstance: false)
        }
      }
    case .unspecified:
      return ""
    default:
      break
    }
    let params = parameters
    if params.isEmpty {
      return declaredTypeName
    }
    return "\(runtimeTypeName)(\(params.map(\.checkerDescription).joined(separator: ", ")))"
  }
}

/// Formats a function signature: `(int, string) -> bool`, or `int.(string)` for an instance call
/// without a result type.
func formatFunctionDeclType(resultType: CELType?, argumentTypes: [CELType], isInstance: Bool) -> String {
  var result = ""
  var args = argumentTypes[...]
  if isInstance, let target = args.first {
    args = args.dropFirst()
    result += target.checkerDescription
    result += "."
  }
  result += "("
  result += args.map(\.checkerDescription).joined(separator: ", ")
  result += ")"
  if let resultType {
    let rt = resultType.checkerDescription
    if !rt.isEmpty {
      result += " -> "
      result += rt
    }
  }
  return result
}
