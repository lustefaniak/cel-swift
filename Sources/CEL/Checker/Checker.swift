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

// Ported from cel-go checker/checker.go.
//
// cel-go rewrites expression nodes in place (`SetKindCase`). Expressions are values here, so the
// checker walks the tree through `inout` parameters and writes each rewritten node back.

/// Type-checks parsed expressions (cel-go `checker.Check`).
package enum Checker {
  /// Type-checks `parsed` against `env`.
  ///
  /// Returns the checked AST, with its type map and reference map filled in, and the errors found.
  /// The AST may not be usable when there are errors. Identifiers and qualified names are rewritten
  /// to their fully qualified names, namespaced function calls lose their receiver, and message
  /// literals get fully qualified type names.
  package static func check(_ parsed: AST, source: any Source, env: CheckerEnv) -> (
    ast: AST, errors: CELErrors
  ) {
    var checker = TypeChecker(
      env: env, sourceInfo: parsed.sourceInfo, errors: TypeErrors(errs: CELErrors(source: source)))
    var expr = parsed.expr
    checker.check(&expr)

    var ast = parsed
    ast.expr = expr
    // Substitute type parameters in the final type map by their bound value or by `dyn`.
    var typeMap: [Int64: CELType] = [:]
    typeMap.reserveCapacity(checker.typeMap.count)
    for (id, t) in checker.typeMap {
      typeMap[id] = substitute(checker.mappings, t, true)
    }
    ast.typeMap = typeMap
    ast.referenceMap = checker.referenceMap
    // Remove source info for ids without a node: rewrites drop nodes, such as the operand of a
    // select replaced by a qualified identifier.
    ast.clearUnusedIDs()
    if env.jsonFieldNames {
      ast.sourceInfo.addExtension(
        SourceExtension(
          id: "json_name", version: SourceExtension.Version(major: 1, minor: 1),
          components: [.runtime]))
    }
    return (ast, checker.errors.errs)
  }
}

/// The mutable state of one type-checking pass (cel-go `checker`).
struct TypeChecker {
  var env: CheckerEnv
  let sourceInfo: SourceInfo
  var errors: TypeErrors
  var mappings = TypeMapping()
  var freeTypeVarCounter = 0
  var typeMap: [Int64: CELType] = [:]
  var referenceMap: [Int64: ReferenceInfo] = [:]

  init(env: CheckerEnv, sourceInfo: SourceInfo, errors: TypeErrors) {
    self.env = env
    self.sourceInfo = sourceInfo
    self.errors = errors
  }

  mutating func check(_ e: inout Expr) {
    switch e.kind {
    case .literal(let c):
      setType(e, literalType(c))
    case .ident:
      checkIdent(&e)
    case .select:
      checkSelect(&e)
    case .call:
      checkCall(&e)
    case .list:
      checkCreateList(&e)
    case .map:
      checkCreateMap(&e)
    case .struct:
      checkCreateStruct(&e)
    case .comprehension:
      checkComprehension(&e)
    case .unspecified:
      // cel-go formats `reflect.TypeOf(e).Name()`, which is empty for its pointer node type.
      errors.unexpectedASTType(e.id, location(e), "unspecified", "")
    }
  }

  private func literalType(_ c: Constant) -> CELType {
    switch c {
    case .bool: return .bool
    case .bytes: return .bytes
    case .double: return .double
    case .int: return .int
    case .null: return .null
    case .string: return .string
    case .uint: return .uint
    }
  }

  private mutating func checkIdent(_ e: inout Expr) {
    guard case .ident(let identName) = e.kind else { return }
    // Check to see if the identifier is declared.
    if let ident = env.resolveSimpleIdent(identName) {
      var name = trimLeadingDot(ident.decl.name)
      if ident.requiresDisambiguation {
        name = "." + name
      }
      setType(e, ident.decl.type)
      setReference(e, ReferenceInfo(name: name, value: ident.decl.value))
      // Overwrite the identifier with its fully qualified name.
      e.kind = .ident(name)
      return
    }
    setType(e, .error)
    errors.undeclaredReference(e.id, location(e), env.container.name, identName)
  }

