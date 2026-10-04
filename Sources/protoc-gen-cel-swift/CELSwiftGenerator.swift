// protoc-gen-cel-swift: a protoc plugin that emits CEL message adapters for swift-protobuf types. Not a ported file.
//
// For every `foo/bar.proto` it writes `foo/bar.cel.swift` (or `foo_bar.cel.swift` with
// FileNaming=PathToUnderscores) holding one `ProtobufFile` constant, `<Prefix><Base>_CELFile`,
// that describes the file's messages (a field table built on key paths into the swift-protobuf
// properties), enums and extensions to `CELProtobuf`. Run it next to protoc-gen-swift with the
// same options:
//
//   protoc --swift_out=Sources/X --cel-swift_out=Sources/X \
//     --plugin=protoc-gen-cel-swift=<path> --cel-swift_opt=Visibility=Public foo/bar.proto
//
// Options: Visibility (Internal, Package, Public), FileNaming (FullPath, PathToUnderscores,
// DropPath), ProtoPathModuleMappings (as for protoc-gen-swift), and RuntimeModule=None when
// generating into the CELProtobuf module itself (the well-known types).
//
// The field semantics follow cel-go common/types/pb/type.go (FieldDescription) and
// common/types/provider.go (fieldDescToCELType); see Sources/CELProtobuf.

import Foundation
import SwiftProtobuf
import SwiftProtobufPluginLibrary

struct Options {
  var visibility = "internal"
  var fileNaming = "fullpath"
  var mappings = ProtoFileToModuleMappings()
  var importRuntime = true

  init(_ parameter: any CodeGeneratorParameter) throws {
    for (key, value) in parameter.parsedPairs {
      switch key {
      case "Visibility":
        let v = value.lowercased()
        guard ["internal", "package", "public"].contains(v) else {
          throw GenerationError("unknown Visibility: \(value)")
        }
        visibility = v
      case "FileNaming":
        let v = value.lowercased().replacingOccurrences(of: "_", with: "")
        guard ["fullpath", "pathtounderscores", "droppath"].contains(v) else {
          throw GenerationError("unknown FileNaming: \(value)")
        }
        fileNaming = v
      case "ProtoPathModuleMappings":
        if !value.isEmpty {
          mappings = try ProtoFileToModuleMappings(path: value)
        }
      case "RuntimeModule":
        importRuntime = value.lowercased() != "none"
      default:
        throw GenerationError("unknown option: \(key)")
      }
    }
  }
}

struct GenerationError: Error, CustomStringConvertible {
  var description: String
  init(_ description: String) { self.description = description }
}

func splitPath(_ path: String) -> (dir: String, base: String) {
  var dir = ""
  var file = path
  if let slash = path.lastIndex(of: "/") {
    dir = String(path[...slash])
    file = String(path[path.index(after: slash)...])
  }
  if file.hasSuffix(".proto") {
    file.removeLast(".proto".count)
  }
  return (dir, file)
}

/// The identifier of a file's `ProtobufFile` constant.
func fileSymbol(_ file: FileDescriptor, namer: SwiftProtobufNamer) -> String {
  namer.typePrefix(forFile: file) + NamingUtils.toUpperCamelCase(splitPath(file.name).base) + "_CELFile"
}

/// protoc's default JSON name, mirrored in CELProtobuf's `defaultJSONName`.
func defaultJSONName(_ name: String) -> String {
  var result = ""
  var upper = false
  for c in name {
    if c == "_" {
      upper = true
    } else if upper {
      result += c.uppercased()
      upper = false
    } else {
      result.append(c)
    }
  }
  return result
}

func swiftString(_ s: String) -> String {
  "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    + "\""
}

let wellKnownPaths: Set<String> = [
  "google/protobuf/any.proto", "google/protobuf/duration.proto", "google/protobuf/empty.proto",
  "google/protobuf/field_mask.proto", "google/protobuf/struct.proto",
  "google/protobuf/timestamp.proto", "google/protobuf/wrappers.proto",
]

struct FileGenerator {
  let file: FileDescriptor
  let options: Options
  let namer: SwiftProtobufNamer
  var lines: [String] = []

  init(file: FileDescriptor, options: Options) {
    self.file = file
    self.options = options
    namer = SwiftProtobufNamer(currentFile: file, protoFileToModuleMappings: options.mappings)
  }

