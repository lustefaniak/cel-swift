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

// Ported from cel-go checker/types.go: assignability with type parameter substitution, the
// occurs check, substitution and the most general type of two unifiable types.

/// Whether the type is `dyn` or the well-known `google.protobuf.Any`.
func isDyn(_ t: CELType) -> Bool {
  switch t.kind {
  case .dyn, .any: return true
  default: return false
  }
}

/// Whether the type is `dyn`, `any` or the error type.
func isDynOrError(_ t: CELType) -> Bool {
  isError(t) || isDyn(t)
}

func isError(_ t: CELType) -> Bool {
  t.kind == .error
}

func isOptional(_ t: CELType) -> Bool {
  t.kind == .opaque && t.runtimeTypeName == "optional_type"
}

/// The parameter of an optional type and `true`, or the type itself and `false`.
func maybeUnwrapOptional(_ t: CELType) -> (CELType, Bool) {
  if isOptional(t), let param = t.parameters.first {
    return (param, true)
  }
  return (t, false)
}

/// Whether `t1` is equal to or less specific than `t2`; a type is less specific if it matches the
/// other type using `dyn`.
func isEqualOrLessSpecific(_ t1: CELType, _ t2: CELType) -> Bool {
  let kind1 = t1.kind
  let kind2 = t2.kind
  // The first type is less specific.
  if isDyn(t1) || kind1 == .typeParam {
    return true
  }
  // The first type is not less specific.
  if isDyn(t2) || kind2 == .typeParam {
    return false
  }
  // Types must be of the same kind to be equal.
  if kind1 != kind2 {
    return false
  }
  // With limited exceptions for ANY and JSON values, the types must agree and be equivalent in
  // order to return true.
  switch kind1 {
  case .opaque:
    let p1 = t1.parameters
    let p2 = t2.parameters
    if t1.runtimeTypeName != t2.runtimeTypeName || p1.count != p2.count {
      return false
    }
    for (a, b) in zip(p1, p2) where !isEqualOrLessSpecific(a, b) {
      return false
    }
    return true
  case .list:
    return isEqualOrLessSpecific(t1.parameters[0], t2.parameters[0])
  case .map:
    let p1 = t1.parameters
    let p2 = t2.parameters
    return isEqualOrLessSpecific(p1[0], p2[0]) && isEqualOrLessSpecific(p1[1], p2[1])
  case .type:
    return true
  default:
    return t1.isExactType(t2)
  }
}

/// Whether `t1` is assignable to `t2`, recording type parameter substitutions in `m`.
func internalIsAssignable(_ m: inout TypeMapping, _ t1: CELType, _ t2: CELType) -> Bool {
  // Process type parameters.
  let kind1 = t1.kind
  let kind2 = t2.kind
  if kind2 == .typeParam {
    // If t2 is a valid type substitution for t1, return true.
    let (valid, t2HasSub) = isValidTypeSubstitution(&m, t1, t2)
    if valid {
      return true
    }
    // If t2 is not a valid type sub for t1, and already has a known substitution return false
    // since it is not possible for t1 to be a substitution for t2.
    if t2HasSub {
      return false
    }
    // Otherwise, fall through to check whether t1 is a possible substitution for t2.
  }
  if kind1 == .typeParam {
    // Return whether t1 is a valid substitution for t2. If not, do no additional checks as the
    // possible type substitutions have been searched in both directions.
    return isValidTypeSubstitution(&m, t2, t1).valid
  }

  // Next check for wildcard types.
  if isDynOrError(t1) || isDynOrError(t2) {
    return true
  }
  // Preserve the nullness checks of the legacy type-checker.
  if kind1 == .nullType {
    return internalIsAssignableNull(t2)
  }
  if kind2 == .nullType {
    return internalIsAssignableNull(t1)
  }

  // Test for when the types do not need to agree, but are more specific than dyn.
  switch kind1 {
  case .bool, .bytes, .double, .int, .string, .uint, .any, .duration, .timestamp, .struct:
    // Test whether t2 is assignable from t1.
    return t2.isAssignable(from: t1)
  case .type:
    return kind2 == .type
  case .opaque, .list, .map:
    return kind1 == kind2 && t1.runtimeTypeName == t2.runtimeTypeName
      && internalIsAssignableList(&m, t1.parameters, t2.parameters)
  default:
    return false
  }
}

