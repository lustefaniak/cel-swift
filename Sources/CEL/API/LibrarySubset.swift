// Copyright 2025 Google LLC
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
// Ported from cel-go common/env/env.go (LibrarySubset: Validate, SubsetFunction, SubsetMacro) and
// cel/library.go (StdLibSubset, stdLibrary.CompileOptions). cel-go reports an invalid subset when
// the library option is applied; here the factory throws, so the error surfaces where the subset
// is built.

extension Library {
  /// A selection of a library's macros and functions, such as a standard library without
  /// comprehension macros (cel-go `env.LibrarySubset`).
  ///
  /// A subset either lists what to include or what to exclude, separately for macros and for
  /// functions; listing both for the same kind is an error. Functions are selected by name, and
  /// optionally narrowed to some of their overloads by overload identifier:
  ///
  /// ```swift
  /// let subset = Library.Subset(
  ///   includedMacros: ["has"],
  ///   includedFunctions: [
  ///     .init("_==_"),
  ///     .init("size", overloadIDs: ["list_size"]),
  ///   ])
  /// let env = try Environment.custom(.library(.standard(subset: subset)))
  /// ```
  public struct Subset: Sendable, Hashable {
    /// A function selected by name, optionally restricted to some of its overloads.
    public struct FunctionSelection: Sendable, Hashable {
      /// The function name, such as `size` or `_==_`.
      public var name: String

      /// The overload identifiers to select, such as `list_size`; empty selects the whole
      /// function.
      public var overloadIDs: [String]

      /// Creates a function selection.
      ///
      /// - Parameters:
      ///   - name: The function name.
      ///   - overloadIDs: The overload identifiers to select; empty selects every overload.
      public init(_ name: String, overloadIDs: [String] = []) {
        self.name = name
        self.overloadIDs = overloadIDs
      }
    }

    /// Whether the library is left out entirely.
    public var isDisabled: Bool

    /// Whether every macro of the library is left out.
    public var disablesMacros: Bool

    /// The macros to include, by function name such as `has` or `exists`; when non-empty, only
    /// these macros are included.
    public var includedMacros: [String]

    /// The macros to leave out, by function name.
    public var excludedMacros: [String]

    /// The functions to include; when non-empty, only these functions are included.
    public var includedFunctions: [FunctionSelection]

    /// The functions, or overloads of functions, to leave out.
    public var excludedFunctions: [FunctionSelection]

    /// Creates a subset; with the default arguments it includes the whole library.
    ///
    /// - Parameters:
    ///   - isDisabled: Whether to leave out the whole library.
    ///   - disablesMacros: Whether to leave out every macro.
    ///   - includedMacros: The macros to include; mutually exclusive with `excludedMacros`.
    ///   - excludedMacros: The macros to leave out.
    ///   - includedFunctions: The functions to include; mutually exclusive with
    ///     `excludedFunctions`.
    ///   - excludedFunctions: The functions or overloads to leave out.
    public init(
      isDisabled: Bool = false,
      disablesMacros: Bool = false,
      includedMacros: [String] = [],
      excludedMacros: [String] = [],
      includedFunctions: [FunctionSelection] = [],
      excludedFunctions: [FunctionSelection] = []
    ) {
      self.isDisabled = isDisabled
      self.disablesMacros = disablesMacros
      self.includedMacros = includedMacros
      self.excludedMacros = excludedMacros
      self.includedFunctions = includedFunctions
      self.excludedFunctions = excludedFunctions
    }

    /// Checks that the subset does not both include and exclude macros, or functions
    /// (cel-go `LibrarySubset.Validate`).
    ///
    /// - Throws: ``DeclarationError`` describing every conflict.
    public func validate() throws(DeclarationError) {
      var errors: [String] = []
      if !includedMacros.isEmpty && !excludedMacros.isEmpty {
        errors.append("invalid subset: cannot both include and exclude macros")
      }
      if !includedFunctions.isEmpty && !excludedFunctions.isEmpty {
        errors.append("invalid subset: cannot both include and exclude functions")
      }
      if !errors.isEmpty {
        throw DeclarationError(errors.joined(separator: "\n"))
      }
    }

    /// Whether the subset includes the macro with the given function name (cel-go
    /// `LibrarySubset.SubsetMacro`).
    ///
    /// - Parameter function: The macro's function name, such as `has` or `exists`.
    public func includesMacro(_ function: String) -> Bool {
      if isDisabled || disablesMacros {
        return false
      }
      if !includedMacros.isEmpty {
        return includedMacros.contains(function)
      }
      if !excludedMacros.isEmpty {
        return !excludedMacros.contains(function)
      }
      return true
    }

    /// The part of `function` the subset includes: the whole declaration, a declaration with
    /// fewer overloads, or `nil` when the function is left out (cel-go
    /// `LibrarySubset.SubsetFunction`).
    ///
    /// - Parameter function: A function declaration of the library being subset.
    public func subset(of function: FunctionDecl) -> FunctionDecl? {
      if isDisabled {
        return nil
      }
      if !includedFunctions.isEmpty {
        guard let include = includedFunctions.first(where: { $0.name == function.name }) else {
          return nil
        }
        return include.overloadIDs.isEmpty ? function : function.including(overloadIDs: include.overloadIDs)
      }
      if let exclude = excludedFunctions.first(where: { $0.name == function.name }) {
        return exclude.overloadIDs.isEmpty ? nil : function.excluding(overloadIDs: exclude.overloadIDs)
      }
      return function
    }
  }

  /// The standard library restricted to a subset of its macros and functions (cel-go
  /// `StdLib(StdLibSubset(subset))`).
  ///
  /// The library keeps the standard library's name, so an environment holds at most one of them:
  /// start from ``Environment/custom(_:)``, which has no standard library, rather than
  /// ``Environment/init(_:)``. A disabled subset produces a library without functions or macros.
  ///
  /// - Parameter subset: The macros and functions to keep.
  /// - Returns: The restricted standard library.
  /// - Throws: ``DeclarationError`` when the subset both includes and excludes macros, or
  ///   functions.
  public static func standard(subset: Subset) throws(DeclarationError) -> Library {
    try subset.validate()
    return Library(
      name: Library.standard.name, alias: Library.standard.alias,
      functions: Library.standard.functions.compactMap { subset.subset(of: $0) },
      variables: Library.standard.variables,
      macros: Library.standard.macros.filter { subset.includesMacro($0.function) })
  }
}