  private mutating func checkSelect(_ e: inout Expr) {
    guard case .select(var sel) = e.kind else { return }
    // Before traversing down the tree, try to interpret as qualified name.
    if let qualifiers = computeQualifiers(e), let ident = env.resolveQualifiedIdent(qualifiers) {
      // Test-only expressions never yield qualifiers. Rewrite the node to be a variable
      // reference to the resolved fully-qualified variable name.
      var name = ident.decl.name
      if ident.requiresDisambiguation {
        name = "." + name
      }
      setType(e, ident.decl.type)
      setReference(e, ReferenceInfo(name: name, value: ident.decl.value))
      e.kind = .ident(name)
      return
    }

    var resultType = checkSelectField(e.id, &sel.operand, sel.field, optional: false)
    e.kind = .select(sel)
    if sel.testOnly {
      resultType = .bool
    }
    setType(e, substitute(mappings, resultType, false))
  }

  /// The parts of a qualified name a chain of selections on an identifier spells, or `nil`.
  private func computeQualifiers(_ e: Expr) -> [String]? {
    var qualifiers: [String] = []
    var current = e
    while case .select(let sel) = current.kind {
      // Test-only expressions are not considered for qualified name selection.
      if sel.testOnly {
        return nil
      }
      qualifiers.append(sel.field)
      current = sel.operand
      if case .ident(let name) = current.kind {
        qualifiers.append(name)
        return qualifiers.reversed()
      }
    }
    return nil
  }

  private mutating func checkOptSelect(_ e: inout Expr) {
    // Collect metadata related to the opt select call packaged by the parser.
    guard case .call(var call) = e.kind else { return }
    if call.args.count != 2 || call.isMemberFunction {
      let t = call.isMemberFunction ? " member call with" : ""
      errors.notAnOptionalFieldSelectionCall(
        e.id, location(e), "incorrect signature.\(t) argument count: \(call.args.count)")
      return
    }
    let field = call.args[1]
    guard case .literal(.string(let fieldName)) = field.kind else {
      errors.notAnOptionalFieldSelection(field.id, location(field), field)
      return
    }
    // Perform type-checking using the field selection logic.
    let resultType = checkSelectField(e.id, &call.args[0], fieldName, optional: true)
    e.kind = .call(call)
    setType(e, substitute(mappings, resultType, false))
    setReference(e, ReferenceInfo(overloadIDs: ["select_optional_field"]))
  }

  private mutating func checkSelectField(
    _ id: Int64, _ operand: inout Expr, _ field: String, optional: Bool
  ) -> CELType {
    // Interpret as field selection, first traversing down the operand.
    check(&operand)
    let operandType = substitute(mappings, getType(operand), false)

    // If the target type is 'optional', unwrap it for the sake of this check.
    let (targetType, isOpt) = maybeUnwrapOptional(operandType)

    // Assume error type by default as most types do not support field selection.
    var resultType = CELType.error
    switch targetType.kind {
    case .map:
      // Maps yield their value type as the selection result type.
      resultType = targetType.parameters[1]
    case .struct:
      // Objects yield their field type declaration as the selection result type, but only if the
      // field is defined.
      if let fieldType = lookupFieldType(id, targetType.runtimeTypeName, field) {
        resultType = fieldType
      }
    case .typeParam:
      // Set the operand type to DYN to prevent assignment to a potentially incorrect type at a
      // later point in type-checking. The isAssignable call updates the type substitutions for the
      // type param under the covers.
      _ = isAssignable(.dyn, targetType)
      resultType = .dyn
    default:
      // Dynamic / error values are treated as DYN type. Errors are handled this way as well in
      // order to allow forward progress on the check.
      if !isDynOrError(targetType) {
        errors.typeDoesNotSupportFieldSelection(id, location(id), targetType)
      }
      resultType = .dyn
    }

    // If the target type was optional coming in, then the result must be optional going out.
    if isOpt || optional {
      return .optional(resultType)
    }
    return resultType
  }