/// Whether `t2` (or its substitution) is a valid type substitution for `t1`, and whether `t2` has a
/// substitution in `m`.
///
/// `t2` is a valid substitution for `t1` if its substitution equals or is assignable to `t1`, or if
/// it does not occur within `t1`.
func isValidTypeSubstitution(
  _ m: inout TypeMapping, _ t1: CELType, _ t2: CELType
) -> (valid: Bool, hasSub: Bool) {
  // Early return if t1 and t2 are the same type.
  if t1.kind == t2.kind && t1.isExactType(t2) {
    return (true, true)
  }
  if let t2Sub = m.find(t2) {
    // Early return if t1 and t2Sub are the same, as otherwise the mapping might mark a type as
    // being a substitution for itself.
    if t1.kind == t2Sub.kind && t1.isExactType(t2Sub) {
      return (true, true)
    }
    // If the types are compatible, pick the more general type and return true.
    if internalIsAssignable(&m, t1, t2Sub) {
      let t2New = mostGeneral(t1, t2Sub)
      // Only update the type reference map if the target type does not occur within it.
      if notReferencedIn(m, t2, t2New) {
        m.add(t2, t2New)
      }
      // Acknowledge the type agreement, and that the substitution is already tracked.
      return (true, true)
    }
    return (false, true)
  }
  if notReferencedIn(m, t2, t1) {
    m.add(t2, t1)
    return (true, false)
  }
  return (false, false)
}

/// Whether each type in `l1` is assignable to the type at the same index in `l2`.
func internalIsAssignableList(_ m: inout TypeMapping, _ l1: [CELType], _ l2: [CELType]) -> Bool {
  if l1.count != l2.count {
    return false
  }
  for (t1, t2) in zip(l1, l2) where !internalIsAssignable(&m, t1, t2) {
    return false
  }
  return true
}

/// Whether the type is nullable.
func internalIsAssignableNull(_ t: CELType) -> Bool {
  isLegacyNullable(t) || t.isAssignable(from: .null)
}

/// Preserves the null-ness compatibility of the original type-checker implementation.
func isLegacyNullable(_ t: CELType) -> Bool {
  switch t.kind {
  case .opaque, .struct, .any, .duration, .timestamp: return true
  default: return false
  }
}

/// Whether `t1` is assignable to `t2`, keeping the substitutions in `m` if so and leaving `m`
/// unchanged if not (cel-go returns an updated copy or nil).
func unifyAssignable(_ m: inout TypeMapping, _ t1: CELType, _ t2: CELType) -> Bool {
  m.trying { internalIsAssignable(&$0, t1, t2) }
}

/// Whether the types in `l1` are assignable to those in `l2`, keeping the substitutions in `m` if so
/// and leaving `m` unchanged if not.
func unifyAssignableList(_ m: inout TypeMapping, _ l1: [CELType], _ l2: [CELType]) -> Bool {
  m.trying { internalIsAssignableList(&$0, l1, l2) }
}

/// The more general of two types which are known to unify.
func mostGeneral(_ t1: CELType, _ t2: CELType) -> CELType {
  isEqualOrLessSpecific(t1, t2) ? t1 : t2
}

/// Whether `t` does not occur, directly or through substitutions, within `withinType` (the occurs
/// check of type unification).
func notReferencedIn(_ m: TypeMapping, _ t: CELType, _ withinType: CELType) -> Bool {
  if t.isExactType(withinType) {
    return false
  }
  switch withinType.kind {
  case .typeParam:
    guard let sub = m.find(withinType) else {
      return true
    }
    return notReferencedIn(m, t, sub)
  case .opaque, .list, .map, .type:
    for param in withinType.parameters where !notReferencedIn(m, t, param) {
      return false
    }
    return true
  default:
    return true
  }
}

/// Replaces all direct and indirect occurrences of bound type parameters; unbound type parameters
/// become `dyn` when `typeParamToDyn` is set.
func substitute(_ m: TypeMapping, _ t: CELType, _ typeParamToDyn: Bool) -> CELType {
  if let sub = m.find(t) {
    return substitute(m, sub, typeParamToDyn)
  }
  let kind = t.kind
  if typeParamToDyn && kind == .typeParam {
    return .dyn
  }
  switch t {
  case .opaque(let name, let params):
    return .opaque(name: name, parameters: params.map { substitute(m, $0, typeParamToDyn) })
  case .list(let elem):
    return .list(substitute(m, elem, typeParamToDyn))
  case .map(let key, let value):
    return .map(key: substitute(m, key, typeParamToDyn), value: substitute(m, value, typeParamToDyn))
  case .type(let param?):
    return .type(substitute(m, param, typeParamToDyn))
  default:
    return t
  }
}

/// The function type the checker unifies call arguments against: `function(result, args...)`.
func newFunctionType(_ resultType: CELType, _ argumentTypes: [CELType]) -> CELType {
  .opaque(name: "function", parameters: [resultType] + argumentTypes)
}
