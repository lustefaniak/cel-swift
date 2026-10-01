// Copyright 2025 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Ported from cel-go common/env/io.go (ConfigFromYAML, Variable and TypeDesc UnmarshalYAML,
// ParseTypeDesc) and the `yaml:` struct tags of common/env/env.go.
//
// Not ported: ConfigToYAML. go-yaml's emitter layout (four-space indent, compact nested
// sequences) is what cel-go's round-trip tests compare against, and nothing in the policy
// pipeline writes configs.

extension EnvironmentConfig {
  /// Decodes a config from YAML (or JSON) text, as cel-go's `env.ConfigFromYAML`.
  ///
  /// Unknown keys are ignored. Type mismatches are collected and reported together, in
  /// go-yaml's format.
  ///
  /// - Parameter yaml: The config text.
  /// - Throws: ``YAMLError`` when the text is not valid YAML or does not match the config shape.
  public init(yaml: String) throws(YAMLError) {
    self.init()
    guard let doc = try YAMLNode.parseDocument(yaml) else {
      return
    }
    var decoder = YAMLDecoder()
    try decoder.decodeConfig(doc, into: &self)
    if let error = decoder.unmarshalError {
      throw error
    }
  }
}

extension EnvironmentConfig.TypeDescriptor {
  /// Parses a type specifier such as `int`, `list<string>`, `map<string, ~V>` or
  /// `.com.example.Message`.
  ///
  /// - Parameter text: The specifier.
  /// - Throws: ``EnvironmentConfigError`` describing the syntax error, in cel-go's wording.
  public init(parsing text: String) throws(EnvironmentConfigError) {
    var parser = TypeDescriptorParser(text: text)
    switch parser.parse() {
    case .success(let d):
      self = d
    case .failure(let message):
      throw EnvironmentConfigError(messages: [message.text])
    }
  }
}

struct TypeDescriptorParseFailure: Error {
  var text: String
}

/// Port of cel-go's `typeDescParser`; positions are byte offsets, as in Go.
struct TypeDescriptorParser {
  typealias TypeDescriptor = EnvironmentConfig.TypeDescriptor
  let text: String
  let bytes: [UInt8]
  var pos = 0

  init(text: String) {
    self.text = text
    self.bytes = Array(text.utf8)
  }

  mutating func parse() -> Result<TypeDescriptor, TypeDescriptorParseFailure> {
    let res: TypeDescriptor
    switch parseTypeElem() {
    case .success(let d):
      res = d
    case .failure(let e):
      return .failure(TypeDescriptorParseFailure(text: "failed to parse type \(goQuote(text)): \(e.text)"))
    }
    skipWhitespace()
    if pos < bytes.count {
      return .failure(
        TypeDescriptorParseFailure(
          text: "unexpected character \(Self.quoteByte(bytes[pos])) at position \(pos) in \(goQuote(text))"))
    }
    return .success(res)
  }

  private mutating func parseConcreteType() -> Result<TypeDescriptor, TypeDescriptorParseFailure> {
    let id: String
    switch parseNamespaceIdentifier() {
    case .success(let s): id = s
    case .failure(let e): return .failure(e)
    }
    if pos < bytes.count && bytes[pos] == UInt8(ascii: "<") {
      pos += 1
      var params: [TypeDescriptor] = []
      while true {
        skipWhitespace()
        switch parseTypeElem() {
        case .success(let p): params.append(p)
        case .failure(let e): return .failure(e)
        }
        skipWhitespace()
        if pos < bytes.count && bytes[pos] == UInt8(ascii: ",") {
          pos += 1
          continue
        }
        if pos < bytes.count && bytes[pos] == UInt8(ascii: ">") {
          pos += 1
          break
        }
        return .failure(TypeDescriptorParseFailure(text: "expected ',' or '>' at position \(pos)"))
      }
      return .success(TypeDescriptor(id, parameters: params))
    }
    return .success(TypeDescriptor(id))
  }