  private mutating func checkCall(_ e: inout Expr) {
    // Note: similar logic exists within the interpreter's planner.
    guard case .call(var call) = e.kind else { return }
    let fnName = call.function
    if fnName == Operators.optSelect {
      checkOptSelect(&e)
      return
    }

    // Traverse arguments.
    for i in call.args.indices {
      check(&call.args[i])
    }

    // Regular static call with simple name.
    guard var target = call.target else {
      e.kind = .call(call)
      // Check for the existence of the function.
      guard let fn = env.lookupFunction(fnName) else {
        errors.undeclaredReference(e.id, location(e), env.container.name, fnName)
        setType(e, .error)
        return
      }
      // Overwrite the function name with its fully qualified resolved name.
      e.kind = .call(Expr.Call(function: fn.name, args: call.args))
      resolveOverloadOrError(e, fn, target: nil, args: call.args)
      return
    }

    // If a receiver 'target' is present, it may either be a receiver function, or a namespaced
    // function, but not both. Given a.b.c() either a.b.c is a function or c is a function with
    // target a.b.
    //
    // Check whether the target is a namespaced function name.
    if let qualifiedPrefix = Container.qualifiedName(of: target) {
      let maybeQualifiedName = qualifiedPrefix + "." + fnName
      if let fn = env.lookupFunction(maybeQualifiedName) {
        // The function name is namespaced and so preserving the target operand would be an
        // inaccurate representation of the desired evaluation behavior. Overwrite with the
        // fully-qualified resolved function name sans receiver target.
        e.kind = .call(Expr.Call(function: fn.name, args: call.args))
        resolveOverloadOrError(e, fn, target: nil, args: call.args)
        return
      }
    }

    // Regular instance call.
    check(&target)
    call.target = target
    e.kind = .call(call)
    // Function found, attempt overload resolution.
    if let fn = env.lookupFunction(fnName) {
      resolveOverloadOrError(e, fn, target: target, args: call.args)
      return
    }
    // Function name not declared, record error.
    setType(e, .error)
    errors.undeclaredReference(e.id, location(e), env.container.name, fnName)
  }

  private mutating func resolveOverloadOrError(
    _ e: Expr, _ fn: FunctionDecl, target: Expr?, args: [Expr]
  ) {
    // Attempt to resolve the overload.
    guard let resolution = resolveOverload(e, fn, target: target, args: args) else {
      // No such overload, error noted in the resolveOverload call, type recorded here.
      setType(e, .error)
      return
    }
    // Overload found.
    setType(e, resolution.type)
    setReference(e, resolution.reference)
  }

  private mutating func resolveOverload(
    _ call: Expr, _ fn: FunctionDecl, target: Expr?, args: [Expr]
  ) -> (type: CELType, reference: ReferenceInfo)? {
    var argTypes: [CELType] = []
    if let target {
      argTypes.append(getType(target))
    }
    for arg in args {
      argTypes.append(getType(arg))
    }

    var resultType: CELType?
    var checkedRef: ReferenceInfo?
    for overload in fn.overloads {
      // Determine whether the overload is currently considered.
      if env.isOverloadDisabled(overload.id) {
        continue
      }

      // Ensure the call style for the overload matches.
      if (target == nil && overload.isMemberFunction) || (target != nil && !overload.isMemberFunction) {
        // Not a compatible call style.
        continue
      }

      // Alternative type-checking behavior when the logical operators are compacted into variadic
      // AST representations.
      if fn.name == Operators.logicalAnd || fn.name == Operators.logicalOr {
        let ref = ReferenceInfo(overloadIDs: [overload.id])
        for (i, argType) in argTypes.enumerated() where !isAssignable(argType, .bool) {
          errors.typeMismatch(args[i].id, location(args[i].id), .bool, argType)
          resultType = .error
        }
        if let resultType, isError(resultType) {
          return nil
        }
        return (.bool, ref)
      }

      var overloadType = newFunctionType(overload.resultType, overload.argTypes)
      let typeParams = overload.typeParams
      if !typeParams.isEmpty {
        // Instantiate the overload's type with fresh type variables.
        var substitutions = TypeMapping()
        for typeParam in typeParams {
          substitutions.add(.typeParam(typeParam), newTypeVar())
        }
        overloadType = substitute(substitutions, overloadType, false)
      }

      let overloadParams = overloadType.parameters
      let candidateArgTypes = Array(overloadParams.dropFirst())
      if isAssignableList(argTypes, candidateArgTypes) {
        if checkedRef == nil {
          checkedRef = ReferenceInfo(overloadIDs: [overload.id])
        } else {
          checkedRef?.addOverload(overload.id)
        }

        // First matching overload, determines result type.
        let fnResultType = substitute(mappings, overloadParams[0], false)
        if let current = resultType {
          if !isDyn(current) && !fnResultType.isExactType(current) {
            resultType = .dyn
          }
        } else {
          resultType = fnResultType
        }
      }
    }

    guard let resultType, let checkedRef else {
      let substituted = argTypes.map { substitute(mappings, $0, true) }
      errors.noMatchingOverload(call.id, location(call), fn.name, substituted, target != nil)
      return nil
    }
    return (resultType, checkedRef)
  }

