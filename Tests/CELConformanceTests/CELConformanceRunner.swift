// The CEL runner for the conformance suite, following cel-go conformance/conformance_test.go: parse with
// or without macros, extend the environment with the container and type_env declarations, check unless
// disabled, plan and evaluate with the bindings, and convert the result to a cel.expr.ExprValue.
//
// cel-go's environment: standard library, optional types, EnableErrorOnBadPresenceTest, the TestAllTypes
// messages, the bindings / encoders / lists / math / protos / strings / two-variable comprehension
// extensions, the conformance cel.block macros, and identifier escape syntax. Pieces not in the library
// yet (checker, protobuf messages, extensions) report `notImplemented` or fail; see `Hooks`.

import CEL
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
    var registry = TypeRegistry()
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
    return env
  }()

  func run(_ request: ConformanceRequest) -> ConformanceOutcome {
    let test = request.test
    var env = Self.baseEnvironment
    if test.disableMacros {
      // cel-go clears the macros before adding the libraries, so library macros stay.
      env.macros = OptionalLibrary.macros()
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
      switch ValueConversion.toValue(exprValue) {
      case .success(let v): bindings[name] = v
      case .failure(let reason): return .notImplemented(reason.message)
      }
    }
    let program: Program
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
    switch ValueConversion.toExprValue(result.value) {
    case .success(let ev): return .evaluated(result: ev, deducedType: deducedType)
    case .failure(let reason): return .notImplemented(reason.message)
    }
  }
}

struct ConversionFailure: Error {
  var message: String
}