  private mutating func parseTypeElem() -> Result<TypeDescriptor, TypeDescriptorParseFailure> {
    skipWhitespace()
    if pos < bytes.count && bytes[pos] == UInt8(ascii: "~") {
      pos += 1
      switch parseTypeParamIdent() {
      case .success(let id): return .success(.typeParameter(id))
      case .failure(let e): return .failure(e)
      }
    }
    return parseConcreteType()
  }

  private mutating func parseNamespaceIdentifier() -> Result<String, TypeDescriptorParseFailure> {
    skipWhitespace()
    var id = ""
    while pos < bytes.count && bytes[pos] != UInt8(ascii: "<") {
      if bytes[pos] == UInt8(ascii: ".") {
        id += "."
        pos += 1
      }
      switch parseIdentifier() {
      case .success(let ident): id += ident
      case .failure(let e): return .failure(e)
      }
      skipWhitespace()
      if pos < bytes.count && bytes[pos] != UInt8(ascii: ".") {
        break
      }
    }
    if id.isEmpty {
      return .failure(TypeDescriptorParseFailure(text: "missing identifier at position \(pos)"))
    }
    return .success(id)
  }

  private mutating func parseIdentifier() -> Result<String, TypeDescriptorParseFailure> {
    skipWhitespace()
    if pos >= bytes.count {
      return .failure(TypeDescriptorParseFailure(text: "unexpected end of input"))
    }
    let start = pos
    let c = bytes[pos]
    if !Self.isAlpha(c) && c != UInt8(ascii: "_") {
      return .failure(
        TypeDescriptorParseFailure(
          text: "identifier is expected, but \(Self.quoteByte(c)) was found at position \(pos)"))
    }
    pos += 1
    while pos < bytes.count {
      let c = bytes[pos]
      if !Self.isAlphaNumeric(c) && c != UInt8(ascii: "_") {
        break
      }
      pos += 1
    }
    return .success(String(decoding: bytes[start..<pos], as: UTF8.self))
  }

  private mutating func parseTypeParamIdent() -> Result<String, TypeDescriptorParseFailure> {
    skipWhitespace()
    if pos >= bytes.count {
      return .failure(TypeDescriptorParseFailure(text: "unexpected end of input"))
    }
    let c = bytes[pos]
    if !Self.isAlpha(c) {
      return .failure(
        TypeDescriptorParseFailure(
          text:
            "invalid type parameter identifier \(Self.quoteByte(c)) at position \(pos), must be a single character from A-Z"
        ))
    }
    pos += 1
    if pos < bytes.count && Self.isAlpha(bytes[pos]) {
      return .failure(
        TypeDescriptorParseFailure(
          text: "invalid type param, must have a single alphabetic character at position \(pos)"))
    }
    return .success(String(UnicodeScalar(c)))
  }

  private mutating func skipWhitespace() {
    while pos < bytes.count && Self.isWhitespace(bytes[pos]) {
      pos += 1
    }
  }

  private static func isWhitespace(_ c: UInt8) -> Bool {
    c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") || c == UInt8(ascii: "\n") || c == UInt8(ascii: "\r")
  }

  private static func isAlpha(_ c: UInt8) -> Bool {
    (c >= UInt8(ascii: "a") && c <= UInt8(ascii: "z")) || (c >= UInt8(ascii: "A") && c <= UInt8(ascii: "Z"))
  }