  private mutating func checkCreateList(_ e: inout Expr) {
    guard case .list(var create) = e.kind else { return }
    var elemsType: CELType?
    let optionals = Set(create.optionalIndices)
    for i in create.elements.indices {
      check(&create.elements[i])
      let elem = create.elements[i]
      var elemType = getType(elem)
      if optionals.contains(Int32(i)) {
        let (unwrapped, isOptional) = maybeUnwrapOptional(elemType)
        elemType = unwrapped
        if !isOptional && !isDyn(elemType) {
          errors.typeMismatch(elem.id, location(elem), .optional(elemType), elemType)
        }
      }
      elemsType = joinTypes(elem, elemsType, elemType)
    }
    e.kind = .list(create)
    // If the list is empty, assign a free type var to the element type.
    setType(e, .list(elemsType ?? newTypeVar()))
  }

  private mutating func checkCreateMap(_ e: inout Expr) {
    guard case .map(var mapVal) = e.kind else { return }
    var mapKeyType: CELType?
    var mapValueType: CELType?
    for i in mapVal.entries.indices {
      check(&mapVal.entries[i].key)
      let key = mapVal.entries[i].key
      mapKeyType = joinTypes(key, mapKeyType, getType(key))

      check(&mapVal.entries[i].value)
      let val = mapVal.entries[i].value
      var valType = getType(val)
      if mapVal.entries[i].isOptional {
        let (unwrapped, isOptional) = maybeUnwrapOptional(valType)
        valType = unwrapped
        if !isOptional && !isDyn(valType) {
          errors.typeMismatch(val.id, location(val), .optional(valType), valType)
        }
      }
      mapValueType = joinTypes(val, mapValueType, valType)
    }
    e.kind = .map(mapVal)
    if let mapKeyType, let mapValueType {
      setType(e, .map(key: mapKeyType, value: mapValueType))
    } else {
      // If the map is empty, assign free type variables to the key and value type.
      let keyType = newTypeVar()
      let valueType = newTypeVar()
      setType(e, .map(key: keyType, value: valueType))
    }
  }

