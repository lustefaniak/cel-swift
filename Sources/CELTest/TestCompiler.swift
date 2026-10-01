// Copyright 2025 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Ported from cel-go tools/compiler/compiler.go (NewCompiler, CreateEnv, EnvironmentFile,
// InferFileFormat, FileExpression, RawExpression, PolicyMetadataEnvOption).
//
// Not ported: binary and textproto environments, checked-expression files and file descriptor
// sets; types come from the environment's type provider.

import CEL
import CELPolicy

/// Builds the environment for `celtest`-style runs and compiles expressions, `.cel` files and
/// policies in it (cel-go `tools/compiler`).
public struct TestCompiler: Sendable {
  /// The environment: a custom environment with the configs, the extra options, optional types
  /// and the bindings library.
  public let environment: Environment
  /// Parses policy files.
  public var policyParser: PolicyParser
  /// Compiles policies.
  public var policyCompiler: PolicyCompiler
  /// Options derived from a parsed policy's metadata, applied before compiling it
  /// (cel-go `PolicyMetadataEnvOption`).
  public var policyMetadataOptions: [@Sendable ([String: any Sendable]) -> [Environment.Option]]

  /// Creates a compiler.
  ///
  /// - Parameters:
  ///   - environmentConfigs: Environment configs applied in order, such as a base config and a
  ///     config (cel-go `EnvironmentFile`).
  ///   - options: Additional environment options, such as function implementations.
  ///   - policyParser: The parser for policy files.
  ///   - policyCompiler: The compiler for policies.
  /// - Throws: ``TestRunnerError`` when the environment cannot be created.
  public init(
    environmentConfigs: [EnvironmentConfig] = [],
    options: [Environment.Option] = [],
    policyParser: PolicyParser = PolicyParser(),
    policyCompiler: PolicyCompiler = PolicyCompiler()
  ) throws(TestRunnerError) {
    var envOptions: [Environment.Option] = environmentConfigs.map { .environmentConfig($0) }
    envOptions += options
    // cel-go `extensionOpt`: optional types and bindings at their latest versions.
    var extensions = EnvironmentConfig()
    extensions.extensions = [
      EnvironmentConfig.Extension(name: "optional", version: "latest"),
      EnvironmentConfig.Extension(name: "bindings", version: "latest"),
    ]
    envOptions.append(.environmentConfig(extensions))
    do {
      environment = try Environment.custom(options: envOptions)
    } catch {
      throw TestRunnerError("\(error)")
    }
    self.policyParser = policyParser
    self.policyCompiler = policyCompiler
    self.policyMetadataOptions = []
  }

  /// The kind of input an expression argument names (cel-go `InferFileFormat`).
  public enum ExpressionKind: Sendable, Hashable {
    /// A `.cel` file holding an expression.
    case celFile
    /// A `.celpolicy` or `.yaml` policy file.
    case policyFile
    /// The argument is the expression itself.
    case raw
  }

  /// Infers what an expression argument is from its file extension.
  public static func kind(of argument: String) -> ExpressionKind {
    if argument.hasSuffixScalars(".cel") {
      return .celFile
    }
    if argument.hasSuffixScalars(".celpolicy") || argument.hasSuffixScalars(".yaml") {
      return .policyFile
    }
    return .raw
  }

  /// Compiles a raw expression (cel-go `RawExpression`).
  ///
  /// - Throws: ``TestRunnerError`` with the compile errors.
  public func compile(expression: String) throws(TestRunnerError) -> CheckedExpression {
    do {
      return try environment.compile(expression)
    } catch {
      throw TestRunnerError("e.Compile(\(goQuoted(expression))) failed: \(error)")
    }
  }

  /// Compiles the contents of a `.cel` file (cel-go `FileExpression` for `.cel`).
  ///
  /// - Throws: ``TestRunnerError`` with the compile errors.
  public func compile(celFile content: String, path: String) throws(TestRunnerError) -> CheckedExpression {
    do {
      return try environment.compile(content, sourceName: path)
    } catch {
      throw TestRunnerError("e.CompileSource(\(goQuoted(content))) failed: \(error)")
    }
  }

  /// Parses and compiles a policy file (cel-go `FileExpression` for `.celpolicy` / `.yaml`).
  ///
  /// - Throws: ``TestRunnerError`` with the parse or compile errors.
  public func compile(policyFile content: String, path: String) throws(TestRunnerError) -> CompiledPolicy {
    let source = PolicySource(content, description: path)
    let policy: Policy
    do {
      policy = try policyParser.parse(source)
    } catch {
      throw TestRunnerError("parser.Parse(\(goQuoted(content))) failed: \(error)")
    }
    var env = environment
    if !policyMetadataOptions.isEmpty {
      var metadata: [String: any Sendable] = [:]
      for key in policy.metadataKeys {
        metadata[key] = policy.metadata(forKey: key)
      }
      for make in policyMetadataOptions {
        do {
          env = try env.extending(options: make(metadata))
        } catch {
          throw TestRunnerError("e.Extend() with metadata option failed: \(error)")
        }
      }
    }
    do {
      return try policyCompiler.compile(policy, environment: env)
    } catch {
      throw TestRunnerError("policy.Compile(\(goQuoted(content))) failed: \(error)")
    }
  }
}

extension String {
  func hasSuffixScalars(_ suffix: String) -> Bool {
    unicodeScalars.reversed().starts(with: suffix.unicodeScalars.reversed())
  }
}