  var visibility: String {
    options.visibility == "internal" ? "" : options.visibility + " "
  }

  var outputName: String {
    let (dir, base) = splitPath(file.name)
    switch options.fileNaming {
    case "pathtounderscores": return dir.replacingOccurrences(of: "/", with: "_") + base + ".cel.swift"
    case "droppath": return base + ".cel.swift"
    default: return dir + base + ".cel.swift"
    }
  }

  /// Messages in the file, nested ones included, map entries excluded.
  func allMessages(_ messages: [Descriptor]) -> [Descriptor] {
    var result: [Descriptor] = []
    for m in messages where !m.isMapEntry {
      result.append(m)
      result += allMessages(m.messages)
    }
    return result
  }

  func allEnums() -> [EnumDescriptor] {
    var result = file.enums
    for m in allMessages(file.messages) {
      result += m.enums
    }
    return result
  }

  func allExtensions() -> [FieldDescriptor] {
    var result = file.extensions
    for m in allMessages(file.messages) {
      result += m.extensions
    }
    return result
  }

  func kind(_ field: FieldDescriptor) -> String {
    switch field.type {
    case .double: return ".double"
    case .float: return ".float"
    case .int64, .sint64, .sfixed64: return ".int64"
    case .uint64, .fixed64: return ".uint64"
    case .int32, .sint32, .sfixed32: return ".int32"
    case .uint32, .fixed32: return ".uint32"
    case .bool: return ".bool"
    case .string: return ".string"
    case .bytes: return ".bytes"
    case .enum:
      // The enum's name gives strong enum values their type; NullValue stays an int.
      guard let enumType = field.enumType, enumType.fullName != "google.protobuf.NullValue" else {
        return ".enumeration"
      }
      return ".enumeration(\(swiftString(enumType.fullName)))"
    case .message, .group: return ".message"
    }
  }

  func header(_ name: String, _ number: Int32, jsonName: String?) -> String {
    var s = "\(swiftString(name)), number: \(number)"
    if let jsonName, jsonName != defaultJSONName(name) {
      s += ", jsonName: \(swiftString(jsonName))"
    }
    return s
  }

  /// The `ProtobufField` builder expression for a regular field of `message`.
  func fieldExpression(_ field: FieldDescriptor, in message: Descriptor) -> String {
    let swiftMessage = namer.fullName(message: message)
    let names = namer.messagePropertyNames(
      field: field, prefixed: "_", includeHasAndClear: field.hasPresence && field.realContainingOneof == nil)
    let head = header(field.name, field.number, jsonName: field.jsonName)
    let keyPath = "\\\(swiftMessage).\(names.name)"
    if field.isMap, let (key, value) = field.messageType.mapKeyAndValue {
      return ".map(\(head), \(keyPath), key: \(kind(key)), value: \(kind(value)))"
    }
    if field.isRepeated {
      return ".repeated(\(head), \(keyPath), \(kind(field)))"
    }
    var presence = ""
    if let oneof = field.realContainingOneof {
      let oneofName = namer.messagePropertyName(oneof: oneof).name
      presence =
        ", presence: .oneof({ if case .\(names.name)? = $0.\(oneofName) { return true }; return false })"
    } else if field.hasPresence {
      presence = ", presence: .explicit(\\\(swiftMessage).\(names.has))"
    }
    return ".singular(\(head), \(keyPath), \(kind(field))\(presence))"
  }

  func extensionExpression(_ field: FieldDescriptor) -> String {
    let extended = namer.fullName(message: field.containingType)
    let names = namer.messagePropertyNames(extensionField: field)
    let head = header(field.fullName, field.number, jsonName: nil)
    let keyPath = "\\\(extended).\(names.value)"
    if field.isRepeated {
      return "ProtobufExtension(ProtobufField<\(extended)>.repeated(\(head), \(keyPath), \(kind(field))))"
    }
    return "ProtobufExtension(ProtobufField<\(extended)>.singular(\(head), \(keyPath), \(kind(field)), "
      + "presence: .explicit(\\\(extended).\(names.has))))"
  }

  func functionName(_ message: Descriptor) -> String {
    "_celFields_" + namer.fullName(message: message).replacingOccurrences(of: ".", with: "_")
  }

