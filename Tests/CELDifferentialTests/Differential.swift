// A differential case, the cel-swift side of it, and the comparison with the oracle's answer.

import CEL
import CELExtensions
import Foundation

/// Whether to compare static and runtime costs of expressions that call extension library functions
/// (cel-swift ports cel-go's per-library cost estimators and trackers). `CEL_DIFF_EXTENSION_COSTS=0` leaves
/// them out, for work on the extension costs.
let compareExtensionCosts = ProcessInfo.processInfo.environment["CEL_DIFF_EXTENSION_COSTS"] != "0"

/// One generated case.
struct DiffCase: Sendable {
  var id: String
  var profile: Profile
  var root: Node
  var bindings: [(String, GValue)]
  var checked: Bool
  /// Extension names and versions (`latest` or a number).
  var extensions: [(String, String)]
  /// Attribute patterns evaluated as unknown, in the oracle's form.
  var unknowns: [JSON] = []
  var costLimit: UInt64?

  /// Source text replacing the rendered tree: a mutated expression that usually fails to parse.
  var textOverride: String?

  var expr: String { textOverride ?? root.rendered }

  /// Size hints for the static cost estimate: every sized variable is between 0 and 4 long.
  static func sizeHints(_ decls: [(String, GType)]) -> JSON {
    var hints: [(String, JSON)] = []
    for (name, type) in decls {
      switch type {
      case .string, .bytes, .list, .map:
        hints.append((name, .object([("min", .number("0")), ("max", .number("4"))])))
      default: break
      }
    }
    return .object(hints)
  }

  /// The oracle request; also everything the cel-swift side needs.
  var request: JSON {
    let decls = profile.declarations
    // Message variables go through decls_proto: the env config resolves variable types before any
    // extension registers the message types.
    let plain = decls.filter { if case .message = $0.1 { return false } else { return true } }
    let messageDecls: [JSON] = decls.compactMap { name, type in
      guard case .message(let m) = type else { return nil }
      return .object([("name", .string(name)), ("ident", .object([("type", .object([("message_type", .string(m))]))]))])
    }
    let config: JSON = .object([
      (
        "variables",
        .array(plain.map { name, type in .object([("name", .string(name))] + (type.typeDesc.objectValue ?? [])) })
      ),
      ("extensions", .array(extensions.map { .object([("name", .string($0.0)), ("version", .string($0.1))]) })),
    ])
    var fields: [(String, JSON)] = [
      ("id", .string(id)), ("kind", "eval"), ("expr", .string(expr)), ("config", config),
      ("bindings", .object(bindings.map { ($0.0, $0.1.json) })),
    ]
    if profile == .proto {
      fields.append(("container", .string(Messages.container)))
      fields.append(("test_types", true))
      fields.append(("decls_proto", .array(messageDecls)))
    }
    if checked {
      fields.append(("size_hints", Self.sizeHints(decls)))
    } else {
      fields.append(("check", false))
    }
    if !unknowns.isEmpty {
      fields.append(("unknowns", .array(unknowns)))
    }
    if let costLimit {
      fields.append(("cost_limit", .number(String(costLimit))))
    }
    if root.anyUsesExtension {
      fields.append(("uses_extensions", true))
    }
    return .object(fields)
  }

