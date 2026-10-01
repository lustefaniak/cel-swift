// Load-time checks that an expression's or a policy's outputs decode as the Swift output type:
// the checked output type must be compatible, and map literals must name the output struct's
// fields with values of the right types. Not a ported file.

import CEL
import CELPolicy

/// Checks outputs against the schema of the Swift output type.
struct OutputChecker {
  let schema: CELSchema
  let outputIsOptional: Bool
  var errors: CELErrors

  init(schema: CELSchema, outputIsOptional: Bool, source: any Source) {
    self.schema = schema
    self.outputIsOptional = outputIsOptional
    self.errors = CELErrors(source: source)
  }

  /// Checks the type an expression or a composed policy produces.
  mutating func checkResultType(_ produced: CELType, location: Location, exprID: Int64, isPolicy: Bool) {
    var produced = produced
    if case .opaque(name: "optional_type", parameters: let parameters) = produced, parameters.count == 1 {
      guard outputIsOptional else {
        errors.reportError(
          exprID: exprID, at: location,
          isPolicy
            ? "the policy produces no output when no match applies; add a match without a condition or decode the output as an Optional"
            : "the expression produces an optional value; decode it as an Optional")
        return
      }
      produced = parameters[0]
    }
    if !canDecode(produced, as: schema.type) {
      errors.reportError(exprID: exprID, at: location, "output type \(produced) cannot be decoded as \(schema.type)")
    }
  }

  /// Checks a literal output: map literal keys against the fields of an expected object type,
  /// recursively, and list literals element by element.
  mutating func checkLiteral(_ expr: Expr, expected: CELType, in ast: AST) {
    switch (expr.kind, unwrapped(expected)) {
    case (.map(let map), .object(let name)):
      guard let structType = schema.structType(named: name) else { return }
      var given: Set<String> = []
      var hasComputedKeys = false
      for entry in map.entries {
        guard case .literal(.string(let key)) = entry.key.kind else {
          hasComputedKeys = true
          continue
        }
        given.insert(key)
        guard let field = structType.field(named: key) else {
          let names = structType.fieldNames.joined(separator: ", ")
          errors.reportError(
            exprID: entry.key.id, at: ast.sourceInfo.startLocation(entry.key.id),
            "'\(key)' is not a field of \(name) (fields: \(names))")
          continue
        }
        let valueType = ast.type(of: entry.value.id)
        if !canDecode(valueType, as: field.type) {
          errors.reportError(
            exprID: entry.value.id, at: ast.sourceInfo.startLocation(entry.value.id),
            "field '\(key)' of \(name) has type \(field.type), found \(valueType)")
        }
        checkLiteral(entry.value, expected: field.type, in: ast)
      }
      if !hasComputedKeys {
        for field in structType.fields where !field.isOptional && !given.contains(field.name) {
          errors.reportError(
            exprID: expr.id, at: ast.sourceInfo.startLocation(expr.id),
            "missing field '\(field.name)' of \(name)")
        }
      }
    case (.list(let list), .list(let element)):
      for item in list.elements {
        checkLiteral(item, expected: element, in: ast)
      }
    default:
      return
    }
  }

  /// Checks the outputs of every match of a compiled policy rule.
  mutating func checkPolicy(_ rule: CompiledRule, expected: CELType) {
    let element: CELType
    if rule.semantic == .aggregate {
      guard case .list(let e) = unwrapped(expected) else { return }  // reported by checkResultType
      element = e
    } else {
      element = expected
    }
    for match in rule.matches {
      if let output = match.output?.expr {
        checkLiteral(output.expr, expected: element, in: output)
      }
      if let nested = match.nestedRule {
        checkPolicy(nested, expected: rule.semantic == .aggregate ? .list(element) : element)
      }
    }
  }
}

/// The type an optional field or output wraps.
private func unwrapped(_ type: CELType) -> CELType {
  if case .wrapper(let inner) = type {
    return inner
  }
  return type
}

/// Whether a value of CEL type `produced` decodes as a Swift value of CEL type `expected`: `dyn`
/// is checked when the value arrives, `null` fits optional fields, and numbers convert to `double`.
func canDecode(_ produced: CELType, as expected: CELType) -> Bool {
  switch (produced, expected) {
  case (.dyn, _), (_, .dyn), (.error, _):
    return true
  case (.null, .wrapper), (.null, .object), (.null, .list), (.null, .map), (.null, .timestamp),
    (.null, .duration):
    return true  // optional fields hold null; a non-optional one fails when decoded
  case (.wrapper(let inner), .wrapper(let expectedInner)):
    return canDecode(inner, as: expectedInner)
  case (_, .wrapper(let inner)):
    return canDecode(produced, as: inner)
  case (.wrapper(let inner), _):
    return canDecode(inner, as: expected)
  case (.object(let name), .object(let expectedName)):
    return name == expectedName
  case (.map(key: .string, value: _), .object):
    return true  // keys are checked for literals, otherwise when the value is decoded
  case (.list(let element), .list(let expectedElement)):
    return canDecode(element, as: expectedElement)
  case (.map(let key, let value), .map(let expectedKey, let expectedValue)):
    return canDecode(key, as: expectedKey) && canDecode(value, as: expectedValue)
  case (.int, .double), (.uint, .double):
    return true
  default:
    return produced == expected || expected.isAssignable(from: produced)
  }
}