  mutating func generate() {
    let messages = allMessages(file.messages)
    let extensions = allExtensions()
    lines.append("// DO NOT EDIT.")
    lines.append("// swift-format-ignore-file")
    lines.append("//")
    lines.append("// Generated by protoc-gen-cel-swift.")
    lines.append("// Source: \(file.name)")
    lines.append("")
    var imports: Set<String> = ["CEL", "SwiftProtobuf"]
    if options.importRuntime {
      imports.insert("CELProtobuf")
    }
    if let own = options.mappings.moduleName(forFile: file) {
      imports.insert(own)
    }
    for module in options.mappings.neededModules(forFile: file) ?? [] {
      imports.insert(module)
    }
    for module in imports.sorted() {
      lines.append("import \(module)")
    }
    lines.append("")

    lines.append("/// The CEL description of `\(file.name)`, for `ProtobufTypes`.")
    lines.append("\(visibility)let \(fileSymbol(file, namer: namer)) = ProtobufFile(")
    lines.append("  path: \(swiftString(file.name)),")
    lines.append("  messageTypes: [")
    for message in messages {
      let swiftName = namer.fullName(message: message)
      lines.append("    ProtobufMessageType(\(swiftName).self, fields: \(functionName(message))()),")
    }
    lines.append("  ],")
    lines.append("  enumTypes: [")
    for e in allEnums() {
      let values = e.values.map { "(\(swiftString($0.name)), \($0.number))" }.joined(separator: ", ")
      lines.append("    ProtobufEnumType(\(swiftString(e.fullName)), values: [\(values)]),")
    }
    lines.append("  ],")
    lines.append("  extensions: [")
    for ext in extensions {
      lines.append("    \(extensionExpression(ext)),")
    }
    lines.append("  ],")
    if !file.extensions.isEmpty || !extensions.isEmpty {
      let mapName =
        namer.typePrefix(forFile: file) + NamingUtils.toUpperCamelCase(splitPath(file.name).base)
        + "_Extensions"
      lines.append("  extensionMap: \(mapName),")
    }
    var dependencies: [String] = []
    for dependency in file.dependencies where !wellKnownPaths.contains(dependency.name) {
      if dependency.name.hasPrefix("google/protobuf/") {
        // Other google/protobuf files (descriptor.proto, ...) have no generated adapters.
        continue
      }
      let depNamer = SwiftProtobufNamer(currentFile: dependency, protoFileToModuleMappings: options.mappings)
      var symbol = fileSymbol(dependency, namer: depNamer)
      if let module = options.mappings.moduleName(forFile: dependency),
        module != options.mappings.moduleName(forFile: file)
      {
        symbol = module + "." + symbol
      }
      dependencies.append(symbol)
    }
    lines.append("  dependencies: [\(dependencies.joined(separator: ", "))]")
    lines.append(")")

    for message in messages {
      let swiftName = namer.fullName(message: message)
      let fields = message.fields
      lines.append("")
      lines.append("fileprivate func \(functionName(message))() -> [ProtobufField<\(swiftName)>] {")
      if fields.isEmpty {
        lines.append("  []")
      } else {
        lines.append("  var fields: [ProtobufField<\(swiftName)>] = []")
        lines.append("  fields.reserveCapacity(\(fields.count))")
        for field in fields {
          lines.append("  fields.append(\(fieldExpression(field, in: message)))")
        }
        lines.append("  return fields")
      }
      lines.append("}")
    }
    lines.append("")
  }
}

@main
struct CELSwiftGenerator: CodeGenerator {
  func generate(
    files: [FileDescriptor],
    parameter: any CodeGeneratorParameter,
    protoCompilerContext: any ProtoCompilerContext,
    generatorOutputs: any GeneratorOutputs
  ) throws {
    let options = try Options(parameter)
    for file in files {
      var generator = FileGenerator(file: file, options: options)
      generator.generate()
      try generatorOutputs.add(fileName: generator.outputName, contents: generator.lines.joined(separator: "\n"))
    }
  }

  var supportedFeatures: [Google_Protobuf_Compiler_CodeGeneratorResponse.Feature] {
    [.proto3Optional, .supportsEditions]
  }

  var supportedEditionRange: ClosedRange<Google_Protobuf_Edition> {
    Google_Protobuf_Edition.proto2...Google_Protobuf_Edition.edition2023
  }

  var version: String? { "0.1.1" }
  var projectURL: String? { "https://github.com/lustefaniak/cel-swift" }
}
