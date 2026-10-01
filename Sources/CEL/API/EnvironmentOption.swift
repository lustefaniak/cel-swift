// Copyright 2019 Google LLC
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
// Re-designed from cel-go cel/options.go (EnvOption and its constructors, features and limits),
// cel/decls.go (Variable, Constant, Function) and cel/library.go (Lib, StdLib, OptionalTypes,
// EnableErrorOnBadPresenceTest).

extension Environment {
  /// Everything an environment is built from: the accumulated effect of its options.
  package struct Configuration: Sendable {
    package var container = Container.default
    package var variables: [VariableDecl] = []
    /// Functions in declaration order; options declaring an existing name merge into it.
    package var functions: [FunctionDecl] = []
    package var macros: [Macro] = []
    package var registry = TypeRegistry()
    package var libraryNames: [String] = []
    package var decorators: [ProgramDecorator] = []
    package var costEstimateOptions = CostEstimateOptions()
    package var costTrackers: [String: FunctionTracker] = [:]
    package var regexProgramSizeLimit = 0
    package var programOptions: [Program.Option] = []
    package var validators: [ExpressionValidator] = []
    /// Types registered by libraries and options, re-registered when the provider is replaced.
    package var registeredTypes: [CELType] = []
    package var homogeneousLiteralExemptFunctions: [String] = []

    // Features (cel-go `features`).
    package var crossTypeNumericComparisons = false
    package var errorOnBadPresenceTest = false
    package var jsonFieldNames = false
    package var macroCallTracking = false
    package var optionalSyntax = false
    package var identifierEscapeSyntax = false
    package var variadicLogicalASTs = false
    package var hiddenAccumulatorName = true
    package var extraParserOptions: [ParserOption] = []

    // Limits (cel-go `limits`); 0 means the default.
    package var parserRecursionLimit = 0
    package var parserErrorRecoveryLimit = 0
    package var expressionSizeCodePointLimit = 0
    package var expressionNodeCountLimit = 0

    package init() {}

    /// The code point limit applied when creating sources (cel-go `configuredExpressionSizeLimit`).
    package var expressionSizeLimit: Int {
      expressionSizeCodePointLimit != 0 ? expressionSizeCodePointLimit : 100_000
    }

    /// The node count limit applied before checking (cel-go `configuredExpressionNodeLimit`).
    package var expressionNodeLimit: Int {
      expressionNodeCountLimit != 0 ? expressionNodeCountLimit : 100_000
    }

    package var parserOptions: [ParserOption] {
      var options: [ParserOption] = [.macros(macros)]
      options += extraParserOptions
      if macroCallTracking { options.append(.populateMacroCalls(true)) }
      if variadicLogicalASTs { options.append(.enableVariadicOperatorASTs(true)) }
      if optionalSyntax { options.append(.enableOptionalSyntax(true)) }
      options.append(.enableIdentEscapeSyntax(identifierEscapeSyntax))
      options.append(.enableHiddenAccumulatorName(hiddenAccumulatorName))
      if parserErrorRecoveryLimit != 0 { options.append(.errorRecoveryLimit(parserErrorRecoveryLimit)) }
      if expressionSizeCodePointLimit != 0 {
        options.append(.expressionSizeCodePointLimit(expressionSizeCodePointLimit))
      }
      if parserRecursionLimit != 0 { options.append(.maxRecursionDepth(parserRecursionLimit)) }
      if expressionNodeCountLimit != 0 { options.append(.maxExpressionNodeCount(expressionNodeCountLimit)) }
      return options
    }

    package var checkerOptions: [CheckerOption] {
      [.crossTypeNumericComparisons(crossTypeNumericComparisons), .jsonFieldNames(jsonFieldNames)]
    }

    /// Adds a function, merging it into an existing declaration with the same name
    /// (cel-go `Function` env option).
    package mutating func declare(_ function: FunctionDecl) throws {
      if let i = functions.firstIndex(where: { $0.name == function.name }) {
        functions[i] = try functions[i].merging(function)
      } else {
        functions.append(function)
      }
    }

    /// Applies a library unless one with the same name is already configured (cel-go `Lib`).
    package mutating func apply(_ library: Library) throws {
      if libraryNames.contains(library.name) {
        return
      }
      for required in library.requiredLibraries where !libraryNames.contains(required.name) {
        throw DeclarationError(required.error)
      }
      libraryNames.append(library.name)
      for type in library.types {
        try registry.register(type)
        registeredTypes.append(type)
      }
      variables += library.variables
      for function in library.functions {
        try declare(function)
      }
      macros += library.macros
      extraParserOptions += library.parserOptions
      decorators += library.decorators
      costEstimateOptions.merge(library.costEstimateOptions)
      costTrackers.merge(library.costTrackers) { _, new in new }
      homogeneousLiteralExemptFunctions += library.homogeneousLiteralExemptFunctions
      for validator in library.validators where !validators.contains(where: { $0.name == validator.name }) {
        validators.append(validator)
      }
    }
  }