  private static func isAlphaNumeric(_ c: UInt8) -> Bool {
    isAlpha(c) || (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
  }

  /// Go's `%q` for a byte value: a quoted rune literal.
  private static func quoteByte(_ c: UInt8) -> String {
    switch c {
    case UInt8(ascii: "'"): return "'\\''"
    case UInt8(ascii: "\\"): return "'\\\\'"
    case UInt8(ascii: "\n"): return "'\\n'"
    case UInt8(ascii: "\t"): return "'\\t'"
    case UInt8(ascii: "\r"): return "'\\r'"
    default:
      if c < 0x20 || c == 0x7f {
        let hex = String(c, radix: 16)
        return "'\\x" + (hex.count < 2 ? "0" + hex : hex) + "'"
      }
      if c >= 0x80 {
        return "'" + String(UnicodeScalar(c)) + "'"
      }
      return "'" + String(UnicodeScalar(c)) + "'"
    }
  }
}

// MARK: - Decoding

extension YAMLDecoder {
  mutating func decodeConfig(_ node: YAMLNode, into c: inout EnvironmentConfig) throws(YAMLError) {
    let fields: Set<String> = [
      "name", "description", "container", "imports", "stdlib", "extensions", "context_variable", "variables",
      "functions", "validators", "features", "limits",
    ]
    try decodeObject(node, typeName: "env.Config", fields: fields) { (d, key, value) throws(YAMLError) in
      switch key {
      case "name": c.name = try d.decodeString(value) ?? ""
      case "description": c.description = try d.decodeString(value) ?? ""
      case "container": c.container = try d.decodeString(value) ?? ""
      case "imports":
        c.imports =
          try d.decodeList(value, typeName: "[]*env.Import") { (d, n) throws(YAMLError) in
            try d.decodeImport(n)
          } ?? []
      case "stdlib": c.standardLibrary = try d.decodeLibrarySubset(value)
      case "extensions":
        c.extensions =
          try d.decodeList(value, typeName: "[]*env.Extension") { (d, n) throws(YAMLError) in
            try d.decodeExtension(n)
          } ?? []
      case "context_variable":
        if YAMLDecoder.isNull(value) {
          c.contextVariable = nil
        } else {
          var ctx = EnvironmentConfig.ContextVariable(typeName: "")
          try d.decodeObject(value, typeName: "env.ContextVariable", fields: ["type_name"]) { (d, _, v) throws(YAMLError) in
            ctx.typeName = try d.decodeString(v) ?? ""
          }
          c.contextVariable = ctx
        }
      case "variables":
        c.variables =
          try d.decodeList(value, typeName: "[]*env.Variable") { (d, n) throws(YAMLError) in
            try d.decodeVariable(n)
          } ?? []
      case "functions":
        c.functions = try d.decodeFunctions(value)
      case "validators":
        c.validators =
          try d.decodeList(value, typeName: "[]*env.Validator") { (d, n) throws(YAMLError) in
            try d.decodeValidator(n)
          } ?? []
      case "features":
        c.features =
          try d.decodeList(value, typeName: "[]*env.Feature") { (d, n) throws(YAMLError) in
            try d.decodeFeature(n)
          } ?? []
      case "limits":
        c.limits =
          try d.decodeList(value, typeName: "[]*env.Limit") { (d, n) throws(YAMLError) in
            try d.decodeLimit(n)
          } ?? []
      default:
        break
      }
    }
  }

  private mutating func decodeImport(_ node: YAMLNode) throws(YAMLError) -> EnvironmentConfig.Import {
    var imp = EnvironmentConfig.Import(name: "")
    try decodeObject(node, typeName: "env.Import", fields: ["name"]) { (d, _, v) throws(YAMLError) in
      imp.name = try d.decodeString(v) ?? ""
    }
    return imp
  }

  private mutating func decodeExtension(_ node: YAMLNode) throws(YAMLError) -> EnvironmentConfig.Extension {
    var ext = EnvironmentConfig.Extension(name: "")
    try decodeObject(node, typeName: "env.Extension", fields: ["name", "version"]) { (d, key, v) throws(YAMLError) in
      switch key {
      case "name": ext.name = try d.decodeString(v) ?? ""
      default: ext.version = try d.decodeString(v) ?? ""
      }
    }
    return ext
  }

