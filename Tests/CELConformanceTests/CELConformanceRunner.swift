// The CEL runner for the conformance suite, following cel-go conformance/conformance_test.go: parse with
// or without macros, extend the environment with the container and type_env declarations, check unless
// disabled, plan and evaluate with the bindings, and convert the result to a cel.expr.ExprValue.
//
// Everything goes through the public `Environment` / `Program` API, so the suite exercises the product
// surface. cel-go's environment: standard library, optional types, EnableErrorOnBadPresenceTest, the
// TestAllTypes messages, the bindings / encoders / lists / math / protos / strings / two-variable
// comprehension extensions, the conformance cel.block macros, and identifier escape syntax.

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

  /// The extension libraries of cel-go's conformance environment, in its order.
  static let extensionLibraries: [Library] = [
    .bindings, .encoders, .lists, .math, .protos, .strings, .twoVarComprehensions,
    .celBlockConformance,
  ]

  /// cel-go's conformance environment options before the standard macros are added back: it clears the
  /// macros, installs optional types and the libraries, then re-adds the standard macros.
  static let baseOptions: [Environment.Option] = {
    // cel-go `Types(&proto2pb.TestAllTypes{}, &proto3pb.TestAllTypes{})` plus the proto2 extensions.
    let protos = CELSpecProtos.protobufTypes
    return [
      .typeProvider(TypeRegistry(composing: protos, adapter: protos)),
      .clearMacros,
      .optionalTypes,
      .errorOnBadPresenceTest(),
      .identifierEscapeSyntax(),
      .libraries(extensionLibraries),
    ]
  }()

  static let baseEnvironment = makeEnvironment(baseOptions + [.macros(Macro.allMacros)])

  /// With `disable_macros`: the optional and library macros stay, the standard ones are not added back.
  static let environmentWithoutStandardMacros = makeEnvironment(baseOptions)

  /// cel-go does not run network_ext (its conformance environment lacks the network library); these
  /// tests run with the base environment plus `ext.Network()`, as the oracle's `network` extension does.
  /// The library's literal validators are left out: like cel-go's, they reject invalid `ip("...")` /
  /// `cidr("...")` literals at check time, while the spec tests expect the runtime error.
  static let networkEnvironment = makeEnvironment(
    baseOptions + [.macros(Macro.allMacros), .library(networkWithoutValidators)])

  static var networkWithoutValidators: Library {
    var library = Library.network
    library.validators = []
    return library
  }

  static func makeEnvironment(_ options: [Environment.Option]) -> Result<Environment, DeclarationError> {
    Result { () throws(DeclarationError) in try Environment(options: options) }
  }

  func run(_ request: ConformanceRequest) -> ConformanceOutcome {
    let test = request.test
    let base =
      request.name.hasPrefix("network_ext/")
      ? Self.networkEnvironment
      : test.disableMacros ? Self.environmentWithoutStandardMacros : Self.baseEnvironment
    let env: Environment
    switch base {
    case .success(let e): env = e
    case .failure(let error): return .notImplemented("conformance environment: \(error)")
    }
    let parsed: ParsedExpression
    do {
      parsed = try env.parse(test.expr, sourceName: test.name)
    } catch {
      return .parseError(error.description)
    }
    let testEnv: Environment
    do {
      var options: [Environment.Option] = []
      if !test.container.isEmpty {
        options.append(.container(test.container))
      }
      for decl in test.typeEnv {
        options.append(try TypeConversion.option(for: decl))
      }
      testEnv = options.isEmpty ? env : try env.extending(options: options)
    } catch {
      return .checkError("\(error)")
    }
    var checked: CheckedExpression?
    var deducedType: Cel_Expr_Type?
    if request.runsChecker {
      do {
        checked = try testEnv.check(parsed)
      } catch {
        return .checkError(error.description)
      }
      deducedType = checked.map { TypeConversion.toProto($0.outputType) }
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
    let program: Program
    do {
      if let checked {
        program = try testEnv.program(checked, options: [.errorsAsValues])
      } else {
        program = try testEnv.program(parsed, options: [.errorsAsValues])
      }
    } catch {
      // cel-go fails the test when program creation fails; report it as an evaluation error.
      var set = Cel_Expr_ErrorSet()
      var status = Cel_Expr_Status()
      status.message = error.description
      set.errors = [status]
      var result = Cel_Expr_ExprValue()
      result.error = set
      return .evaluated(result: result, deducedType: deducedType)
    }
    let value: Value
    do {
      value = try program.evaluate(bindings).value
    } catch {
      value = .error(error)
    }
    switch ValueConversion.toExprValue(value, types: CELSpecProtos.protobufTypes) {
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
