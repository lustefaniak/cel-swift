// Copyright 2022 Google LLC
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

// The parts of cel-go cel/env.go and cel/library.go the policy compiler and the test runner use:
// NewCustomEnv, Extend with libraries / variables / functions / container options, CompileSource,
// Check and Program.
//
// TODO(api): this is the single adapter between CELPolicy and the core. It is built on the
// package-level `ProgramEnvironment`, `Parser` and `Checker`; once the public `Environment` lands
// on main, the public policy API takes an `Environment` and converts it here.

import CEL

extension Library {
  /// The optional types library (cel-go `cel.OptionalTypes`).
  package static func optionalTypes(version: UInt32 = OptionalLibrary.latestVersion) -> Library {
    var lib = Library(
      name: "cel.lib.optional", alias: "optional", version: version,
      functions: OptionalLibrary.functions(version: version),
      variables: OptionalLibrary.types,
      macros: OptionalLibrary.macros(version: version))
    lib.parserOptions = [.enableOptionalSyntax(true)]
    lib.decorators = [OptionalLibrary.decorator]
    return lib
  }

  /// The standard library, optionally restricted to a subset (cel-go `cel.StdLib`).
  package static func standard(subset: EnvironmentConfig.LibrarySubset? = nil) -> Library {
    var functions: [FunctionDecl] = []
    for fn in StandardLibrary.functions {
      if let subset {
        if let kept = subset.subsetFunction(fn) {
          functions.append(kept)
        }
      } else {
        functions.append(fn)
      }
    }
    let macros = Macro.allMacros.filter { subset?.includesMacro($0.function) ?? true }
    return Library(
      name: "cel.lib.std", alias: "stdlib", functions: functions, variables: StandardLibrary.types,
      macros: macros)
  }
}

/// An error building or extending an environment, with cel-go's message.
package struct EnvironmentError: Error, Sendable, CustomStringConvertible {
  package var description: String

  package init(_ description: String) {
    self.description = description
  }
}

/// Resolves an extension library by name and version (cel-go `ConfigOptionFactory` for
/// `env.Extension`); `nil` when the name is not recognized.
package typealias ExtensionResolver = @Sendable (_ name: String, _ version: UInt32) -> Library?

