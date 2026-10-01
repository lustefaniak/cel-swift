// Copyright 2023 Google LLC
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

// Ported from cel-go common/ast/ast.go (non-protobuf parts).
//
// The checked parts of cel-go's AST (type map, reference map) are filled in by the checker; their
// accessors and `ReferenceInfo` are in ReferenceInfo.swift.

/// A parsed expression together with its source metadata.
package struct AST: Sendable {
  /// The root expression.
  package var expr: Expr
  /// Offsets, line information and macro calls for the expression.
  package var sourceInfo: SourceInfo
  /// Checked types by expression id; empty until the AST is type-checked (cel-go `TypeMap`).
  package var typeMap: [Int64: CELType] = [:]
  /// Resolved identifiers and overloads by expression id (cel-go `ReferenceMap`).
  package var referenceMap: [Int64: ReferenceInfo] = [:]

  package init(expr: Expr, sourceInfo: SourceInfo) {
    self.expr = expr
    self.sourceInfo = sourceInfo
  }

  /// The set of node ids in the expression and in the macro calls.
  package var ids: Set<Int64> {
    var ids = Set<Int64>()
    let collect: (Int64) -> Void = { ids.insert($0) }
    expr.postOrderVisit(expr: { collect($0.id) }, entry: { collect($0.id) })
    for call in sourceInfo.macroCalls.values {
      call.postOrderVisit(expr: { collect($0.id) }, entry: { collect($0.id) })
    }
    return ids
  }

  /// The upper bound (exclusive) of ids used in the expression and macro calls (cel-go `ast.MaxID`).
  package var maxID: Int64 {
    var maxID: Int64 = 1
    let update: (Int64) -> Void = { if maxID < $0 { maxID = $0 } }
    expr.postOrderVisit(expr: { update($0.id) }, entry: { update($0.id) })
    for (id, call) in sourceInfo.macroCalls {
      call.postOrderVisit(expr: { update($0.id) }, entry: { update($0.id) })
      if id > maxID {
        maxID = id + 1
      }
    }
    return maxID + 1
  }

  /// The number of expression nodes, including macro calls (cel-go `ast.NodeCount`).
  package var nodeCount: Int { ids.count }

  /// Removes offset ranges for ids that no longer occur in the AST or the macro calls.
  package mutating func clearUnusedIDs() {
    let ids = self.ids
    for id in sourceInfo.offsetRanges.keys where !ids.contains(id) {
      sourceInfo.clearOffsetRange(id)
    }
  }

  /// The height of every node in the expression, keyed by id (cel-go `ast.Heights`).
  ///
  /// Identifiers and literals have height zero.
  package var heights: [Int64: Int] {
    var hv: [Int64: Int] = [:]
    func maxHeight(_ exprs: [Expr]) -> Int {
      exprs.reduce(0) { Swift.max($0, hv[$1.id] ?? 0) }
    }
    expr.postOrderVisit(
      expr: { e in
        hv[e.id] = 0
        switch e.kind {
        case .select(let s):
          hv[e.id] = 1 + (hv[s.operand.id] ?? 0)
        case .call(let c):
          var height = maxHeight(c.args)
          if let target = c.target {
            height = Swift.max(height, hv[target.id] ?? 0)
          }
          hv[e.id] = 1 + height
        case .list(let l):
          hv[e.id] = 1 + maxHeight(l.elements)
        case .map(let m):
          hv[e.id] = 1 + m.entries.reduce(0) { Swift.max($0, hv[$1.id] ?? 0) }
        case .struct(let s):
          hv[e.id] = 1 + s.fields.reduce(0) { Swift.max($0, hv[$1.id] ?? 0) }
        case .comprehension(let c):
          hv[e.id] =
            1 + maxHeight([c.iterRange, c.accuInit, c.loopCondition, c.loopStep, c.result])
        case .unspecified, .literal, .ident:
          break
        }
      },
      entry: { entry in
        switch entry {
        case .mapEntry(let me):
          hv[me.id] = maxHeight([me.value, me.key])
        case .structField(let sf):
          hv[sf.id] = hv[sf.value.id] ?? 0
        }
      })
    return hv
  }
}

/// The start and stop code point offsets of an expression in the source text.
package struct OffsetRange: Hashable, Sendable {
  package var start: Int32
  package var stop: Int32

  package init(start: Int32, stop: Int32) {
    self.start = start
    self.stop = stop
  }
}

/// A versioned optional feature recorded in the source info.
package struct SourceExtension: Hashable, Sendable {
  /// Which CEL component a feature affects.
  package enum Component: Int, Hashable, Sendable {
    case parser = 1
    case typeChecker = 2
    case runtime = 3
  }

  /// A major / minor version.
  package struct Version: Hashable, Sendable {
    package var major: Int64
    package var minor: Int64

    package init(major: Int64, minor: Int64) {
      self.major = major
      self.minor = minor
    }
  }

  package var id: String
  package var version: Version
  package var components: [Component]

  package init(id: String, version: Version, components: [Component]) {
    self.id = id
    self.version = version
    self.components = components
  }
}