  /// The case generated for a seed and index.
  static func generate(seed: UInt64, index: Int) -> DiffCase {
    var mixer = SeededRandom(seed: seed &* 0x2545_F491_4F6C_DD1D &+ UInt64(index))
    let caseSeed = mixer.next()
    var pick = SeededRandom(seed: caseSeed ^ 0xA5A5)
    let profile: Profile = [.full, .std, .versioned, .proto][pick.weighted([60, 15, 10, 15])]
    let checked = pick.chance(85)
    var extensions: [(String, String)] = []
    switch profile {
    case .full: extensions = Profile.extensionVersions.map { ($0.0, "latest") }
    case .std: break
    case .versioned: extensions = Profile.extensionVersions.map { ($0.0, String(pick.range(0, $0.1))) }
    case .proto: extensions = Profile.extensionVersions.map { ($0.0, "latest") }
    }
    var generator = Generator(seed: caseSeed, profile: profile)
    let (root, bindings) = generator.makeCase()
    var c = DiffCase(
      id: "s\(seed)-c\(index)", profile: profile, root: root, bindings: bindings, checked: checked,
      extensions: extensions)
    if pick.chance(10) {
      // Partial evaluation: one or two attribute patterns over the declared variables.
      for _ in 0..<pick.range(1, 2) {
        let (name, type) = pick.pick(profile.declarations)
        var path: [JSON] = []
        switch type {
        case .map(.string, _) where pick.chance(60):
          path.append(pick.chance(20) ? "*" : GValue.string(pick.pick(Generator.mapKeys)).json)
        case .map(.int, _) where pick.chance(60), .list where pick.chance(60):
          path.append(GValue.int(Int64(pick.range(0, 2))).json)
        case .map(.bool, _) where pick.chance(60):
          path.append(GValue.bool(pick.chance(50)).json)
        default: break
        }
        c.unknowns.append(.object([("variable", .string(name)), ("path", .array(path))]))
      }
    }
    if pick.chance(4) {
      // Syntax errors: delete, duplicate or insert one character, to compare parser error messages.
      var scalars = Array(c.expr.unicodeScalars)
      let at = pick.below(scalars.count + 1)
      let inserts: [Unicode.Scalar] = [
        "(", ")", "[", "]", "{", "}", ".", ",", "?", ":", "!", "\"", "'", "`", "&", "|", "-", "@", "#", "\\", "1", "a",
        " ",
      ]
      switch pick.below(3) {
      case 0 where at < scalars.count: scalars.remove(at: at)
      case 1 where at < scalars.count: scalars.insert(scalars[at], at: at)
      default: scalars.insert(pick.pick(inserts), at: at)
      }
      var text = ""
      text.unicodeScalars.append(contentsOf: scalars)
      c.textOverride = text
    }
    if !root.anyUsesExtension && pick.chance(10) {
      // A cost limit somewhere around the cost of a typical case.
      c.costLimit = UInt64(pick.range(0, 120))
    }
    return c
  }
}

/// What one implementation answered for a case, in comparable form.
struct Outcome: Sendable, Equatable {
  var harnessError: String?
  var compileError: String?
  var type: String?
  var estimate: String?
  var value: String?
  var evalError: String?
  var cost: UInt64?

  init(oracle r: JSON) {
    harnessError = r["oracle_error"]?.stringValue
    compileError = r["error"]?.stringValue
    type = r["type"]?.stringValue
    if let e = r["cost_estimate"] {
      estimate = "\(e["min"]?.uint64Value ?? 0)..\(e["max"]?.uint64Value ?? 0)"
    }
    if let result = r["result"] {
      if let v = result["value"] {
        value = Codec.canonical(json: v)
      } else if let e = result["error"]?.stringValue {
        evalError = e
      } else if let ids = result["unknown"]?.arrayValue {
        value =
          "unknown:"
          + ids.map { id -> String in if case .number(let n) = id { return n } else { return id.rendered } }
          .joined(separator: ",")
      } else {
        evalError = "unknown result \(result.rendered)"
      }
    }
    cost = r["cost"]?.uint64Value
  }

  init() {}

  /// The oracle response fields a regression entry keeps.
  static func stripped(_ r: JSON) -> JSON {
    var fields: [(String, JSON)] = []
    for key in ["oracle_error", "error", "type", "cost_estimate", "result", "cost"] {
      if let v = r[key] { fields.append((key, v)) }
    }
    return .object(fields)
  }
}

/// A difference between the two outcomes.
struct Mismatch: Sendable, CustomStringConvertible {
  enum Category: String, Sendable, CaseIterable, Comparable {
    case harness, compile, type, estimate, kind, value, error, cost