/// `cel.expr.Value` <-> `Value` (cel-go `cel.ProtoAsValue` / `cel.ValueAsProto`).
enum ValueConversion {
  static func toValue(_ ev: Cel_Expr_ExprValue) -> Result<Value, ConversionFailure> {
    switch ev.kind {
    case .value(let v)?: return toValue(v)
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

  static func toValue(_ v: Cel_Expr_Value) -> Result<Value, ConversionFailure> {
    switch v.kind {
    case .nullValue?: return .success(.null)
    case .boolValue(let b)?: return .success(.bool(b))
    case .int64Value(let i)?: return .success(.int(i))
    case .uint64Value(let u)?: return .success(.uint(u))
    case .doubleValue(let d)?: return .success(.double(d))
    case .stringValue(let s)?: return .success(.string(s))
    case .bytesValue(let b)?: return .success(.bytes([UInt8](b)))
    case .enumValue(let e)?: return .success(.int(Int64(e.value)))
    case .typeValue(let name)?:
      if let t = TypeRegistry().findIdent(name) {
        return .success(t)
      }
      return .success(.type(.objectType(name)))
    case .listValue(let l)?:
      var out: [Value] = []
      for e in l.values {
        switch toValue(e) {
        case .success(let x): out.append(x)
        case .failure(let f): return .failure(f)
        }
      }
      return .success(.list(ArrayList(out)))
    case .mapValue(let m)?:
      var map = OrderedMap()
      for entry in m.entries {
        guard case .success(let k) = toValue(entry.key), let key = MapKey(k) else {
          return .failure(ConversionFailure(message: "unsupported map key \(entry.key)"))
        }
        switch toValue(entry.value) {
        case .success(let x): map[key] = x
        case .failure(let f): return .failure(f)
        }
      }
      return .success(.map(map))
    case .objectValue(let any)?:
      return anyToValue(any)
    case nil:
      return .failure(ConversionFailure(message: "empty value"))
    }
  }

  /// Well-known types inside `Any`; message objects need the protobuf support (not wired yet).
  static func anyToValue(_ any: Google_Protobuf_Any) -> Result<Value, ConversionFailure> {
    do {
      if any.isA(Google_Protobuf_Duration.self) {
        let d = try Google_Protobuf_Duration(unpackingAny: any)
        guard let dur = CELDuration(seconds: d.seconds, nanoseconds: Int64(d.nanos)) else {
          return .success(.error(EvalError("duration out of range")))
        }
        return .success(.duration(dur))
      }
      if any.isA(Google_Protobuf_Timestamp.self) {
        let t = try Google_Protobuf_Timestamp(unpackingAny: any)
        return .success(.timestamp(CELTimestamp(secondsSinceEpoch: t.seconds, nanoseconds: Int64(t.nanos))))
      }
      if any.isA(Google_Protobuf_Int64Value.self) { return .success(.int(try Google_Protobuf_Int64Value(unpackingAny: any).value)) }
      if any.isA(Google_Protobuf_Int32Value.self) { return .success(.int(Int64(try Google_Protobuf_Int32Value(unpackingAny: any).value))) }
      if any.isA(Google_Protobuf_UInt64Value.self) { return .success(.uint(try Google_Protobuf_UInt64Value(unpackingAny: any).value)) }
      if any.isA(Google_Protobuf_UInt32Value.self) { return .success(.uint(UInt64(try Google_Protobuf_UInt32Value(unpackingAny: any).value))) }
      if any.isA(Google_Protobuf_DoubleValue.self) { return .success(.double(try Google_Protobuf_DoubleValue(unpackingAny: any).value)) }
      if any.isA(Google_Protobuf_FloatValue.self) { return .success(.double(Double(try Google_Protobuf_FloatValue(unpackingAny: any).value))) }
      if any.isA(Google_Protobuf_BoolValue.self) { return .success(.bool(try Google_Protobuf_BoolValue(unpackingAny: any).value)) }
      if any.isA(Google_Protobuf_StringValue.self) { return .success(.string(try Google_Protobuf_StringValue(unpackingAny: any).value)) }
      if any.isA(Google_Protobuf_BytesValue.self) { return .success(.bytes([UInt8](try Google_Protobuf_BytesValue(unpackingAny: any).value))) }
      if any.isA(Google_Protobuf_Value.self) { return .success(jsonToValue(try Google_Protobuf_Value(unpackingAny: any))) }
      if any.isA(Google_Protobuf_Struct.self) { return .success(structToValue(try Google_Protobuf_Struct(unpackingAny: any))) }
      if any.isA(Google_Protobuf_ListValue.self) {
        return .success(.list(ArrayList(try Google_Protobuf_ListValue(unpackingAny: any).values.map(jsonToValue))))
      }
    } catch {
      return .failure(ConversionFailure(message: "cannot unpack \(any.typeURL): \(error)"))
    }
    return .failure(ConversionFailure(message: "message values are not supported yet: \(any.typeURL)"))
  }

  static func jsonToValue(_ v: Google_Protobuf_Value) -> Value {
    switch v.kind {
    case .nullValue?, nil: return .null
    case .numberValue(let d)?: return .double(d)
    case .stringValue(let s)?: return .string(s)
    case .boolValue(let b)?: return .bool(b)
    case .structValue(let s)?: return structToValue(s)
    case .listValue(let l)?: return .list(ArrayList(l.values.map(jsonToValue)))
    }
  }

  static func structToValue(_ s: Google_Protobuf_Struct) -> Value {
    var map = OrderedMap()
    for key in s.fields.keys.sorted() {
      map[.string(key)] = s.fields[key].map(jsonToValue) ?? .null
    }
    return .map(map)
  }

  static func toExprValue(_ v: Value) -> Result<Cel_Expr_ExprValue, ConversionFailure> {
    var out = Cel_Expr_ExprValue()
    switch v {
    case .error(let err):
      var set = Cel_Expr_ErrorSet()
      var status = Cel_Expr_Status()
      status.message = err.message
      set.errors = [status]
      out.error = set
    case .unknown(let u):
      var set = Cel_Expr_UnknownSet()
      set.exprs = u.exprIDs
      out.unknown = set
    default:
      switch toProto(v) {
      case .success(let p): out.value = p
      case .failure(let f): return .failure(f)
      }
    }
    return .success(out)
  }

  static func toProto(_ v: Value) -> Result<Cel_Expr_Value, ConversionFailure> {
    var out = Cel_Expr_Value()
    switch v {
    case .null: out.nullValue = .nullValue
    case .bool(let b): out.boolValue = b
    case .int(let i): out.int64Value = i
    case .uint(let u): out.uint64Value = u
    case .double(let d): out.doubleValue = d
    case .string(let s): out.stringValue = s
    case .bytes(let b): out.bytesValue = Data(b)
    case .type(let t): out.typeValue = t.runtimeTypeName
    case .list(let l):
      var list = Cel_Expr_ListValue()
      for i in 0..<l.count {
        switch toProto(l.element(at: i)) {
        case .success(let p): list.values.append(p)
        case .failure(let f): return .failure(f)
        }
      }
      out.listValue = list
    case .map(let m):
      var map = Cel_Expr_MapValue()
      for key in m.keys {
        var entry = Cel_Expr_MapValue.Entry()
        guard case .success(let k) = toProto(key.value),
          case .success(let val) = toProto(m.value(forKey: key) ?? .null)
        else {
          return .failure(ConversionFailure(message: "cannot convert map entry"))
        }
        entry.key = k
        entry.value = val
        map.entries.append(entry)
      }
      out.mapValue = map
    case .duration(let d):
      var p = Google_Protobuf_Duration()
      p.seconds = d.nanoseconds / 1_000_000_000
      p.nanos = Int32(d.nanoseconds % 1_000_000_000)
      guard let any = try? Google_Protobuf_Any(message: p) else {
        return .failure(ConversionFailure(message: "cannot pack duration"))
      }
      out.objectValue = any
    case .timestamp(let t):
      var p = Google_Protobuf_Timestamp()
      p.seconds = t.secondsSinceEpoch
      p.nanos = t.nanoseconds
      guard let any = try? Google_Protobuf_Any(message: p) else {
        return .failure(ConversionFailure(message: "cannot pack timestamp"))
      }
      out.objectValue = any
    case .optional, .object, .error, .unknown:
      return .failure(ConversionFailure(message: "cannot convert \(v.runtimeTypeName) to a cel.expr.Value yet"))
    }
    return .success(out)
  }
}