/// Source metadata for an expression: description, line offsets, node offset ranges and macro calls.
package struct SourceInfo: Sendable {
  package var syntaxVersion: String
  package var description: String
  package var lineOffsets: [Int32]
  package var baseLine: Int32
  package var baseColumn: Int32
  package private(set) var offsetRanges: [Int64: OffsetRange]
  package private(set) var macroCalls: [Int64: Expr]
  package private(set) var extensions: [SourceExtension]

  /// Creates source info for `source`, relative to the location of offset 0 in it.
  package init(source: (any Source)?) {
    var baseLine: Int32 = 0
    var baseColumn: Int32 = 0
    if let source, let loc = source.offsetLocation(0) {
      baseLine = Int32(loc.line) - 1
      baseColumn = Int32(loc.column)
    }
    self.init(
      description: source?.description ?? "", lineOffsets: source?.lineOffsets ?? [],
      baseLine: baseLine, baseColumn: baseColumn)
  }

  package init(
    syntaxVersion: String = "", description: String, lineOffsets: [Int32], baseLine: Int32 = 0,
    baseColumn: Int32 = 0, offsetRanges: [Int64: OffsetRange] = [:], macroCalls: [Int64: Expr] = [:],
    extensions: [SourceExtension] = []
  ) {
    self.syntaxVersion = syntaxVersion
    self.description = description
    self.lineOffsets = lineOffsets
    self.baseLine = baseLine
    self.baseColumn = baseColumn
    self.offsetRanges = offsetRanges
    self.macroCalls = macroCalls
    self.extensions = extensions
  }

  /// Rewrites the ids of the offset ranges with `generate`, visiting old ids in ascending order.
  package mutating func renumberIDs(_ generate: (Int64) -> Int64) {
    var newRanges: [Int64: OffsetRange] = [:]
    for id in offsetRanges.keys.sorted() {
      newRanges[generate(id)] = offsetRanges[id]
    }
    offsetRanges = newRanges
  }

  /// The original call replaced by a macro expansion rooted at `id`, if recorded.
  package func macroCall(_ id: Int64) -> Expr? {
    macroCalls[id]
  }

  /// Records the original call of a macro expanded into the node `id`.
  package mutating func setMacroCall(_ id: Int64, _ call: Expr) {
    macroCalls[id] = call
  }

  /// Removes the macro call recorded for `id`.
  package mutating func clearMacroCall(_ id: Int64) {
    macroCalls[id] = nil
  }

  /// The offset range of the node `id`, if recorded.
  package func offsetRange(_ id: Int64) -> OffsetRange? {
    offsetRanges[id]
  }

  /// Records the offset range of the node `id`.
  package mutating func setOffsetRange(_ id: Int64, _ range: OffsetRange) {
    offsetRanges[id] = range
  }

  /// Removes the offset range of the node `id`.
  package mutating func clearOffsetRange(_ id: Int64) {
    offsetRanges[id] = nil
  }

  /// The 1-based line and 0-based column of the first character of the node `id`.
  package func startLocation(_ id: Int64) -> Location {
    if let o = offsetRanges[id] {
      return location(ofOffset: o.start)
    }
    return .none
  }

  /// The 1-based line and 0-based column of the last character of the node `id`.
  package func stopLocation(_ id: Int64) -> Location {
    if let o = offsetRanges[id] {
      return location(ofOffset: o.stop)
    }
    return .none
  }

  /// The line and column of a code point offset.
  package func location(ofOffset offset: Int32) -> Location {
    var line = 1
    var col = Int(offset)
    for lineOffset in lineOffsets {
      if lineOffset > offset {
        break
      }
      line += 1
      col = Int(offset - lineOffset)
    }
    return Location(line: line, column: col)
  }

  /// The code point offset of a line and column relative to the base location.
  package func computeOffset(line: Int32, column: Int32) -> Int32 {
    computeOffsetAbsolute(line: baseLine + line, column: baseColumn + column)
  }

  /// The code point offset of an absolute line and column.
  package func computeOffsetAbsolute(line: Int32, column: Int32) -> Int32 {
    if line == 1 {
      return column
    }
    if line < 1 || line > Int32(lineOffsets.count) {
      return -1
    }
    return lineOffsets[Int(line) - 2] + column
  }

  /// Whether an extension with the same major and at least the given minor version is present.
  ///
  /// Mirrors cel-go, which only inspects the first recorded extension.
  package func hasExtension(id: String, minVersion: SourceExtension.Version) -> Bool {
    guard let ext = extensions.first else {
      return false
    }
    return ext.id == id && ext.version.major == minVersion.major
      && ext.version.minor >= minVersion.minor
  }

  /// Records an extension.
  package mutating func addExtension(_ ext: SourceExtension) {
    extensions.append(ext)
  }
}