  /// A configuration step for an ``Environment``: a declaration, a library or a feature.
  ///
  /// Options are applied in order; later options see the effect of earlier ones, so for example
  /// ``clearMacros`` must come before options that add macros.
  public struct Option: Sendable {
    let apply: @Sendable (inout Configuration) throws -> Void

    package init(_ apply: @escaping @Sendable (inout Configuration) throws -> Void) {
      self.apply = apply
    }

    // MARK: Declarations

    /// Declares a variable of the given type (cel-go `Variable`).
    ///
    /// - Parameters:
    ///   - name: The variable name, possibly qualified such as `request.auth`.
    ///   - type: The variable type; use `.dyn` when the type is not known statically.
    public static func variable(_ name: String, _ type: CELType) -> Option {
      variables([VariableDecl(name: name, type: type)])
    }

    /// Declares variables (cel-go `VariableDecls`).
    public static func variables(_ declarations: [VariableDecl]) -> Option {
      Option { $0.variables += declarations }
    }

    /// Declares variables from a dictionary of names and types, in name order.
    public static func variables(_ types: [String: CELType]) -> Option {
      variables(types.sorted { $0.key < $1.key }.map { VariableDecl(name: $0.key, type: $0.value) })
    }

    /// Declares a named constant, which the checker inlines (cel-go `Constant`).
    ///
    /// - Parameters:
    ///   - name: The constant name.
    ///   - type: The constant type.
    ///   - value: The constant value, which must be of `type`.
    public static func constant(_ name: String, _ type: CELType, value: Value) -> Option {
      variables([VariableDecl(constant: name, type: type, value: value)])
    }

    /// Declares a function, or adds overloads to an existing one (cel-go `Function`).
    ///
    /// - Parameters:
    ///   - name: The function name.
    ///   - options: Overloads, bindings and documentation for the function.
    public static func function(_ name: String, _ options: FunctionDecl.Option...) -> Option {
      Option { try $0.declare(FunctionDecl(name, options: options)) }
    }

    /// Declares functions, merging each into an existing function with the same name
    /// (cel-go `FunctionDecls`).
    public static func functions(_ declarations: [FunctionDecl]) -> Option {
      Option { config in
        for declaration in declarations {
          try config.declare(declaration)
        }
      }
    }

    // MARK: Names and types

    /// Sets the container unqualified names are resolved in, such as `google.type`
    /// (cel-go `Container`).
    public static func container(_ name: String) -> Option {
      Option { $0.container = try $0.container.extended(.name(name)) }
    }

    /// Makes qualified names available by their last component, such as `C` for `a.b.C`
    /// (cel-go `Abbrevs`).
    public static func abbreviations(_ qualifiedNames: String...) -> Option {
      Option { $0.container = try $0.container.extended(.abbreviations(qualifiedNames)) }
    }

    /// Makes a qualified name available under a simple alias.
    public static func alias(_ qualifiedName: String, as alias: String) -> Option {
      Option { $0.container = try $0.container.extended(.alias(qualifiedName, as: alias)) }
    }

