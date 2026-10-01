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
//
// Ported from cel-go cel/library.go (Library, SingletonLibrary, LibraryAliaser, LibraryVersioner).
//
// cel-go libraries are objects returning lists of functional `EnvOption`s and `ProgramOption`s.
// Here a library is a value holding what those options would install, so an environment can read
// it: declarations for the checker and the interpreter's dispatcher, macros for the parser, and the
// names of the libraries it depends on.

/// A named bundle of CEL declarations that extends an environment, such as the strings or math
/// extension library.
///
/// Libraries are singletons by ``name``: an environment configured with two libraries of the same
/// name keeps the first, as cel-go does. The extension libraries are created by the factories in
/// the `CELExtensions` module, for example `Library.strings` or `Library.lists(version: 1)`.
public struct Library: Sendable {
  /// The version that enables every feature of a library, cel-go's `math.MaxUint32`.
  public static let latestVersion: UInt32 = .max

  /// The namespaced library name, for example `cel.lib.ext.strings`.
  public let name: String

  /// The short name used in environment configuration files, for example `strings`.
  public let alias: String

  /// The configured version; ``latestVersion`` when the library was created without one.
  public let version: UInt32

  /// The function declarations, with their runtime bindings, in declaration order.
  package var functions: [FunctionDecl]

  /// Variable and constant declarations.
  package var variables: [VariableDecl]

  /// Types the library introduces, such as the opaque `net.IP`; an environment registers them with
  /// its type provider so the checker can resolve their names.
  package var types: [CELType]

  /// Parser macros, added to the environment's macros (replacing standard macros with the same
  /// key, as cel-go's `cel.Macros` does).
  package var macros: [Macro]

  /// Parser options the library needs, such as optional syntax.
  package var parserOptions: [ParserOption] = []

  /// Planner decorators applied to every program (cel-go `ProgramOptions` with
  /// `CustomDecorator`), such as the `cel.@block` evaluation.
  package var decorators: [ProgramDecorator] = []

  /// Checks run on every type-checked expression (cel-go `ASTValidators`), such as the
  /// `string.format` clause validator.
  package var validators: [ExpressionValidator] = []

  /// Names of libraries that must be configured in the same environment, with the error an
  /// environment reports when one is missing (cel-go checks this with an `EnvOption`).
  package var requiredLibraries: [(name: String, error: String)]

  /// Functions whose list and map literal arguments are exempt from the homogeneous aggregate
  /// literal validator (cel-go `HomogeneousAggregateLiteralExemptFunctions`).
  package var homogeneousLiteralExemptFunctions: [String]

  /// Creates a library.
  package init(
    name: String,
    alias: String,
    version: UInt32 = Library.latestVersion,
    functions: [FunctionDecl] = [],
    variables: [VariableDecl] = [],
    types: [CELType] = [],
    macros: [Macro] = [],
    requiredLibraries: [(name: String, error: String)] = [],
    homogeneousLiteralExemptFunctions: [String] = []
  ) {
    self.name = name
    self.alias = alias
    self.version = version
    self.functions = functions
    self.variables = variables
    self.types = types
    self.macros = macros
    self.requiredLibraries = requiredLibraries
    self.homogeneousLiteralExemptFunctions = homogeneousLiteralExemptFunctions
  }

  /// The function declaration with the given name, if the library declares it.
  package func function(named name: String) -> FunctionDecl? {
    functions.first { $0.name == name }
  }

  /// The runtime bindings of every function in the library, keyed by overload id and function
  /// name, as an interpreter's dispatcher indexes them.
  package func bindings() throws -> [String: FunctionBinding] {
    var result: [String: FunctionBinding] = [:]
    for decl in functions {
      for binding in try decl.bindings() {
        result[binding.name] = binding
      }
    }
    return result
  }
}

extension ProgramEnvironment {
  /// Installs a library: merges its functions and variables into the declarations, registers its
  /// types when the provider is a ``TypeRegistry``, adds its macros (replacing macros with the same
  /// key), parser options and planner decorators (cel-go `cel.Lib`). Singleton deduplication by
  /// name is the caller's job.
  package mutating func install(_ library: Library) throws {
    try declare(library.variables, functions: library.functions)
    if !library.types.isEmpty, var registry = provider as? TypeRegistry {
      for type in library.types {
        try registry.register(type)
      }
      provider = registry
    }
    let keys = Set(library.macros.map(\.key))
    macros = macros.filter { !keys.contains($0.key) } + library.macros
    parserOptions += library.parserOptions
    decorators += library.decorators
  }
}
