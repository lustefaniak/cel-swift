//
// Copyright (c) 2011-2019 Canonical Ltd
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Ported from go.yaml.in/yaml/v3 decode.go (the `parser` type that builds `yaml.Node` trees).
//
// go-yaml is itself a port of libyaml, so driving libyaml's event parser (the C library bundled with
// Yams) and composing nodes the way go-yaml does gives the same marks, tags and styles cel-go sees.
// Yams' own composer is not used: it rejects duplicate mapping keys, which go-yaml accepts when
// decoding into a node, and it hides the scalar style and implicit-tag details the policy parser
// depends on.

import CYaml

/// A YAML syntax or decoding error, with go-yaml's message text, for example
/// `yaml: line 3: mapping values are not allowed in this context` or
/// `yaml: unmarshal errors:\n  line 2: cannot unmarshal !!map into string`.
public struct YAMLError: Error, Sendable, Hashable, CustomStringConvertible {
  /// The error message.
  public var message: String

  /// Creates an error with a message.
  ///
  /// - Parameter message: The error message.
  public init(message: String) {
    self.message = message
  }

  /// A textual representation of the error: its ``message``.
  public var description: String { message }
}

extension YAMLNode {
  /// Parses the first document in `text` into a node tree.
  ///
  /// The returned node is the document node; its single child is the document content. Text with
  /// no document returns `nil`, matching go-yaml decoding an empty input into a zero `yaml.Node`.
  ///
  /// - Parameter text: The YAML source.
  /// - Returns: The document node, or `nil` when the stream holds no document.
  /// - Throws: ``YAMLError`` when the text is not well-formed YAML.
  public static func parseDocument(_ text: String) throws(YAMLError) -> YAMLNode? {
    var bytes = Array(text.utf8)
    if bytes.isEmpty {
      bytes = [UInt8(ascii: "\n")]
    }
    let result: Result<YAMLNode?, YAMLError> = bytes.withUnsafeBufferPointer { buffer in
      YAMLComposer(buffer).parseResult()
    }
    return try result.get()
  }
}

private final class YAMLComposer {
  private var parser = yaml_parser_t()
  private var event = yaml_event_t()
  private var hasEvent = false
  private var doneInit = false
  private var anchors: [String: YAMLNode] = [:]

  init(_ buffer: UnsafeBufferPointer<UInt8>) {
    yaml_parser_initialize(&parser)
    yaml_parser_set_input_string(&parser, buffer.baseAddress, buffer.count)
  }

  deinit {
    if hasEvent {
      yaml_event_delete(&event)
    }
    yaml_parser_delete(&parser)
  }

  func parseResult() -> Result<YAMLNode?, YAMLError> {
    do {
      return .success(try parse())
    } catch {
      return .failure(error)
    }
  }

  func parse() throws(YAMLError) -> YAMLNode? {
    try initialize()
    switch try peek() {
    case YAML_SCALAR_EVENT:
      return try scalar()
    case YAML_ALIAS_EVENT:
      return try alias()
    case YAML_MAPPING_START_EVENT:
      return try mapping()
    case YAML_SEQUENCE_START_EVENT:
      return try sequence()
    case YAML_DOCUMENT_START_EVENT:
      return try document()
    case YAML_STREAM_END_EVENT:
      // Happens when attempting to decode an empty buffer.
      return nil
    default:
      throw YAMLError(message: "yaml: internal error: attempted to parse unknown event")
    }
  }

  private func initialize() throws(YAMLError) {
    if doneInit {
      return
    }
    try expect(YAML_STREAM_START_EVENT)
    doneInit = true
  }

  private func peek() throws(YAMLError) -> yaml_event_type_t {
    if hasEvent {
      return event.type
    }
    if yaml_parser_parse(&parser, &event) == 0 || parser.error != YAML_NO_ERROR {
      throw failure()
    }
    hasEvent = true
    return event.type
  }

  private func expect(_ type: yaml_event_type_t) throws(YAMLError) {
    if !hasEvent {
      if yaml_parser_parse(&parser, &event) == 0 {
        throw failure()
      }
      hasEvent = true
    }
    if event.type == YAML_STREAM_END_EVENT {
      throw YAMLError(message: "yaml: attempted to go past the end of stream; corrupted value?")
    }
    if event.type != type {
      throw YAMLError(message: "yaml: expected \(type) event but got \(event.type)")
    }
    yaml_event_delete(&event)
    hasEvent = false
  }

  /// go-yaml's `parser.fail`: note that for parser (not scanner) errors the reported line is
  /// libyaml's 0-based mark line, which go-yaml does not adjust.
  private func failure() -> YAMLError {
    var line = 0
    if parser.context_mark.line != 0 {
      line = parser.context_mark.line
      if parser.error == YAML_SCANNER_ERROR {
        line += 1
      }
    } else if parser.problem_mark.line != 0 {
      line = parser.problem_mark.line
      if parser.error == YAML_SCANNER_ERROR {
        line += 1
      }
    }
    var where_ = ""
    if line != 0 {
      where_ = "line \(line): "
    }
    var msg = "unknown problem parsing YAML content"
    if let problem = parser.problem, problem.pointee != 0 {
      msg = String(cString: problem)
    }
    return YAMLError(message: "yaml: \(where_)\(msg)")
  }

