// cel.expr.Type / cel.expr.Decl <-> CELType / declarations, following cel-go common/types/types.go
// (TypeToProto, ProtoAsType) and cel/decls.go (ProtoAsDeclaration).

import CEL
import CELSpecProtos
import Foundation
import SwiftProtobuf

enum TypeConversion {
  static func toCELType(_ t: Cel_Expr_Type) -> Result<CELType, ConversionFailure> {
    switch t.typeKind {
    case .dyn?: return .success(.dyn)
    case .null?: return .success(.null)
    case .primitive(let p)?: return primitive(p)
    case .wrapper(let p)?: return primitive(p).map { .wrapper($0) }
    case .wellKnown(let w)?:
      switch w {
      case .any: return .success(.any)
      case .duration: return .success(.duration)
      case .timestamp: return .success(.timestamp)
      default: return .failure(ConversionFailure(message: "unsupported well-known type: \(w)"))
      }
    case .listType(let l)?:
      return toCELType(l.elemType).map { .list($0) }
    case .mapType(let m)?:
      guard case .success(let k) = toCELType(m.keyType), case .success(let v) = toCELType(m.valueType) else {
        return .failure(ConversionFailure(message: "invalid map type"))
      }
      return .success(.map(key: k, value: v))
    case .messageType(let name)?:
      return .success(.objectType(name))
    case .typeParam(let name)?:
      return .success(.typeParam(name))
    case .type(let inner)?:
      if inner.typeKind == nil {
        return .success(.type(nil))
      }
      return toCELType(inner).map { .type($0) }
    case .error?:
      return .success(.error)
    case .abstractType(let a)?:
      var params: [CELType] = []
      for p in a.parameterTypes {
        guard case .success(let pt) = toCELType(p) else {
          return .failure(ConversionFailure(message: "invalid abstract type parameter"))
        }
        params.append(pt)
      }
      return .success(.opaque(name: a.name, parameters: params))
    case .function?, nil:
      return .failure(ConversionFailure(message: "unsupported type: \(t)"))
    }
  }

  private static func primitive(_ p: Cel_Expr_Type.PrimitiveType) -> Result<CELType, ConversionFailure> {
    switch p {
    case .bool: return .success(.bool)
    case .bytes: return .success(.bytes)
    case .double: return .success(.double)
    case .int64: return .success(.int)
    case .string: return .success(.string)
    case .uint64: return .success(.uint)
    default: return .failure(ConversionFailure(message: "unsupported primitive type: \(p)"))
    }
  }

  static func toProto(_ t: CELType) -> Cel_Expr_Type {
    var out = Cel_Expr_Type()
    switch t {
    case .any: out.wellKnown = .any
    case .bool: out.primitive = .bool
    case .bytes: out.primitive = .bytes
    case .double: out.primitive = .double
    case .duration: out.wellKnown = .duration
    case .dyn: out.dyn = Google_Protobuf_Empty()
    case .error, .unknown: out.error = Google_Protobuf_Empty()
    case .int: out.primitive = .int64
    case .list(let e):
      var l = Cel_Expr_Type.ListType()
      l.elemType = toProto(e)
      out.listType = l
    case .map(let k, let v):
      var m = Cel_Expr_Type.MapType()
      m.keyType = toProto(k)
      m.valueType = toProto(v)
      out.mapType = m
    case .null: out.null = .nullValue
    case .opaque(let name, let params):
      var a = Cel_Expr_Type.AbstractType()
      a.name = name
      a.parameterTypes = params.map(toProto)
      out.abstractType = a
    case .string: out.primitive = .string
    case .object(let name): out.messageType = name
    case .timestamp: out.wellKnown = .timestamp
    case .typeParam(let name): out.typeParam = name
    case .type(let inner):
      out.type = inner.map(toProto) ?? Cel_Expr_Type()
    case .uint: out.primitive = .uint64
    case .wrapper(let inner):
      if case .primitive(let p)? = toProto(inner).typeKind {
        out.wrapper = p
      } else {
        out = toProto(inner)
      }
    }
    return out
  }

  static func constant(_ c: Cel_Expr_Constant) -> Result<Value, ConversionFailure> {
    switch c.constantKind {
    case .nullValue?: return .success(.null)
    case .boolValue(let b)?: return .success(.bool(b))
    case .int64Value(let i)?: return .success(.int(i))
    case .uint64Value(let u)?: return .success(.uint(u))
    case .doubleValue(let d)?: return .success(.double(d))
    case .stringValue(let s)?: return .success(.string(s))
    case .bytesValue(let b)?: return .success(.bytes([UInt8](b)))
    default: return .failure(ConversionFailure(message: "unsupported constant \(c)"))
    }
  }

  /// The environment option declaring a `type_env` declaration (cel-go `ProtoAsDeclaration`).
  static func option(for d: Cel_Expr_Decl) throws -> Environment.Option {
    switch d.declKind {
    case .ident(let ident)?:
      let t = try toCELType(ident.type).get()
      if ident.hasValue {
        return .constant(d.name, t, value: try constant(ident.value).get())
      }
      return .variable(d.name, t)
    case .function(let fn)?:
      var options: [FunctionDecl.Option] = []
      for o in fn.overloads {
        let args = try o.params.map { try toCELType($0).get() }
        let result = try toCELType(o.resultType).get()
        options.append(
          o.isInstanceFunction
            ? .memberOverload(o.overloadID, argTypes: args, resultType: result)
            : .overload(o.overloadID, argTypes: args, resultType: result))
      }
      return .functions([try FunctionDecl(d.name, options: options)])
    case nil:
      throw ConversionFailure(message: "unsupported decl: \(d)")
    }
  }
}