  private mutating func checkCreateStruct(_ e: inout Expr) {
    guard case .struct(var msgVal) = e.kind else { return }
    // Determine the type of the message.
    var resultType = CELType.error
    guard let ident = env.resolveTypeIdent(msgVal.typeName) else {
      errors.undeclaredReference(e.id, location(e), env.container.name, msgVal.typeName)
      setType(e, .error)
      return
    }
    // Ensure the type name is fully qualified in the AST.
    var typeName = ident.name
    msgVal.typeName = typeName
    setReference(e, ReferenceInfo(name: typeName))
    let identKind = ident.type.kind
    if identKind != .error {
      if identKind != .type {
        errors.notAType(e.id, location(e), ident.type.declaredTypeName)
      } else if let described = ident.type.parameters.first {
        resultType = described
        // Backwards compatibility test between well-known types and message types. In this
        // context, the type is being instantiated by its protobuf name which is not ideal or
        // recommended, but some users expect this to work.
        if isWellKnownType(resultType) {
          typeName = wellKnownTypeName(resultType)
        } else if resultType.kind == .struct {
          typeName = resultType.declaredTypeName
        } else {
          errors.notAMessageType(e.id, location(e), resultType.declaredTypeName)
          resultType = .error
        }
      }
    }
    setType(e, resultType)

    // Check the field initializers.
    for i in msgVal.fields.indices {
      check(&msgVal.fields[i].value)
      let field = msgVal.fields[i]
      let fieldType = lookupFieldType(field.id, typeName, field.name) ?? .error

      var valType = getType(field.value)
      if field.isOptional {
        let (unwrapped, isOptional) = maybeUnwrapOptional(valType)
        valType = unwrapped
        if !isOptional && !isDyn(valType) {
          errors.typeMismatch(field.value.id, location(field.value), .optional(valType), valType)
        }
      }
      if !isAssignable(fieldType, valType) {
        errors.fieldTypeMismatch(field.id, location(field.id), field.name, fieldType, valType)
      }
    }
    e.kind = .struct(msgVal)
  }

  private mutating func checkComprehension(_ e: inout Expr) {
    guard case .comprehension(var comp) = e.kind else { return }
    check(&comp.iterRange)
    check(&comp.accuInit)
    let rangeType = substitute(mappings, getType(comp.iterRange), false)

    // Create a scope for the comprehension since it has a local accumulation variable. This scope
    // will contain the accumulation variable used to compute the result.
    let accuType = getType(comp.accuInit)
    env = env.enterScope()
    try? env.addIdents(VariableDecl(name: comp.accuVar, type: accuType))

    var varType: CELType
    var var2Type: CELType?
    switch rangeType.kind {
    case .list:
      // The list element type for one-variable comprehensions.
      varType = rangeType.parameters[0]
      if comp.hasIterVar2 {
        // The list index (int) and the element type for two-variable comprehensions.
        var2Type = varType
        varType = .int
      }
    case .map:
      // The map entry key for all comprehension types.
      varType = rangeType.parameters[0]
      if comp.hasIterVar2 {
        // The map entry value for two-variable comprehensions.
        var2Type = rangeType.parameters[1]
      }
    case .dyn, .error, .typeParam:
      // Set the range type to DYN to prevent assignment to a potentially incorrect type at a later
      // point in type-checking. The isAssignable call updates the type substitutions for the type
      // param under the covers.
      _ = isAssignable(.dyn, rangeType)
      // Set the range iteration variable to type DYN as well.
      varType = .dyn
      if comp.hasIterVar2 {
        var2Type = .dyn
      }
    default:
      errors.notAComprehensionRange(comp.iterRange.id, location(comp.iterRange), rangeType)
      varType = .error
      if comp.hasIterVar2 {
        var2Type = .error
      }
    }

    // Create a block scope for the loop.
    env = env.enterScope()
    try? env.addIdents(VariableDecl(name: comp.iterVar, type: varType))
    if comp.hasIterVar2, let var2Type {
      try? env.addIdents(VariableDecl(name: comp.iterVar2, type: var2Type))
    }
    // Check the variable references in the condition and step.
    check(&comp.loopCondition)
    assertType(comp.loopCondition, .bool)
    check(&comp.loopStep)
    assertType(comp.loopStep, accuType)
    // Exit the loop's block scope before checking the result.
    env = env.exitScope()
    check(&comp.result)
    // Exit the comprehension scope.
    env = env.exitScope()
    e.kind = .comprehension(comp)
    setType(e, substitute(mappings, getType(comp.result), false))
  }