    static func < (a: Category, b: Category) -> Bool {
      allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
  }

  var category: Category
  var oracle: String
  var swift: String

  var description: String { "\(category.rawValue): cel-go \(oracle) | cel-swift \(swift)" }

  /// Cases not compared, by the answer of cel-go (first) and cel-swift (second).
  static let divergences: [(reason: String, matches: @Sendable (Outcome, Outcome) -> Bool)] = [
    // docs/divergences.md: cel-go lets a repeated key overwrite the earlier entry.
    ("map literals reject repeated keys", { _, s in s.evalError?.hasPrefix("Failed with repeated key") ?? false }),
    // docs/divergences.md: an `indexOf` / `lastIndexOf` offset past the end of the string is an error (spec),
    // where cel-go returns -1 or the string length and evaluation goes on (to a value or another error).
    // charAt and substring report the same message in both, so equal errors are still compared.
    (
      "string offsets past the end are errors",
      { o, s in
        guard let e = s.evalError, e.hasPrefix("index out of range: ") else { return false }
        return o.evalError != e
      }
    ),
    // docs/divergences.md: cel-go accepts any value as a map literal key (parse-only expressions).
    ("map literals reject non-key types", { _, s in s.evalError?.hasPrefix("unsupported key type") ?? false }),
    // cel-go panics (recovered as `internal error: interface conversion ...`) in the runtime cost trackers of
    // ext/lists.go `distinct` and `sort`, which cast their argument to a list without checking for an error.
    ("cel-go panics", { o, _ in o.evalError?.hasPrefix("internal error: ") ?? false }),
    // cel-go sets message literal fields from a Go map, in random order, so which of two bad fields is reported
    // varies; reruns rarely find cel-swift's (declaration) order.
    (
      "message field order",
      { o, s in
        let prefix = "field type conversion error for "
        return (o.evalError?.hasPrefix(prefix) ?? false) && (s.evalError?.hasPrefix(prefix) ?? false)
      }
    ),
    // A null read from an unset wrapper field is a structpb.NullValue in cel-go, a types.Null when written as a
    // literal; cel-swift has one null and names it types.Null in error messages.
    (
      "null from a wrapper field",
      { o, s in
        guard let e = o.evalError, e.contains("structpb.NullValue") else { return false }
        return s.evalError == e.replacingOccurrences(of: "structpb.NullValue", with: "types.Null")
      }
    ),
  ]

  /// Checked types equal up to the documented join of null and wrapper element types (docs/divergences.md:
  /// cel-swift joins `[1, msg.single_int64_wrapper]` to `list(wrapper(int))` and `[msg, null]` to `msg`'s type,
  /// where cel-go's `mostGeneral` picks the primitive or `null`).
  static func typesEquivalent(_ o: String?, _ s: String?) -> Bool {
    guard let o, let s else { return o == s }
    if o == s { return true }
    func unwrapped(_ t: String) -> String {
      var t = t
      while let r = t.range(of: "wrapper(") {
        guard let close = t[r.upperBound...].firstIndex(of: ")") else { break }
        t.replaceSubrange(close...close, with: "")
        t.replaceSubrange(r, with: "")
      }
      return t
    }
    return unwrapped(o) == unwrapped(s) || o.contains("null")
  }

  static func divergence(_ o: Outcome, _ s: Outcome) -> String? {
    divergences.first { $0.matches(o, s) }?.reason
  }