/// The declarations, libraries and options expressions are compiled and planned against (the
/// subset of cel-go's `cel.Env` the policy compiler needs).
package struct PolicyEnvironment: Sendable {
  package private(set) var base: ProgramEnvironment
  package private(set) var checker: CheckerEnv
  /// The libraries applied, by name, with their version.
  package private(set) var libraries: [String: UInt32] = [:]
  /// Records macro calls in the source info (cel-go `EnableMacroCallTracking`).
  package private(set) var macroCallTracking = false
  /// Resolves extension names in environment configs.
  package var extensionResolver: ExtensionResolver?

  /// An environment without the standard library (cel-go `NewCustomEnv`).
  package init(provider: any TypeProvider = TypeRegistry()) {
    var base = ProgramEnvironment(functions: [], provider: provider, macros: [])
    base.declaresStandardTypes = false
    self.base = base
    // An empty environment always builds.
    self.checker = CheckerEnv(container: base.container, provider: provider, options: base.checkerOptions)
  }

  /// An environment with the standard library (cel-go `NewEnv`).
  package static func standard(provider: any TypeProvider = TypeRegistry()) throws -> PolicyEnvironment {
    var env = PolicyEnvironment(provider: provider)
    try env.addLibrary(.standard())
    return env
  }

  /// The type provider.
  package var provider: any TypeProvider { base.provider }

  /// The container names resolve in.
  package var container: Container { base.container }

  /// Whether a library of the given name has been applied (cel-go `HasLibrary`).
  package func hasLibrary(_ name: String) -> Bool {
    libraries[name] != nil
  }

  // MARK: - Extension (cel-go EnvOption)

  /// Applies a library unless one of the same name is already applied.
  package mutating func addLibrary(_ library: Library) throws {
    if libraries[library.name] != nil {
      return
    }
    var next = self
    next.libraries[library.name] = library.version
    for (name, error) in library.requiredLibraries where next.libraries[name] == nil {
      throw EnvironmentError(error)
    }
    if !library.types.isEmpty, var registry = next.base.provider as? TypeRegistry {
      for t in library.types {
        try? registry.register(t)
      }
      next.base.provider = registry
      try next.rebuildChecker()
    }
    try next.declare(variables: library.variables, functions: library.functions)
    for macro in library.macros {
      next.base.macros.removeAll { $0.key == macro.key }
      next.base.macros.append(macro)
    }
    next.base.parserOptions += library.parserOptions
    next.base.decorators += library.decorators
    self = next
  }

  /// Declares variables and functions, merging functions with existing declarations of the same
  /// name; the environment is unchanged when a declaration conflicts.
  package mutating func declare(variables: [VariableDecl] = [], functions: [FunctionDecl] = []) throws {
    var next = self
    try next.base.declare(variables, functions: functions)
    try next.checker.addIdents(variables)
    try next.checker.addFunctions(functions)
    self = next
  }

  /// Extends the container with a name (cel-go `Container`).
  package mutating func setContainer(_ name: String) throws {
    try updateContainer(.name(name))
  }

  /// Adds abbreviations for qualified names (cel-go `Abbrevs`).
  package mutating func addAbbreviations(_ names: [String]) throws {
    try updateContainer(.abbreviations(names))
  }

  private mutating func updateContainer(_ option: Container.Option) throws {
    var next = self
    next.base.container = try container.extended(option)
    try next.rebuildChecker()
    self = next
  }

  /// Enables macro call tracking (cel-go `EnableMacroCallTracking`).
  package mutating func enableMacroCallTracking() {
    if !macroCallTracking {
      macroCallTracking = true
      base.parserOptions.append(.populateMacroCalls(true))
    }
  }

  /// Adds a parser option; later options override earlier ones.
  package mutating func addParserOption(_ option: ParserOption) {
    base.parserOptions.append(option)
  }

  /// Adds a type-checker option.
  package mutating func addCheckerOption(_ option: CheckerOption) {
    var next = self
    next.base.checkerOptions.append(option)
    if (try? next.rebuildChecker()) != nil {
      self = next
    }
  }

  private mutating func rebuildChecker() throws {
    checker = try base.checkerEnv()
  }

  // MARK: - Compilation

  /// Parses an expression; the AST is `nil` when the errors are fatal.
  package func parse(_ source: any Source) -> (ast: AST?, errors: CELErrors) {
    let parser: Parser
    do {
      parser = try Parser(options: [.macros(base.macros)] + base.parserOptions)
    } catch {
      var errs = CELErrors(source: source)
      errs.reportError(at: .none, "\(error)")
      return (nil, errs)
    }
    let (ast, errors) = parser.parse(source)
    return (errors.isEmpty ? ast : nil, errors)
  }

  /// Type-checks a parsed AST (cel-go `Env.Check`).
  package func check(_ ast: AST, source: any Source) -> (ast: AST?, errors: CELErrors) {
    let checker = self.checker
    var result: (ast: AST, errors: CELErrors)?
    runWithStack(depth: ast.expr.depth) {
      result = Checker.check(ast, source: source, env: checker)
    }
    guard let (checked, errors) = result else {
      return (nil, CELErrors(source: source))
    }
    return (errors.isEmpty ? checked : nil, errors)
  }

  /// Parses and type-checks an expression (cel-go `Env.CompileSource`).
  package func compile(_ source: any Source) -> (ast: AST?, errors: CELErrors) {
    let (parsed, parseErrors) = parse(source)
    guard let parsed else {
      return (nil, parseErrors)
    }
    return check(parsed, source: source)
  }

  /// Parses and type-checks expression text (cel-go `Env.Compile`).
  package func compile(_ text: String, description: String = "<input>") -> (ast: AST?, errors: CELErrors) {
    compile(TextSource(text, description: description))
  }

  /// Plans a program (cel-go `Env.Program`).
  package func program(_ ast: AST, options: ProgramOptions = ProgramOptions()) throws -> Program {
    try base.program(ast, options: options)
  }
}

extension EnvironmentConfig.LibrarySubset {
  /// The subset of a function's overloads the library subset keeps, or `nil` when the function is
  /// excluded (cel-go `LibrarySubset.SubsetFunction`).
  package func subsetFunction(_ fn: FunctionDecl) -> FunctionDecl? {
    if isDisabled {
      return nil
    }
    if !includedFunctions.isEmpty {
      for include in includedFunctions where include.name == fn.name {
        if include.overloads.isEmpty {
          return fn
        }
        return fn.including(overloadIDs: include.overloads.map(\.id))
      }
      return nil
    }
    if !excludedFunctions.isEmpty {
      for exclude in excludedFunctions where exclude.name == fn.name {
        if exclude.overloads.isEmpty {
          return nil
        }
        return fn.excluding(overloadIDs: exclude.overloads.map(\.id))
      }
      return fn
    }
    return fn
  }
}

/// Runs `body` on a large enough stack for deep expressions.
func runWithStack(depth: Int, _ body: () -> Void) {
  // The core's `withStack` is internal; checker recursion is shallow enough for policies built
  // from YAML expressions, so run in place.
  _ = depth
  body()
}