  /// Checks compatibility of joined types, and returns the most general common type.
  private mutating func joinTypes(_ e: Expr, _ previous: CELType?, _ current: CELType) -> CELType {
    guard let previous else {
      return current
    }
    if isAssignable(previous, current) {
      // The spec joins `null` into the nullable type it is assigned to ([msg, null] is list(msg)) and a
      // primitive into its wrapper ([1, wrapper(int)] is list(wrapper(int))). cel-go's mostGeneral deduces
      // list(null_type) and list(int) for these (docs/divergences.md).
      if current == .null {
        return previous
      }
      if case .wrapper(let wrapped) = current, previous == wrapped {
        return current
      }
      return mostGeneral(previous, current)
    }
    if env.aggLitElemType == .dyn {
      return .dyn
    }
    errors.typeMismatch(e.id, location(e), previous, current)
    return .error
  }

  private mutating func newTypeVar() -> CELType {
    let id = freeTypeVarCounter
    freeTypeVarCounter += 1
    return .typeParam("_var\(id)")
  }

  private mutating func isAssignable(_ t1: CELType, _ t2: CELType) -> Bool {
    if let subs = unifyAssignable(mappings, t1, t2) {
      mappings = subs
      return true
    }
    return false
  }

  private mutating func isAssignableList(_ l1: [CELType], _ l2: [CELType]) -> Bool {
    if let subs = unifyAssignableList(mappings, l1, l2) {
      mappings = subs
      return true
    }
    return false
  }

  private mutating func setType(_ e: Expr, _ t: CELType) {
    if let old = typeMap[e.id], !old.isExactType(t) {
      errors.incompatibleType(e.id, location(e), e, old, t)
      return
    }
    typeMap[e.id] = t
  }

  private func getType(_ e: Expr) -> CELType {
    typeMap[e.id] ?? .dyn
  }

  private mutating func setReference(_ e: Expr, _ r: ReferenceInfo) {
    if let old = referenceMap[e.id], !old.isEqual(to: r) {
      errors.referenceRedefinition(e.id, location(e), e, old, r)
      return
    }
    referenceMap[e.id] = r
  }

  private mutating func assertType(_ e: Expr, _ t: CELType) {
    let actual = getType(e)
    if !isAssignable(t, actual) {
      errors.typeMismatch(e.id, location(e), t, actual)
    }
  }

  private func location(_ e: Expr) -> Location {
    location(e.id)
  }

  private func location(_ id: Int64) -> Location {
    sourceInfo.startLocation(id)
  }

  private mutating func lookupFieldType(_ exprID: Int64, _ structType: String, _ fieldName: String)
    -> CELType?
  {
    if env.provider.findStructType(structType) == nil {
      // This should not happen, anyway, report an error.
      errors.unexpectedFailedResolution(exprID, location(exprID), structType)
      return nil
    }
    if let ft = env.provider.findStructFieldType(structType, fieldName: fieldName) {
      if env.jsonFieldNames && !ft.isJSONField {
        errors.undefinedField(exprID, location(exprID), fieldName)
      }
      return ft.type
    }
    errors.undefinedField(exprID, location(exprID), fieldName)
    return nil
  }
}

/// Whether a type is a well-known protobuf type that may be instantiated by its message name.
private func isWellKnownType(_ t: CELType) -> Bool {
  switch t.kind {
  case .any, .timestamp, .duration, .dyn, .nullType:
    return true
  case .bool, .bytes, .double, .int, .string, .uint:
    return t.isAssignable(from: .null)
  case .list:
    return t.parameters[0] == .dyn
  case .map:
    return t.parameters[0] == .string && t.parameters[1] == .dyn
  default:
    return false
  }
}

private func wellKnownTypeName(_ t: CELType) -> String {
  switch t.kind {
  case .any: return "google.protobuf.Any"
  case .bool: return "google.protobuf.BoolValue"
  case .bytes: return "google.protobuf.BytesValue"
  case .double: return "google.protobuf.DoubleValue"
  case .duration: return "google.protobuf.Duration"
  case .dyn: return "google.protobuf.Value"
  case .int: return "google.protobuf.Int64Value"
  case .list: return "google.protobuf.ListValue"
  case .nullType: return "google.protobuf.NullValue"
  case .map: return "google.protobuf.Struct"
  case .string: return "google.protobuf.StringValue"
  case .timestamp: return "google.protobuf.Timestamp"
  case .uint: return "google.protobuf.UInt64Value"
  default: return ""
  }
}