  private func node(kind: YAMLNode.Kind, defaultTag: String, tag: String, value: String) -> YAMLNode {
    var style: YAMLNode.Style = []
    var resolvedTag = tag
    if !tag.isEmpty && tag != "!" {
      resolvedTag = YAMLTags.shortTag(tag)
      style = .tagged
    } else if !defaultTag.isEmpty {
      resolvedTag = defaultTag
    } else if kind == .scalar {
      resolvedTag = YAMLResolver.resolve(tag: "", value).tag
    }
    return YAMLNode(
      kind: kind,
      tag: resolvedTag,
      value: value,
      style: style,
      line: Int(event.start_mark.line) + 1,
      column: Int(event.start_mark.column) + 1
    )
  }

  private func parseChild(_ parent: inout YAMLNode) throws(YAMLError) {
    if let child = try parse() {
      parent.content.append(child)
    }
  }

  private func document() throws(YAMLError) -> YAMLNode {
    var n = node(kind: .document, defaultTag: "", tag: "", value: "")
    try expect(YAML_DOCUMENT_START_EVENT)
    try parseChild(&n)
    _ = try peek()
    try expect(YAML_DOCUMENT_END_EVENT)
    return n
  }

  private func alias() throws(YAMLError) -> YAMLNode {
    let name = Self.string(event.data.alias.anchor)
    var n = node(kind: .alias, defaultTag: "", tag: "", value: name)
    guard let target = anchors[name] else {
      throw YAMLError(message: "yaml: unknown anchor '\(name)' referenced")
    }
    n.alias = target
    try expect(YAML_ALIAS_EVENT)
    return n
  }

  private func scalar() throws(YAMLError) -> YAMLNode {
    let data = event.data.scalar
    var nodeStyle: YAMLNode.Style = []
    switch data.style {
    case YAML_DOUBLE_QUOTED_SCALAR_STYLE: nodeStyle = .doubleQuoted
    case YAML_SINGLE_QUOTED_SCALAR_STYLE: nodeStyle = .singleQuoted
    case YAML_LITERAL_SCALAR_STYLE: nodeStyle = .literal
    case YAML_FOLDED_SCALAR_STYLE: nodeStyle = .folded
    default: break
    }
    let value: String
    if let ptr = data.value {
      value = String(decoding: UnsafeBufferPointer(start: ptr, count: data.length), as: UTF8.self)
    } else {
      value = ""
    }
    let tag = Self.string(data.tag)
    var defaultTag = ""
    if nodeStyle.isEmpty {
      if value == "<<" {
        defaultTag = YAMLTags.merge
      }
    } else {
      defaultTag = YAMLTags.str
    }
    var n = node(kind: .scalar, defaultTag: defaultTag, tag: tag, value: value)
    n.style.formUnion(nodeStyle)
    let anchor = Self.string(data.anchor)
    register(anchor, &n)
    try expect(YAML_SCALAR_EVENT)
    return n
  }

  private func sequence() throws(YAMLError) -> YAMLNode {
    let data = event.data.sequence_start
    var n = node(kind: .sequence, defaultTag: YAMLTags.seq, tag: Self.string(data.tag), value: "")
    if data.style == YAML_FLOW_SEQUENCE_STYLE {
      n.style.insert(.flow)
    }
    let anchor = Self.string(data.anchor)
    register(anchor, &n)
    try expect(YAML_SEQUENCE_START_EVENT)
    while try peek() != YAML_SEQUENCE_END_EVENT {
      try parseChild(&n)
    }
    try expect(YAML_SEQUENCE_END_EVENT)
    register(anchor, &n)
    return n
  }

  private func mapping() throws(YAMLError) -> YAMLNode {
    let data = event.data.mapping_start
    var n = node(kind: .mapping, defaultTag: YAMLTags.map, tag: Self.string(data.tag), value: "")
    if data.style == YAML_FLOW_MAPPING_STYLE {
      n.style.insert(.flow)
    }
    let anchor = Self.string(data.anchor)
    register(anchor, &n)
    try expect(YAML_MAPPING_START_EVENT)
    while try peek() != YAML_MAPPING_END_EVENT {
      try parseChild(&n)
      try parseChild(&n)
    }
    try expect(YAML_MAPPING_END_EVENT)
    register(anchor, &n)
    return n
  }

  /// Records an anchored node. go-yaml stores a pointer when the node starts, so aliases see the
  /// finished node; with value semantics the node is re-registered once its content is complete.
  private func register(_ anchor: String, _ n: inout YAMLNode) {
    guard !anchor.isEmpty else { return }
    n.anchor = anchor
    anchors[anchor] = n
  }

  private static func string(_ ptr: UnsafeMutablePointer<yaml_char_t>?) -> String {
    guard let ptr else { return "" }
    return String(cString: ptr)
  }
}