  static func compare(oracle o: Outcome, swift s: Outcome, usesExtensions: Bool) -> [Mismatch] {
    var out: [Mismatch] = []
    if divergence(o, s) != nil { return [] }
    func show(_ v: Any?) -> String { v.map { "\($0)" } ?? "nil" }
    if o.harnessError != nil || s.harnessError != nil {
      return [Mismatch(category: .harness, oracle: show(o.harnessError), swift: show(s.harnessError))]
    }
    if o.compileError != s.compileError {
      return [Mismatch(category: .compile, oracle: show(o.compileError), swift: show(s.compileError))]
    }
    if o.compileError != nil { return [] }
    if !typesEquivalent(o.type, s.type) {
      out.append(Mismatch(category: .type, oracle: show(o.type), swift: show(s.type)))
    }
    let costs = compareExtensionCosts || !usesExtensions
    if costs && o.estimate != s.estimate {
      out.append(Mismatch(category: .estimate, oracle: show(o.estimate), swift: show(s.estimate)))
    }
    if (o.value == nil) != (s.value == nil) {
      out.append(
        Mismatch(
          category: .kind, oracle: o.value ?? "error: " + show(o.evalError),
          swift: s.value ?? "error: " + show(s.evalError)))
    } else if o.value != s.value {
      out.append(Mismatch(category: .value, oracle: show(o.value), swift: show(s.value)))
    } else if o.evalError != s.evalError {
      out.append(Mismatch(category: .error, oracle: show(o.evalError), swift: show(s.evalError)))
    }
    if costs && o.cost != s.cost {
      out.append(Mismatch(category: .cost, oracle: show(o.cost), swift: show(s.cost)))
    }
    return out
  }
}

/// Runs requests with cel-swift through its public API, caching environments by configuration.
struct SwiftSide {
  private var environments: [String: Result<Environment, DeclarationError>] = [:]

  static func library(_ ext: JSON) throws -> Library {
    let name = ext["name"]?.stringValue ?? ""
    let versionText = ext["version"]?.stringValue ?? "0"
    let version: UInt32 = versionText == "latest" ? Library.latestVersion : UInt32(versionText) ?? 0
    switch name {
    case "optional": return .optionalTypes(version: version)
    case "strings": return .strings(version: version)
    case "math": return .math(version: version)
    case "lists": return .lists(version: version)
    case "sets": return .sets(version: version)
    case "encoders": return .encoders(version: version)
    case "bindings": return .bindings(version: version)
    case "two-var-comprehensions": return .twoVarComprehensions(version: version)
    case "regex": return .regex(version: version)
    case "network": return .network
    default: throw CodecError(description: "unknown extension \(name)")
    }
  }

  mutating func environment(_ request: JSON) throws -> Environment {
    let config = request["config"] ?? .object([])
    let container = request["container"]?.stringValue
    let testTypes = request["test_types"]?.boolValue ?? false
    let declsProto = request["decls_proto"]?.arrayValue ?? []
    let key = config.rendered + (container ?? "") + "\(testTypes)" + JSON.array(declsProto).rendered
    if let cached = environments[key] {
      return try cached.get()
    }
    var options: [Environment.Option] = []
    for v in config["variables"]?.arrayValue ?? [] {
      options.append(.variable(v["name"]?.stringValue ?? "", try Codec.celType(v)))
    }
    for ext in config["extensions"]?.arrayValue ?? [] {
      options.append(.library(try Self.library(ext)))
    }
    if testTypes {
      options.append(.typeProvider(TypeRegistry(composing: Messages.types, adapter: Messages.types)))
    }
    if let container {
      options.append(.container(container))
    }
    for decl in declsProto {
      guard let name = decl["name"]?.stringValue, let message = decl["ident"]?["type"]?["message_type"]?.stringValue
      else {
        throw CodecError(description: "unsupported decls_proto entry \(decl.rendered)")
      }
      options.append(.variable(name, .object(message)))
    }
    let result: Result<Environment, DeclarationError>
    do {
      result = .success(try Environment(options: options))
    } catch {
      result = .failure(error)
    }
    environments[key] = result
    return try result.get()
  }

  /// A program-creation failure. cel-go's `Env.Program` returns a plain error, which the oracle reports as
  /// `err.Error()`; cel-swift throws a ``CompileError`` whose description renders its issue as a location-less
  /// `ERROR: <input>:-1:0: ...`. The comparison uses the messages.
  struct ProgramError: Error, CustomStringConvertible {
    var description: String
  }