  private mutating func decodeFunctions(_ node: YAMLNode) throws(YAMLError) -> [EnvironmentConfig.Function] {
    try decodeList(node, typeName: "[]*env.Function") { (d, n) throws(YAMLError) in
      try d.decodeFunction(n)
    } ?? []
  }

  private mutating func decodeFunction(_ node: YAMLNode) throws(YAMLError) -> EnvironmentConfig.Function {
    var fn = EnvironmentConfig.Function(name: "")
    try decodeObject(node, typeName: "env.Function", fields: ["name", "description", "overloads"]) {
      (d, key, v) throws(YAMLError) in
      switch key {
      case "name": fn.name = try d.decodeString(v) ?? ""
      case "description": fn.description = try d.decodeString(v) ?? ""
      default:
        fn.overloads =
          try d.decodeList(v, typeName: "[]*env.Overload") { (d, n) throws(YAMLError) in
            try d.decodeOverload(n)
          } ?? []
      }
    }
    return fn
  }

  private mutating func decodeOverload(_ node: YAMLNode) throws(YAMLError) -> EnvironmentConfig.Overload {
    var o = EnvironmentConfig.Overload(id: "", resultType: nil)
    try decodeObject(node, typeName: "env.Overload", fields: ["id", "examples", "target", "args", "return"]) {
      (d, key, v) throws(YAMLError) in
      switch key {
      case "id": o.id = try d.decodeString(v) ?? ""
      case "examples":
        o.examples =
          try d.decodeList(v, typeName: "[]string") { (d, n) throws(YAMLError) in
            try d.decodeString(n)
          } ?? []
      case "target": o.target = try d.decodeTypeDescriptor(v)
      case "args":
        o.arguments =
          try d.decodeList(v, typeName: "[]*env.TypeDesc") { (d, n) throws(YAMLError) in
            try d.decodeTypeDescriptor(n)
          } ?? []
      default: o.resultType = try d.decodeTypeDescriptor(v)
      }
    }
    return o
  }

  private mutating func decodeLibrarySubset(_ node: YAMLNode) throws(YAMLError) -> EnvironmentConfig.LibrarySubset? {
    if YAMLDecoder.isNull(node) {
      return nil
    }
    var lib = EnvironmentConfig.LibrarySubset()
    let fields: Set<String> = [
      "disabled", "disable_macros", "include_macros", "exclude_macros", "include_functions", "exclude_functions",
    ]
    try decodeObject(node, typeName: "env.LibrarySubset", fields: fields) { (d, key, v) throws(YAMLError) in
      switch key {
      case "disabled": lib.isDisabled = try d.decodeBool(v) ?? false
      case "disable_macros": lib.disablesMacros = try d.decodeBool(v) ?? false
      case "include_macros":
        lib.includedMacros =
          try d.decodeList(v, typeName: "[]string") { (d, n) throws(YAMLError) in try d.decodeString(n) } ?? []
      case "exclude_macros":
        lib.excludedMacros =
          try d.decodeList(v, typeName: "[]string") { (d, n) throws(YAMLError) in try d.decodeString(n) } ?? []
      case "include_functions": lib.includedFunctions = try d.decodeFunctions(v)
      default: lib.excludedFunctions = try d.decodeFunctions(v)
      }
    }
    return lib
  }

  private mutating func decodeValidator(_ node: YAMLNode) throws(YAMLError) -> EnvironmentConfig.Validator {
    var val = EnvironmentConfig.Validator(name: "")
    try decodeObject(node, typeName: "env.Validator", fields: ["name", "config"]) { (d, key, v) throws(YAMLError) in
      switch key {
      case "name": val.name = try d.decodeString(v) ?? ""
      default:
        val.config =
          try d.decodeStringMap(v, typeName: "map[string]interface {}") { (d, n) throws(YAMLError) in
            try d.decodeValue(n) ?? .null
          } ?? [:]
      }
    }
    return val
  }

