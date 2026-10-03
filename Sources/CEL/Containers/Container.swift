// Copyright 2018 Google LLC
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
//
// Ported from cel-go common/containers/container.go (ToQualifiedName, which needs the AST, lives
// with the AST).

/// The namespace an expression is resolved in, with optional aliases (abbreviations).
///
/// A container behaves like a C++ namespace: with the container `a.b.c`, the name `R.s` resolves
/// to the first declared candidate of `a.b.c.R.s`, `a.b.R.s`, `a.R.s` and `R.s`. Aliases map a
/// simple name to a fully qualified name and take precedence over container resolution.
public struct Container: Sendable, Hashable {
  /// The fully qualified container name; empty for the root namespace.
  public private(set) var name: String = ""
  /// Alias to fully qualified name mappings.
  public private(set) var aliases: [String: String] = [:]

  /// The root container: no name, no aliases.
  public static let `default` = Container()

  /// Creates the root container.
  public init() {}

  /// Creates a container by applying options to the root container.
  ///
  /// - Throws: ``DeclarationError`` for invalid names or colliding aliases.
  public init(_ options: Option...) throws(DeclarationError) {
    try self.init(options: options)
  }

  /// Creates a container by applying an array of options to the root container.
  public init(options: [Option]) throws(DeclarationError) {
    for option in options {
      try option.apply(&self)
    }
  }

  /// Returns a copy of the container with further options applied.
  public func extended(_ options: Option...) throws(DeclarationError) -> Container {
    var copy = self
    for option in options {
      try option.apply(&copy)
    }
    return copy
  }

  /// The candidate fully qualified names for `name`, most qualified first.
  ///
  /// A leading dot makes the name absolute; an alias for the first name component replaces the
  /// container search.
  public func resolveCandidateNames(_ name: String) -> [String] {
    if name.utf8.first == UInt8(ascii: ".") {
      let qualified = String(decoding: name.utf8.dropFirst(), as: UTF8.self)
      if let alias = findAlias(qualified) {
        return [alias]
      }
      return [qualified]
    }
    if let alias = findAlias(name) {
      return [alias]
    }
    if self.name.isEmpty {
      return [name]
    }
    var next = Array(self.name.utf8)
    var candidates = [self.name + "." + name]
    while let dot = next.lastIndex(of: UInt8(ascii: ".")) {
      next = Array(next[..<dot])
      candidates.append(String(decoding: next, as: UTF8.self) + "." + name)
    }
    candidates.append(name)
    return candidates
  }

  /// The alias expansion of `name` (without a leading dot): an alias of the first component is
  /// expanded and the remaining components appended.
  func findAlias(_ name: String) -> String? {
    if aliases.isEmpty {
      return nil
    }
    let utf8 = name.utf8
    guard let dot = utf8.firstIndex(of: UInt8(ascii: ".")) else {
      return aliases[name]
    }
    guard let alias = aliases[String(decoding: utf8[..<dot], as: UTF8.self)] else {
      return nil
    }
    return alias + String(decoding: utf8[dot...], as: UTF8.self)
  }
}

extension Container {
  /// A configuration step applied to a ``Container``.
  public struct Option: Sendable {
    let apply: @Sendable (inout Container) throws(DeclarationError) -> Void

    /// Sets the fully qualified container name, which must not start with a dot.
    public static func name(_ name: String) -> Option {
      Option { (c: inout Container) throws(DeclarationError) in
        if name.utf8.first == UInt8(ascii: ".") {
          throw DeclarationError("container name must not contain a leading '.': \(name)")
        }
        c.name = name
      }
    }

    /// Declares abbreviations: each qualified name `a.b.C` becomes available as `C`.
    ///
    /// Abbreviations must be qualified, must not collide with each other, and must not collide
    /// with the container name.
    public static func abbreviations(_ qualifiedNames: String...) -> Option {
      abbreviations(qualifiedNames)
    }

    /// Declares abbreviations from an array of qualified names.
    public static func abbreviations(_ qualifiedNames: [String]) -> Option {
      Option { (c: inout Container) throws(DeclarationError) in
        for raw in qualifiedNames {
          let qn = trimmingGoSpace(raw)
          for scalar in qn.unicodeScalars where !isIdentifierChar(scalar) {
            throw DeclarationError(
              "invalid qualified name: \(qn), wanted name of the form 'qualified.name'")
          }
          let bytes = Array(qn.utf8)
          guard let ind = bytes.lastIndex(of: UInt8(ascii: ".")), ind > 0, ind < bytes.count - 1
          else {
            throw DeclarationError(
              "invalid qualified name: \(qn), wanted name of the form 'qualified.name'")
          }
          let alias = String(decoding: bytes[(ind + 1)...], as: UTF8.self)
          try aliasAs(kind: "abbreviation", qualifiedName: qn, alias: alias, requireQualified: true)
            .apply(&c)
        }
      }
    }

    /// Associates a simple alias with a qualified name.
    public static func alias(_ qualifiedName: String, as alias: String) -> Option {
      aliasAs(kind: "alias", qualifiedName: qualifiedName, alias: alias, requireQualified: false)
    }

    private static func aliasAs(
      kind: String, qualifiedName: String, alias: String, requireQualified: Bool
    ) -> Option {
      Option { (c: inout Container) throws(DeclarationError) in
        if alias.isEmpty || alias.utf8.contains(UInt8(ascii: ".")) {
          throw DeclarationError(
            "\(kind) must be non-empty and simple (not qualified): \(kind)=\(alias)")
        }
        if qualifiedName.isEmpty {
          throw DeclarationError("\(kind) must refer to a valid name: \(qualifiedName)")
        }
        let bytes = Array(qualifiedName.utf8)
        if bytes[0] == UInt8(ascii: ".") {
          throw DeclarationError(
            "qualified name must not begin with a leading '.': \(qualifiedName)")
        }
        let ind = bytes.lastIndex(of: UInt8(ascii: "."))
        if ind == bytes.count - 1 || (requireQualified && (ind ?? -1) <= 0) {
          throw DeclarationError("\(kind) must refer to a valid qualified name: \(qualifiedName)")
        }
        if let aliasRef = c.aliases[alias] {
          throw DeclarationError(
            "\(kind) collides with existing reference: name=\(qualifiedName), \(kind)=\(alias), existing=\(aliasRef)"
          )
        }
        if c.name.utf8.starts(with: (alias + ".").utf8) || c.name == alias {
          throw DeclarationError(
            "\(kind) collides with container name: name=\(qualifiedName), \(kind)=\(alias), container=\(c.name)"
          )
        }
        c.aliases[alias] = qualifiedName
      }
    }
  }
}

/// Go `isIdentifierChar` in containers: ASCII letters, digits, `.` and `_`.
private func isIdentifierChar(_ r: Unicode.Scalar) -> Bool {
  guard r.isASCII else { return false }
  return r == "." || r == "_" || r.properties.isAlphabetic || r.properties.numericType != nil
}

/// Go `strings.TrimSpace` for the ASCII and Unicode white space Go recognizes.
private func trimmingGoSpace(_ s: String) -> String {
  let scalars = Array(s.unicodeScalars)
  var start = 0
  var end = scalars.count
  while start < end && scalars[start].properties.isWhitespace {
    start += 1
  }
  while end > start && scalars[end - 1].properties.isWhitespace {
    end -= 1
  }
  var out = String.UnicodeScalarView()
  out.append(contentsOf: scalars[start..<end])
  return String(out)
}