    /// Resolves message types, enums and fields with `provider` (cel-go `CustomTypeProvider`).
    ///
    /// A ``TypeRegistry`` replaces the environment's registry; any other provider, such as the
    /// protobuf types of the `CELProtobuf` module, is consulted after the registry's own types.
    /// Use this option before ``types(_:)``.
    public static func typeProvider(_ provider: any TypeProvider) -> Option {
      Option { config in
        if let registry = provider as? TypeRegistry {
          config.registry = registry
        } else {
          config.registry = TypeRegistry(composing: provider, adapter: provider as? any TypeAdapter)
        }
        for type in config.registeredTypes {
          try config.registry.register(type)
        }
      }
    }

    /// Registers types with the environment's type registry (cel-go `Types`), such as opaque
    /// types an extension function returns.
    public static func types(_ types: [CELType]) -> Option {
      Option { config in
        for type in types {
          try config.registry.register(type)
          config.registeredTypes.append(type)
        }
      }
    }

    /// Registers message types described by `descriptors` with the environment's type registry.
    public static func types(_ descriptors: [any StructTypeDescriptor]) -> Option {
      Option { config in
        for descriptor in descriptors {
          try config.registry.register(descriptor)
        }
      }
    }

    // MARK: Libraries and macros

    /// Adds a library, unless one with the same name is already configured (cel-go `Lib`).
    ///
    /// - Throws: When the library requires another library that is not configured yet.
    public static func library(_ library: Library) -> Option {
      Option { try $0.apply(library) }
    }

    /// Adds libraries in order.
    public static func libraries(_ libraries: [Library]) -> Option {
      Option { config in
        for library in libraries {
          try config.apply(library)
        }
      }
    }

    /// The CEL standard library: operators, functions, conversions, type identifiers and the
    /// standard macros (cel-go `StdLib`). Included by ``Environment/init(_:)``.
    public static var standardLibrary: Option {
      library(.standard)
    }

    /// Optional types: `optional_type`, `optional.of`, `.?` and `[?` syntax, `or`, `orValue`
    /// and the `optMap` / `optFlatMap` macros (cel-go `OptionalTypes`).
    public static var optionalTypes: Option {
      library(.optionalTypes())
    }

    /// Removes every macro, including the standard ones (cel-go `ClearMacros`).
    ///
    /// Without macros, expressions cannot contain comprehensions, so their evaluation time is
    /// linear in their size.
    public static var clearMacros: Option {
      Option { $0.macros = [] }
    }

    // MARK: Features

    /// Allows comparing numbers of different types, such as `1 < 2.5` (cel-go
    /// `CrossTypeNumericComparisons`).
    public static func crossTypeNumericComparisons(_ enabled: Bool = true) -> Option {
      Option { $0.crossTypeNumericComparisons = enabled }
    }

    /// Makes `has(x.f)` and `x.?f` an error when `x` is not a message or map (cel-go
    /// `EnableErrorOnBadPresenceTest`).
    public static func errorOnBadPresenceTest(_ enabled: Bool = true) -> Option {
      Option { $0.errorOnBadPresenceTest = enabled }
    }

    /// Resolves protobuf fields by their JSON names when checking (cel-go `JSONFieldNames`).
    ///
    /// At runtime the type provider decides which names fields have; create the `CELProtobuf`
    /// types with JSON field names to match.
    public static func jsonFieldNames(_ enabled: Bool = true) -> Option {
      Option { $0.jsonFieldNames = enabled }
    }

    /// Records the original calls of macro expansions, so checked expressions can be printed
    /// back with their macros (cel-go `EnableMacroCallTracking`).
    public static var macroCallTracking: Option {
      Option { $0.macroCallTracking = true }
    }

    /// Allows backtick-quoted field names such as ``a.`b-c` `` (cel-go
    /// `EnableIdentifierEscapeSyntax`).
    public static func identifierEscapeSyntax(_ enabled: Bool = true) -> Option {
      Option { $0.identifierEscapeSyntax = enabled }
    }