  private mutating func decodeFeature(_ node: YAMLNode) throws(YAMLError) -> EnvironmentConfig.Feature {
    var feat = EnvironmentConfig.Feature(name: "", isEnabled: false)
    try decodeObject(node, typeName: "env.Feature", fields: ["name", "enabled"]) { (d, key, v) throws(YAMLError) in
      switch key {
      case "name": feat.name = try d.decodeString(v) ?? ""
      default: feat.isEnabled = try d.decodeBool(v) ?? false
      }
    }
    return feat
  }

  private mutating func decodeLimit(_ node: YAMLNode) throws(YAMLError) -> EnvironmentConfig.Limit {
    var limit = EnvironmentConfig.Limit(name: "", value: 0)
    try decodeObject(node, typeName: "env.Limit", fields: ["name", "value"]) { (d, key, v) throws(YAMLError) in
      switch key {
      case "name": limit.name = try d.decodeString(v) ?? ""
      default: limit.value = Int(try d.decodeInt64(v, typeName: "int") ?? 0)
      }
    }
    return limit
  }

  /// `Variable.UnmarshalYAML`: decodes the inline `type_name` / `params` / `is_type_param` fields
  /// and the `type` field; the inline type wins when `type_name` is set.
  private mutating func decodeVariable(_ node: YAMLNode) throws(YAMLError) -> EnvironmentConfig.Variable {
    var v = EnvironmentConfig.Variable(name: "", type: nil)
    var typeName = ""
    var params: [EnvironmentConfig.TypeDescriptor] = []
    var isTypeParam = false
    var fieldType: EnvironmentConfig.TypeDescriptor?
    let fields: Set<String> = ["name", "description", "type", "type_name", "params", "is_type_param"]
    try decodeObject(node, typeName: "env.internalVariable", fields: fields) { (d, key, n) throws(YAMLError) in
      switch key {
      case "name": v.name = try d.decodeString(n) ?? ""
      case "description": v.description = try d.decodeString(n) ?? ""
      case "type": fieldType = try d.decodeTypeDescriptor(n)
      case "type_name": typeName = try d.decodeString(n) ?? ""
      case "params":
        params =
          try d.decodeList(n, typeName: "[]*env.TypeDesc") { (d, n) throws(YAMLError) in
            try d.decodeTypeDescriptor(n)
          } ?? []
      default: isTypeParam = try d.decodeBool(n) ?? false
      }
    }
    if !typeName.isEmpty {
      var t = EnvironmentConfig.TypeDescriptor(typeName, parameters: params)
      t.isTypeParameter = isTypeParam
      v.type = t
    } else if let fieldType {
      v.type = fieldType
    }
    return v
  }

  /// `TypeDesc.UnmarshalYAML`: a scalar is a type specifier, a mapping is a structured type.
  mutating func decodeTypeDescriptor(_ node: YAMLNode) throws(YAMLError) -> EnvironmentConfig.TypeDescriptor? {
    if YAMLDecoder.isNull(node) {
      return nil
    }
    guard let n = YAMLDecoder.content(of: node) else { return nil }
    if n.kind == .scalar {
      var parser = TypeDescriptorParser(text: n.value)
      switch parser.parse() {
      case .success(let d): return d
      case .failure(let e): throw YAMLError(message: e.text)
      }
    }
    if n.kind != .mapping {
      throw YAMLError(message: "unsupported yaml for TypeDesc")
    }
    var t = EnvironmentConfig.TypeDescriptor("")
    try decodeObject(n, typeName: "env.internalTypeDesc", fields: ["type_name", "params", "is_type_param"]) {
      (d, key, v) throws(YAMLError) in
      switch key {
      case "type_name": t.typeName = try d.decodeString(v) ?? ""
      case "params":
        t.parameters =
          try d.decodeList(v, typeName: "[]*env.TypeDesc") { (d, n) throws(YAMLError) in
            try d.decodeTypeDescriptor(n)
          } ?? []
      default: t.isTypeParameter = try d.decodeBool(v) ?? false
      }
    }
    return t
  }
}
