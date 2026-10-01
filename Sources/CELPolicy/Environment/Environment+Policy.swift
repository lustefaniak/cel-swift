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

// The parts of cel-go cel/env.go the policy compiler uses (CompileSource, Check and Extend with
// errors as issues), on the public `Environment`, and cel-go `cel.StdLib(StdLibSubset(...))`.

import CEL

extension Environment {
  /// Parses and type-checks a source, returning the errors instead of throwing them
  /// (cel-go `Env.CompileSource`).
  func compileSource(_ source: any Source) -> (ast: AST?, errors: CELErrors) {
    do {
      let parsed = try parse(source: source)
      let checked = try check(parsed)
      return (checked.ast, CELErrors(source: source))
    } catch {
      return (nil, error.errors)
    }
  }

  /// Type-checks a parsed AST, returning the errors instead of throwing them (cel-go `Env.Check`).
  func checkAST(_ ast: AST, source: any Source) -> (ast: AST?, errors: CELErrors) {
    do {
      let checked = try check(ParsedExpression(ast: ast, source: source))
      return (checked.ast, CELErrors(source: source))
    } catch {
      return (nil, error.errors)
    }
  }

  /// Declares variables (cel-go `Env.Extend(cel.Variable(...))`).
  func declaring(_ variables: [VariableDecl]) throws(DeclarationError) -> Environment {
    try extending(.variables(variables))
  }
}

/// An error building or extending an environment from a config, with cel-go's message.
package struct EnvironmentError: Error, Sendable, CustomStringConvertible {
  package var description: String

  package init(_ description: String) {
    self.description = description
  }
}

extension Library {
  /// The standard library restricted to a subset (cel-go `cel.StdLib(StdLibSubset(...))`).
  package static func standard(subset: EnvironmentConfig.LibrarySubset) -> Library {
    var functions: [FunctionDecl] = []
    for fn in StandardLibrary.functions {
      if let kept = subset.subsetFunction(fn) {
        functions.append(kept)
      }
    }
    return Library(
      name: "cel.lib.std", alias: "stdlib", functions: functions, variables: StandardLibrary.types,
      macros: Macro.allMacros.filter { subset.includesMacro($0.function) })
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
