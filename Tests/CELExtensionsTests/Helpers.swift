// Helpers to call extension functions through their runtime bindings, the way the interpreter's
// dispatcher does, until the interpreter can evaluate expressions end to end.

import Testing

@testable import CEL
@testable import CELExtensions

/// The dispatcher of a library: bindings keyed by overload id and function name.
struct Dispatcher {
  let bindings: [String: FunctionBinding]

  init(_ library: Library) {
    do {
      bindings = try library.bindings()
    } catch {
      Issue.record("bindings failed: \(error)")
      bindings = [:]
    }
  }

  /// Calls `function` by name (parse-only dispatch) with the arguments.
  func call(_ function: String, _ args: Value...) -> Value {
    call(function, overload: function, args)
  }

  /// Calls the binding for an overload id (checked dispatch), falling back to the function name.
  func call(_ function: String, overload: String, _ args: [Value]) -> Value {
    guard let binding = bindings[overload] ?? bindings[function] else {
      return .error(EvalError("no binding for \(overload)"))
    }
    return binding.call(args, functionName: function, overload: overload, exprID: 1)
  }
}

func list(_ values: Value...) -> Value {
  .list(ArrayList(values))
}

func errorMessage(_ value: Value) -> String? {
  if case .error(let e) = value {
    return e.message
  }
  return nil
}
