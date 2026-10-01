// The CEL runner for the conformance suite, following cel-go conformance/conformance_test.go: parse with
// or without macros, extend the environment with the container and type_env declarations, check unless
// disabled, plan and evaluate with the bindings, and convert the result to a cel.expr.ExprValue.
//
// cel-go's environment: standard library, optional types, EnableErrorOnBadPresenceTest, the TestAllTypes
// messages, the bindings / encoders / lists / math / protos / strings / two-variable comprehension
// extensions, the conformance cel.block macros, and identifier escape syntax. Pieces not in the library
// yet (extensions) report `notImplemented` or fail.

import CEL
import CELExtensions
import CELProtobuf
import CELSpecProtos
import Foundation
import SwiftProtobuf

/// The runner every conformance test goes through.
let conformanceRunner: any ConformanceRunner = CELConformanceRunner()

struct CELConformanceRunner: ConformanceRunner {
  var name: String { "cel-swift" }

  /// cel-go's conformance environment, as far as the library has the pieces: the standard library,
  /// optional types, errors on bad presence tests, identifier escapes.
  static let baseEnvironment: ProgramEnvironment = {
    // cel-go `Types(&proto2pb.TestAllTypes{}, &proto3pb.TestAllTypes{})` plus the proto2 extensions.
    let protos = CELSpecProtos.protobufTypes
    var registry = TypeRegistry(composing: protos, adapter: protos)
    // cel-go `Types(types.OptionalType)`.
    try? registry.register(CELType.optionalOfDyn)
    var env = ProgramEnvironment(
      functions: StandardLibrary.functions + OptionalLibrary.functions(),
      variables: OptionalLibrary.types,
      provider: registry,
      macros: Macro.allMacros + OptionalLibrary.macros(),
      parserOptions: [.enableOptionalSyntax(true), .enableIdentEscapeSyntax(true)],
      errorOnBadPresenceTest: true)
    env.decorators = [OptionalLibrary.decorator]
    // cel-go clears the macros, installs the libraries, then adds the standard macros back.
    env.macros = OptionalLibrary.macros()
    for library in extensionLibraries {
      try? env.install(library)
    }
    env.macros += Macro.allMacros
    return env
  }()

  /// cel-go does not run network_ext (its conformance environment lacks the network library); these
  /// tests run with the base environment plus `ext.Network()`, as the oracle's `network` extension does.
  static let networkEnvironment: ProgramEnvironment = {
    var env = baseEnvironment
    try? env.install(.network)
    return env
  }()

  /// The extension libraries of cel-go's conformance environment, in its order.
  static let extensionLibraries: [Library] = [
    .bindings, .encoders, .lists, .math, .protos, .strings, .twoVarComprehensions,
    .celBlockConformance,
  ]

  /// The macros with `disable_macros`: the optional and library macros, without the standard ones.
  static let macrosWithoutStandard: [Macro] = {
    var env = baseEnvironment
    env.macros = OptionalLibrary.macros()
    for library in extensionLibraries {
      env.macros += library.macros
    }
    return env.macros
  }()

  func run(_ request: ConformanceRequest) -> ConformanceOutcome {
    let test = request.test
    var env = request.name.hasPrefix("network_ext/") ? Self.networkEnvironment : Self.baseEnvironment
    if test.disableMacros {
      // cel-go clears the macros before adding the libraries, so library macros stay.
      env.macros = Self.macrosWithoutStandard
    }
    var ast: AST
    do {
      ast = try env.parse(test.expr, description: test.name)
    } catch {
      return .parseError(error.message)
    }
    do {
      if !test.container.isEmpty {
        env.container = try Container(.name(test.container))
      }
      for decl in test.typeEnv {
        try TypeConversion.declare(decl, in: &env)
      }
    } catch {
      return .checkError("\(error)")
    }
    var deducedType: Cel_Expr_Type?
    if request.runsChecker {
      do {
        ast = try env.check(ast, source: TextSource(test.expr, description: test.name))
      } catch {
        return .checkError(error.message)
      }
      deducedType = TypeConversion.toProto(ast.type(of: ast.expr.id))
      if request.checkOnly, let deducedType {
        return .checked(deducedType: deducedType)
      }
    }
    var bindings: [String: Value] = [:]
    for (name, exprValue) in test.bindings {
      switch ValueConversion.toValue(exprValue, types: CELSpecProtos.protobufTypes) {
      case .success(let v): bindings[name] = v
      case .failure(let reason): return .notImplemented(reason.message)
      }
    }
    let program: PlannedProgram
    do {
      program = try env.program(ast)
    } catch {
      // cel-go fails the test when program creation fails; report it as an evaluation error.
      var set = Cel_Expr_ErrorSet()
      var status = Cel_Expr_Status()
      status.message = "\(error)"
      set.errors = [status]
      var result = Cel_Expr_ExprValue()
      result.error = set
      return .evaluated(result: result, deducedType: deducedType)
    }
    let result = program.eval(bindings)
    switch ValueConversion.toExprValue(result.value, types: CELSpecProtos.protobufTypes) {
    case .success(let ev): return .evaluated(result: ev, deducedType: deducedType)
    case .failure(let reason): return .notImplemented(reason.message)
    }
  }
}

struct ConversionFailure: Error {
  var message: String
}

/// `cel.expr.Value` <-> `Value` (cel-go `cel.ProtoAsValue` / `cel.ValueAsProto`), via CELSpecProtos.
enum ValueConversion {
  static func toValue(_ ev: Cel_Expr_ExprValue, types: ProtobufTypes) -> Result<Value, ConversionFailure> {
    switch ev.kind {
    case .value(let v)?:
      do {
        return .success(try v.celValue(types: types))
      } catch {
        return .failure(ConversionFailure(message: "\(error)"))
      }
    case .error?: return .success(.error(EvalError("XXX add details later")))
    case .unknown(let set)?:
      var unknown: UnknownSet?
      for id in set.exprs {
        unknown = UnknownSet.merge(UnknownSet(exprID: id), unknown)
      }
      return unknown.map { .success(.unknown($0)) } ?? .failure(ConversionFailure(message: "empty unknown set"))
    case nil:
      return .failure(ConversionFailure(message: "unknown ExprValue kind"))
    }
  }

  static func toExprValue(_ v: Value, types: ProtobufTypes) -> Result<Cel_Expr_ExprValue, ConversionFailure> {
    do {
      return .success(try Cel_Expr_ExprValue(celValue: v, types: types))
    } catch {
      return .failure(ConversionFailure(message: "cannot convert \(v.runtimeTypeName) to a cel.expr.Value: \(error)"))
    }
  }
}