  private func makeProgram(_ env: Environment, expression: CheckedExpression, options: [Program.Option]) throws
    -> Program
  {
    do {
      return try env.program(expression, options: options)
    } catch {
      throw ProgramError(description: error.issues.map(\.message).joined(separator: "\n"))
    }
  }

  private func makeProgram(_ env: Environment, parsed: ParsedExpression, options: [Program.Option]) throws -> Program {
    do {
      return try env.program(parsed, options: options)
    } catch {
      throw ProgramError(description: error.issues.map(\.message).joined(separator: "\n"))
    }
  }

  /// `CEL_DIFF_TRACE=path`: each request is written there before cel-swift runs it, so the case behind a
  /// crash is the file's content (use with `CEL_DIFF_WORKERS=1`).
  static let tracePath = ProcessInfo.processInfo.environment["CEL_DIFF_TRACE"]

  mutating func run(_ request: JSON) -> Outcome {
    if let path = Self.tracePath {
      // Appends, so a crash that depends on earlier cases can be replayed in order.
      if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data((request.rendered + "\n").utf8))
        handle.closeFile()
      } else {
        try? Data((request.rendered + "\n").utf8).write(to: URL(fileURLWithPath: path))
      }
    }
    var outcome = Outcome()
    let env: Environment
    var bindings: [String: Value] = [:]
    var hints: [String: ClosedRange<UInt64>] = [:]
    do {
      env = try environment(request)
      for (name, v) in request["bindings"]?.objectValue ?? [] {
        bindings[name] = try Codec.value(v)
      }
      for (name, h) in request["size_hints"]?.objectValue ?? [] {
        hints[name] = (h["min"]?.uint64Value ?? 0)...(h["max"]?.uint64Value ?? 0)
      }
    } catch {
      outcome.harnessError = "\(error)"
      return outcome
    }
    let text = request["expr"]?.stringValue ?? ""
    let checked = request["check"]?.boolValue ?? true
    var programOptions: [Program.Option] = [.trackCost, .errorsAsValues]
    var unknowns: [UnknownPattern] = []
    do {
      for u in request["unknowns"]?.arrayValue ?? [] {
        var pattern = UnknownPattern(u["variable"]?.stringValue ?? "")
        for q in u["path"]?.arrayValue ?? [] {
          if q == "*" {
            pattern = pattern.wildcard()
            continue
          }
          switch try Codec.value(q) {
          case .string(let s): pattern = pattern.qualified(by: .string(s))
          case .int(let i): pattern = pattern.qualified(by: .int(i))
          case .uint(let u): pattern = pattern.qualified(by: .uint(u))
          case .bool(let b): pattern = pattern.qualified(by: .bool(b))
          default: throw CodecError(description: "bad qualifier \(q.rendered)")
          }
        }
        unknowns.append(pattern)
      }
    } catch {
      outcome.harnessError = "\(error)"
      return outcome
    }
    if !unknowns.isEmpty { programOptions.append(.partialEvaluation) }
    if let limit = request["cost_limit"]?.uint64Value { programOptions.append(.costLimit(limit)) }
    let program: Program
    do {
      if checked {
        let expression = try env.compile(text)
        outcome.type = expression.outputType.checkerDescription
        let estimate = env.estimateCost(expression, sizeHints: hints)
        outcome.estimate = "\(estimate.lowerBound)..\(estimate.upperBound)"
        program = try makeProgram(env, expression: expression, options: programOptions)
      } else {
        program = try makeProgram(env, parsed: try env.parse(text), options: programOptions)
      }
    } catch {
      outcome.compileError = "\(error)"
      return outcome
    }
    do {
      let result = try program.evaluate(Variables(bindings, unknowns: unknowns))
      if case .error(let e) = result.value {
        outcome.evalError = e.message
      } else {
        outcome.value = Codec.canonical(result.value)
      }
      outcome.cost = result.cost
    } catch {
      outcome.evalError = error.message
    }
    return outcome
  }
}