    /// Uses `@result` as the comprehension accumulator name (the default) instead of the legacy
    /// `__result__` (cel-go `EnableHiddenAccumulatorName`).
    public static func hiddenAccumulatorName(_ enabled: Bool) -> Option {
      Option { $0.hiddenAccumulatorName = enabled }
    }

    /// Rejects list and map literals whose elements have different types (cel-go
    /// `HomogeneousAggregateLiterals`).
    public static var homogeneousAggregateLiterals: Option {
      validators(.homogeneousAggregateLiterals)
    }

    /// Adds validators run on every checked expression (cel-go `ASTValidators`).
    public static func validators(_ validators: ExpressionValidator...) -> Option {
      self.validators(validators)
    }

    /// Adds validators run on every checked expression (cel-go `ASTValidators`).
    public static func validators(_ validators: [ExpressionValidator]) -> Option {
      Option { config in
        for validator in validators where !config.validators.contains(where: { $0.name == validator.name }) {
          config.validators.append(validator)
        }
      }
    }

    /// Program options applied to every program created from the environment, before the
    /// options passed to ``Environment/program(_:options:)-(CheckedExpression,_)``.
    public static func programOptions(_ options: Program.Option...) -> Option {
      Option { $0.programOptions += options }
    }

    // MARK: Limits

    /// Limits how deeply the parser descends; -1 removes the limit (cel-go
    /// `ParserRecursionLimit`, default 250).
    public static func parserRecursionLimit(_ limit: Int) -> Option {
      Option { $0.parserRecursionLimit = limit }
    }

    /// Limits the parser's error recovery attempts; -1 removes the limit (cel-go
    /// `ParserErrorRecoveryLimit`, default 30).
    public static func parserErrorRecoveryLimit(_ limit: Int) -> Option {
      Option { $0.parserErrorRecoveryLimit = limit }
    }

    /// Limits the expression size in code points; -1 removes the limit (cel-go
    /// `ParserExpressionSizeLimit`, default 100,000).
    public static func expressionSizeLimit(_ codePoints: Int) -> Option {
      Option { $0.expressionSizeCodePointLimit = codePoints }
    }

    /// Limits the number of expression nodes, including macro expansions; -1 removes the limit
    /// (cel-go `ExpressionNodeLimit`, default 100,000).
    public static func expressionNodeLimit(_ nodes: Int) -> Option {
      Option { $0.expressionNodeCountLimit = nodes }
    }

    /// Limits the compiled program size of regular expressions, in instructions (cel-go
    /// `RegexProgramSizeLimit`): pattern literals are rejected when the expression is checked,
    /// computed patterns when the call is evaluated. Zero or less removes the limit.
    public static func regexProgramSizeLimit(_ instructions: Int) -> Option {
      Option {
        $0.regexProgramSizeLimit = instructions
        if instructions > 0 {
          $0.validators.append(.regexProgramSizeLimit(instructions))
        }
      }
    }
  }
}

extension Library {
  /// The CEL standard library: operators, functions, conversions, type identifiers and the
  /// standard macros (cel-go `StdLib`).
  public static let standard = Library(
    name: "cel.lib.std", alias: "stdlib", functions: StandardLibrary.functions,
    variables: StandardLibrary.types, macros: Macro.allMacros)

  /// The optional types library (cel-go `OptionalTypes`).
  ///
  /// - Parameter version: The library version; version 1 adds `optFlatMap`, version 2 `first`,
  ///   `last`, `optional.unwrap` and `unwrapOpt`.
  public static func optionalTypes(version: UInt32 = Library.latestVersion) -> Library {
    var library = Library(
      name: "cel.lib.optional", alias: "optional", version: version,
      functions: OptionalLibrary.functions(version: version), variables: OptionalLibrary.types,
      types: [.optionalOfDyn], macros: OptionalLibrary.macros(version: version))
    library.parserOptions = [.enableOptionalSyntax(true)]
    library.decorators = [OptionalLibrary.decorator]
    return library
  }
}
