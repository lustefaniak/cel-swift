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

// Ported from cel-go checker/errors.go.

/// The checker's error reports, with cel-go's messages verbatim.
struct TypeErrors: Sendable {
  var errs: CELErrors

  mutating func fieldTypeMismatch(
    _ id: Int64, _ l: Location, _ name: String, _ field: CELType, _ value: CELType
  ) {
    errs.reportError(
      exprID: id, at: l,
      "expected type of field '\(name)' is '\(field.checkerDescription)' but provided type is "
        + "'\(value.checkerDescription)'")
  }

  mutating func incompatibleType(_ id: Int64, _ l: Location, _ e: Expr, _ prev: CELType, _ next: CELType) {
    errs.reportError(
      exprID: id, at: l,
      "incompatible type already exists for expression: \(ExprDebug.toDebugString(e))(\(e.id)) "
        + "old:\(prev), new:\(next)")
  }

  mutating func noMatchingOverload(
    _ id: Int64, _ l: Location, _ name: String, _ args: [CELType], _ isInstance: Bool
  ) {
    let signature = formatFunctionDeclType(resultType: nil, argumentTypes: args, isInstance: isInstance)
    errs.reportError(
      exprID: id, at: l, "found no matching overload for '\(name)' applied to '\(signature)'")
  }

  mutating func notAComprehensionRange(_ id: Int64, _ l: Location, _ t: CELType) {
    errs.reportError(
      exprID: id, at: l,
      "expression of type '\(t.checkerDescription)' cannot be range of a comprehension "
        + "(must be list, map, or dynamic)")
  }

  mutating func notAnOptionalFieldSelectionCall(_ id: Int64, _ l: Location, _ err: String) {
    errs.reportError(exprID: id, at: l, "unsupported optional field selection: \(err)")
  }

  mutating func notAnOptionalFieldSelection(_ id: Int64, _ l: Location, _ field: Expr) {
    errs.reportError(
      exprID: id, at: l, "unsupported optional field selection: \(ExprDebug.toDebugString(field))")
  }

  mutating func notAType(_ id: Int64, _ l: Location, _ typeName: String) {
    errs.reportError(exprID: id, at: l, "'\(typeName)' is not a type")
  }

  mutating func notAMessageType(_ id: Int64, _ l: Location, _ typeName: String) {
    errs.reportError(exprID: id, at: l, "'\(typeName)' is not a message type")
  }

  mutating func referenceRedefinition(
    _ id: Int64, _ l: Location, _ e: Expr, _ prev: ReferenceInfo, _ next: ReferenceInfo
  ) {
    errs.reportError(
      exprID: id, at: l,
      "reference already exists for expression: \(ExprDebug.toDebugString(e))(\(e.id)) "
        + "old:\(prev), new:\(next)")
  }

  mutating func typeDoesNotSupportFieldSelection(_ id: Int64, _ l: Location, _ t: CELType) {
    errs.reportError(
      exprID: id, at: l, "type '\(t.checkerDescription)' does not support field selection")
  }

  mutating func typeMismatch(_ id: Int64, _ l: Location, _ expected: CELType, _ actual: CELType) {
    errs.reportError(
      exprID: id, at: l,
      "expected type '\(expected.checkerDescription)' but found '\(actual.checkerDescription)'")
  }

  mutating func undefinedField(_ id: Int64, _ l: Location, _ field: String) {
    errs.reportError(exprID: id, at: l, "undefined field '\(field)'")
  }

  mutating func undeclaredReference(_ id: Int64, _ l: Location, _ container: String, _ name: String) {
    errs.reportError(
      exprID: id, at: l, "undeclared reference to '\(name)' (in container '\(container)')")
  }

  mutating func unexpectedFailedResolution(_ id: Int64, _ l: Location, _ typeName: String) {
    errs.reportError(exprID: id, at: l, "unexpected failed resolution of '\(typeName)'")
  }

  mutating func unexpectedASTType(_ id: Int64, _ l: Location, _ kind: String, _ typeName: String) {
    errs.reportError(exprID: id, at: l, "unexpected \(kind) type: \(typeName)")
  }
}
