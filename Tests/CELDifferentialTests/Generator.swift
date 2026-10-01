// A seeded, type-directed generator of CEL expressions over a fixed set of declared variables, with random
// bindings. Every production builds a `Node` whose static type is known, so the output type-checks unless a
// production deliberately leaves the typed subset (dyn wrapping, cross-type comparisons through dyn).
//
// The generator is deterministic: a case is a function of (seed, index) only. Its random number generator
// is SplitMix64 with its own range reduction, never the standard library's `random(in:using:)`, whose
// algorithm is not guaranteed stable across toolchains.

/// SplitMix64.
struct SeededRandom: RandomNumberGenerator {
  var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// A number in `0..<n`.
  mutating func below(_ n: Int) -> Int {
    precondition(n > 0)
    return Int(next() % UInt64(n))
  }

  mutating func range(_ lo: Int, _ hi: Int) -> Int {
    lo + below(hi - lo + 1)
  }

  mutating func chance(_ percent: Int) -> Bool {
    below(100) < percent
  }

  mutating func pick<T>(_ items: [T]) -> T {
    items[below(items.count)]
  }

  /// Picks an index by weight.
  mutating func pickIndex(_ count: Int) -> Int {
    below(count)
  }

  mutating func weighted(_ weights: [Int]) -> Int {
    let total = weights.reduce(0, +)
    var r = below(max(total, 1))
    for (i, w) in weights.enumerated() {
      if r < w { return i }
      r -= w
    }
    return weights.count - 1
  }
}

/// One generated expression node: a template of text and child slots, the static type and flags.
struct Node: Sendable {
  enum Piece: Sendable {
    case text(String)
    /// A child; `wrap` parenthesizes it when it is an operator expression.
    case child(Int, wrap: Bool)
  }

  var pieces: [Piece]
  var children: [Node]
  var type: GType
  /// An operator expression (or a negative literal) that needs parentheses as an operand.
  var isOperator = false
  /// Calls an extension library function or macro (whose costs cel-swift may not port yet).
  var usesExtension = false

  /// A node from a template where `%N` is child N parenthesized if needed and `$N` is child N as is.
  init(_ template: String, _ children: [Node] = [], _ type: GType, op: Bool = false, ext: Bool = false) {
    var pieces: [Piece] = []
    var text = ""
    // Without children the template is literal text (it may contain `%` or `$`).
    var chars = children.isEmpty ? [] : Array(template.unicodeScalars)[...]
    if children.isEmpty { text = template }
    while let c = chars.first {
      chars = chars.dropFirst()
      if c == "%" || c == "$", let d = chars.first, let digit = Int(String(d)) {
        chars = chars.dropFirst()
        if !text.isEmpty {
          pieces.append(.text(text))
          text = ""
        }
        pieces.append(.child(digit, wrap: c == "%"))
      } else {
        text.unicodeScalars.append(c)
      }
    }
    if !text.isEmpty { pieces.append(.text(text)) }
    self.pieces = pieces
    self.children = children
    self.type = type
    self.isOperator = op
    self.usesExtension = ext
  }

  var rendered: String {
    var out = ""
    render(into: &out)
    return out
  }

  func render(into out: inout String) {
    for piece in pieces {
      switch piece {
      case .text(let t): out += t
      case .child(let i, let wrap):
        let child = children[i]
        if wrap && child.isOperator {
          out += "("
          child.render(into: &out)
          out += ")"
        } else {
          child.render(into: &out)
        }
      }
    }
  }

  var anyUsesExtension: Bool {
    usesExtension || children.contains { $0.anyUsesExtension }
  }

  var size: Int {
    1 + children.reduce(0) { $0 + $1.size }
  }
}

/// The environment a case is generated for.
enum Profile: String, Sendable {
  /// The standard library and every extension the generator samples, at their latest versions.
  case full
  /// The standard library only.
  case std
  /// Like `full`, with each extension at a random version (functions it lacks fail to compile).
  case versioned
  /// Like `full`, plus the conformance TestAllTypes messages in the `cel.expr.conformance` container.
  case proto

  /// The extensions of `full` and the highest version cel-go v0.32.0 defines for each, in the order they are
  /// applied.
  static let extensionVersions: [(String, Int)] = [
    ("optional", 2), ("strings", 5), ("math", 3), ("lists", 3), ("sets", 2), ("encoders", 2), ("bindings", 2),
    ("two-var-comprehensions", 2), ("regex", 2), ("network", 0),
  ]

  var declarations: [(String, GType)] {
    var decls: [(String, GType)] = [
      ("i", .int), ("j", .int), ("u", .uint), ("d", .double), ("s", .string), ("t", .string), ("by", .bytes),
      ("b", .bool), ("du", .duration), ("ts", .timestamp), ("li", .list(.int)), ("ls", .list(.string)),
      ("ld", .list(.double)), ("lli", .list(.list(.int))), ("msi", .map(.string, .int)),
      ("mis", .map(.int, .string)), ("mss", .map(.string, .string)), ("mbl", .map(.bool, .list(.uint))),
      ("x", .dyn), ("nul", .null),
    ]
    if self != .std {
      decls += [("oi", .optional(.int)), ("os", .optional(.string)), ("lo", .list(.optional(.int)))]
    }
    if self == .proto {
      decls += [
        ("m3", .message("cel.expr.conformance.proto3.TestAllTypes")),
        ("m2", .message("cel.expr.conformance.proto2.TestAllTypes")),
      ]
    }
    return decls
  }
}

/// Productions the generator leaves out, each because of an open cel-swift mismatch listed in
/// `docs/status.md`. Remove an entry when its bug is fixed.
enum KnownGaps {
  static let disabled: Set<String> = []
}

struct Generator {
  var rng: SeededRandom
  let profile: Profile
  let decls: [(String, GType)]
  var scope: [(String, GType)] = []
  var counter = 0
  var comprehensionDepth = 0
  /// The runtime type of each `dyn` variable's binding, so it can stand in for that type.
  var dynTypes: [String: GType] = [:]

  init(seed: UInt64, profile: Profile) {
    self.rng = SeededRandom(seed: seed)
    self.profile = profile
    self.decls = profile.declarations
  }

  var full: Bool { profile != .std }
  var messages: Bool { profile == .proto }

  static let messageNames: [String] = [
    "cel.expr.conformance.proto3.TestAllTypes", "cel.expr.conformance.proto2.TestAllTypes",
    "cel.expr.conformance.proto3.TestAllTypes.NestedMessage", "cel.expr.conformance.proto3.NestedTestAllTypes",
    "cel.expr.conformance.proto2.TestAllTypes.NestedMessage", "cel.expr.conformance.proto2.NestedTestAllTypes",
  ]

  static func enabled(_ name: String) -> Bool {
    !KnownGaps.disabled.contains(name)
  }

  // MARK: Pools

  static let ints: [Int64] = [
    0, 1, -1, 2, 3, 5, 7, 10, 42, -42, 100, 255, 1000, 65536, 2_147_483_647, -2_147_483_648, 4_294_967_296,
    .max, .min, .max - 1, .min + 1, 1_000_000_007,
  ]
  static let uints: [UInt64] = [0, 1, 2, 3, 7, 10, 42, 255, 1000, 4_294_967_295, .max, .max - 1, 1 << 63]
  static let doubles: [Double] = [
    0, -0.0, 0.5, 1, -1, 1.5, -2.25, 3.141592653589793, 1e10, 1e-10, 1e100, -1e300, 1.7976931348623157e308,
    5e-324, 0.1, 2.5, 100, 9_007_199_254_740_994, 1e19, -9.3e18, 1.8446744073709552e19, 0.3, 123.456,
    -0.5, 2.5e-7,
  ]
  static let specialDoubles: [Double] = [.nan, .infinity, -.infinity]
  static let strings: [String] = [
    "", "a", "b", "abc", "foo", "bar", "Hello, World", "héllo", "日本語", "😀x", "a b c", "  pad  ", "a,b,c",
    "123", "-42", "3.5", "true", "foo.bar", "\n", "\\", "\"q\"", "αβγ", "ABC", "1h30m", "aaa", "AbC dEf",
    "ﬀ", "Ǆ", "x\u{0}y", "tab\there", "1e3", "0x1F", "  ", "abcabc", "c",
  ]
  static let mapKeys: [String] = ["a", "b", "c", "foo", "bar", ""]
  static let bytePools: [[UInt8]] = [
    [], [0x61], [0x61, 0x62, 0x63], [0xff, 0x00], [0x00], Array("héllo".utf8), [0xc3, 0x28], [0x80],
    Array("日本".utf8), [0x7f, 0xfe, 0x01],
  ]
  static let durations: [String] = [
    "0s", "1s", "-1s", "1.5s", "100ms", "1us", "1µs", "1ns", "90m", "1h", "-2h45m", "24h", "1h30m15.25s",
    "0.000000001s", "-0.5s", "3600s", "2562047h", "-2562047h", "8760h", "59m59s",
  ]
  static let durationNanos: [Int64] = [
    0, 1, 1000, 1_000_000, 1_000_000_000, 90_000_000_000, 3_600_000_000_000, -1_000_000_000, -1_500_000_000,
    86_400_000_000_000, .max, .min + 1, 1_234_567_891,
  ]
  static let timestamps: [String] = [
    "2009-02-13T23:31:30Z", "1970-01-01T00:00:00Z", "2024-02-29T12:00:00.123456789Z", "0001-01-01T00:00:00Z",
    "9999-12-31T23:59:59.999999999Z", "2020-06-15T08:30:00+02:00", "1969-12-31T23:59:59.5Z",
    "2000-01-01T00:00:00-08:00", "2023-12-31T23:59:60Z", "2021-03-14T01:59:59.999Z",
  ]
  static let timestampSeconds: [Int64] = [
    0, 1_234_567_890, -1, 253_402_300_799, -62_135_596_800, 1_709_208_000, 951_782_400, 1_600_000_000,
    -86_400, 4_102_444_800,
  ]
  static let timeZones: [String] = [
    "UTC", "America/Los_Angeles", "Europe/Warsaw", "Asia/Kolkata", "+01:00", "-08:30", "02:00",
    "Australia/Lord_Howe", "Invalid/Zone", "Asia/Kathmandu", "America/St_Johns", "-00:00", "Z",
  ]
  static let regexes: [String] = [
    "a", "[0-9]+", "(a)(b)?", "^.", "b*", "(\\w+)", "x|y", "[aeiou]", "^$", ".*", "(?i)abc", "\\d", "a{2,}",
    "(", "[",
  ]
  static let typeNames: [String] = [
    "int", "uint", "double", "string", "bytes", "bool", "list", "map", "null_type", "type",
    "google.protobuf.Duration", "google.protobuf.Timestamp",
  ]

  // MARK: Literals

  static func quote(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\t": out += "\\t"
      case "\r": out += "\\r"
      default:
        if scalar.value < 0x20 || scalar.value == 0x7f {
          out += "\\x" + String(format2: scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out + "\""
  }

  static func bytesLiteral(_ b: [UInt8]) -> String {
    var out = "b\""
    for byte in b {
      if byte >= 0x20 && byte < 0x7f && byte != UInt8(ascii: "\"") && byte != UInt8(ascii: "\\") {
        out.unicodeScalars.append(Unicode.Scalar(byte))
      } else {
        out += "\\x" + String(format2: UInt32(byte))
      }
    }
    return out + "\""
  }

  static func doubleLiteral(_ d: Double) -> Node {
    if d.isNaN { return Node("double(\"NaN\")", [], .double) }
    if d.isInfinite { return Node(d < 0 ? "double(\"-Infinity\")" : "double(\"Infinity\")", [], .double) }
    var text = "\(d)"
    if !text.contains(".") && !text.contains("e") { text += ".0" }
    return Node(text, [], .double, op: text.hasPrefix("-"))
  }

  mutating func intLiteral() -> Node {
    let v: Int64 = rng.chance(60) ? rng.pick(Self.ints) : Int64(rng.range(-20, 20))
    return Node("\(v)", [], .int, op: v < 0)
  }

  mutating func smallInt(_ depth: Int) -> Node {
    if depth > 1 && rng.chance(20) { return gen(.int, depth - 1) }
    let v = rng.range(-1, 6)
    return Node("\(v)", [], .int, op: v < 0)
  }

  static let ips: [String] = [
    "192.168.0.1", "10.0.0.1", "127.0.0.1", "::1", "2001:db8::1", "fe80::1", "0.0.0.0", "::", "::ffff:192.168.0.1",
    "256.1.1.1", "1.2.3", "192.168.0.1%eth0", "2001:DB8::1", "01.2.3.4", "224.0.0.1", "ff02::1", "169.254.1.1",
    "8.8.8.8", "",
  ]
  static let cidrs: [String] = [
    "192.168.0.0/24", "10.0.0.0/8", "::1/128", "2001:db8::/32", "192.168.0.1/24", "0.0.0.0/0", "1.2.3.4/33",
    "abc/12", "::ffff:10.0.0.0/104", "127.0.0.1/32", "fe80::/10", "10.0.0.0/08", "::/0", "192.168.1.0/24",
  ]

  /// An IP address or CIDR string for the network extension: mostly literals (valid and invalid), sometimes
  /// computed.
  mutating func ipString(_ depth: Int, cidr: Bool) -> Node {
    if depth > 1 && rng.chance(15) { return gen(.string, depth - 1) }
    return Node(Self.quote(rng.pick(cidr ? Self.cidrs : Self.ips)), [], .string)
  }

  /// A list index, mostly 0 or 1 so lookups usually succeed.
  mutating func index(_ depth: Int) -> Node {
    if rng.chance(80) { return Node(rng.chance(60) ? "0" : "1", [], .int) }
    return smallInt(depth)
  }

  mutating func stringLiteral(_ s: String) -> Node {
    if rng.chance(10), !s.contains("\""), !s.contains("\n"), !s.contains("\\"), !s.contains("\r"),
      !s.unicodeScalars.contains(where: { $0.value < 0x20 })
    {
      return Node("r" + Self.quote(s), [], .string)
    }
    if rng.chance(10), !s.contains("'"), !s.contains("\\"), !s.unicodeScalars.contains(where: { $0.value < 0x20 }) {
      return Node("'" + s + "'", [], .string)
    }
    return Node(Self.quote(s), [], .string)
  }

  mutating func literal(_ t: GType, _ depth: Int) -> Node {
    switch t {
    case .int: return intLiteral()
    case .uint:
      let v: UInt64 = rng.chance(60) ? rng.pick(Self.uints) : UInt64(rng.range(0, 30))
      return Node("\(v)u", [], .uint)
    case .double:
      if rng.chance(5) { return Self.doubleLiteral(rng.pick(Self.specialDoubles)) }
      return Self.doubleLiteral(rng.chance(70) ? rng.pick(Self.doubles) : Double(rng.range(-100, 100)) / 4)
    case .string: return stringLiteral(rng.chance(30) ? rng.pick(Self.mapKeys) : rng.pick(Self.strings))
    case .bytes:
      if rng.chance(15) {
        return Node("B" + String(Self.bytesLiteral(rng.pick(Self.bytePools)).dropFirst()), [], .bytes)
      }
      return Node(Self.bytesLiteral(rng.pick(Self.bytePools)), [], .bytes)
    case .bool: return Node(rng.chance(50) ? "true" : "false", [], .bool)
    case .null: return Node("null", [], .null)
    case .duration: return Node("duration(\(Self.quote(rng.pick(Self.durations))))", [], .duration)
    case .timestamp:
      if rng.chance(25) {
        return Node("timestamp(\(rng.pick(Self.timestampSeconds)))", [], .timestamp)
      }
      return Node("timestamp(\(Self.quote(rng.pick(Self.timestamps))))", [], .timestamp)
    case .dyn:
      let inner = randomType(scalarOnly: true)
      return Node("dyn($0)", [literal(inner, depth)], .dyn)
    case .list(let e):
      let n = rng.range(0, 3)
      var kids: [Node] = []
      var parts: [String] = []
      for k in 0..<n {
        if full && e != .dyn && rng.chance(10) {
          kids.append(depth > 0 ? gen(.optional(e), depth - 1) : literal(.optional(e), 0))
          parts.append("?$\(k)")
        } else {
          // A list(dyn) literal holds elements of different types.
          let et = e == .dyn ? randomType(nesting: 1) : e
          kids.append(depth > 0 ? gen(et, depth - 1) : literal(et, 0))
          parts.append("$\(k)")
        }
      }
      return Node("[" + parts.joined(separator: ", ") + "]", kids, t)
    case .map(let k, let v):
      let n = rng.range(0, 3)
      var kids: [Node] = []
      var parts: [String] = []
      var keys: [String] = []
      for _ in 0..<n {
        // Distinct literal keys: cel-swift rejects repeated keys where cel-go overwrites (docs/divergences.md).
        // Computed keys can still repeat; those cases are skipped as a documented divergence.
        let key: Node
        let identity: String
        if rng.chance(80) || depth <= 0 {
          (key, identity) = keyLiteral(k)
        } else {
          let computed = gen(k, depth - 1)
          if computed.children.isEmpty {
            // A literal or variable: literals go through keyLiteral so equal values share an identity.
            (key, identity) = keyLiteral(k)
          } else {
            key = computed
            identity = "expr:" + key.rendered
          }
        }
        if keys.contains(identity) { continue }
        keys.append(identity)
        let i = keys.count - 1
        kids.append(key)
        if full && rng.chance(10) {
          kids.append(depth > 0 ? gen(.optional(v), depth - 1) : literal(.optional(v), 0))
          parts.append("?%\(2 * i): %\(2 * i + 1)")
        } else {
          let vt = v == .dyn ? randomType(nesting: 1) : v
          kids.append(depth > 0 ? gen(vt, depth - 1) : literal(vt, 0))
          parts.append("%\(2 * i): %\(2 * i + 1)")
        }
      }
      return Node("{" + parts.joined(separator: ", ") + "}", kids, t)
    case .optional(let e):
      if rng.chance(30) { return Node("optional.none()", [], t) }
      return Node("optional.of($0)", [depth > 0 ? gen(e, depth - 1) : literal(e, 0)], t)
    case .message(let name):
      let fields = Messages.fields[name] ?? []
      var kids: [Node] = []
      var parts: [String] = []
      var used: [String] = []
      for _ in 0..<(fields.isEmpty ? 0 : rng.range(0, 3)) {
        let f = rng.pick(fields)
        if used.contains(f.name) { continue }
        used.append(f.name)
        let value: Node
        if name.contains(".proto2.") && f.name.contains("enum") && rng.chance(50) {
          // Undeclared numbers too: cel-swift keeps them in unknown fields, as cel-go keeps any int32.
          value = closedEnumLiteral(f.type, max: 12)
        } else if f.name.contains("null_value") && f.type != .null {
          // Numbers other than NULL_VALUE (0) too: protojson writes each as null.
          value = closedEnumLiteral(f.type, max: 5)
        } else if (f.isWrapper || f.type == .null) && rng.chance(25) {
          value = Node("null", [], .null)
        } else if case .message = f.type, depth <= 0 {
          value = Self.minimalLiterals(f.type)[0]
        } else {
          value = depth > 0 ? gen(f.type, depth - 1) : literal(f.type, 0)
        }
        // An optional field entry `?f: optional` sets the field only when the optional has a value.
        if full && rng.chance(8) {
          kids.append(Node("optional.of($0)", [value], .optional(f.type)))
          parts.append("?\(f.name): $\(kids.count - 1)")
        } else {
          kids.append(value)
          parts.append("\(f.name): $\(kids.count - 1)")
        }
      }
      return Node(Messages.shortName(name) + "{" + parts.joined(separator: ", ") + "}", kids, t)
    }
  }

  /// A literal holding only enum numbers 0...max, for an enum, list of enums or map of enums field.
  mutating func closedEnumLiteral(_ t: GType, max: Int) -> Node {
    switch t {
    case .list:
      return Node("[" + (0..<rng.range(0, 2)).map { _ in "\(rng.range(0, max))" }.joined(separator: ", ") + "]", [], t)
    case .map(let k, _):
      if rng.chance(30) { return Node("{}", [], t) }
      let (key, _) = keyLiteral(k)
      return Node("{$0: \(rng.range(0, max))}", [key], t)
    default:
      return Node("\(rng.range(0, max))", [], t)
    }
  }

  /// A map key literal and the identity of its value, so a literal map never repeats a key.
  mutating func keyLiteral(_ k: GType) -> (Node, String) {
    switch k {
    case .string:
      let s = rng.chance(60) ? rng.pick(Self.mapKeys) : rng.pick(Self.strings)
      return (Node(Self.quote(s), [], .string), "s:" + s)
    case .int:
      let v: Int64 = rng.chance(50) ? Int64(rng.range(-3, 3)) : rng.pick(Self.ints)
      return (Node("\(v)", [], .int, op: v < 0), "i:\(v)")
    case .uint:
      let v: UInt64 = rng.chance(50) ? UInt64(rng.range(0, 3)) : rng.pick(Self.uints)
      return (Node("\(v)u", [], .uint), "u:\(v)")
    case .bool:
      let v = rng.chance(50)
      return (Node("\(v)", [], .bool), "b:\(v)")
    default:
      let node = literal(k, 0)
      return (node, "x:" + node.rendered)
    }
  }

  /// The smallest literal of a type, for test case reduction.
  static func minimalLiterals(_ t: GType) -> [Node] {
    switch t {
    case .int: return [Node("0", [], .int), Node("1", [], .int)]
    case .uint: return [Node("0u", [], .uint)]
    case .double: return [Node("0.0", [], .double)]
    case .string: return [Node("\"\"", [], .string), Node("\"a\"", [], .string)]
    case .bytes: return [Node("b\"\"", [], .bytes)]
    case .bool: return [Node("false", [], .bool), Node("true", [], .bool)]
    case .null: return [Node("null", [], .null)]
    case .duration: return [Node("duration(\"0s\")", [], .duration)]
    case .timestamp: return [Node("timestamp(0)", [], .timestamp)]
    case .dyn: return [Node("0", [], .int)]
    case .list: return [Node("[]", [], t)]
    case .map: return [Node("{}", [], t)]
    case .optional: return [Node("optional.none()", [], t)]
    case .message(let name): return [Node(Messages.shortName(name) + "{}", [], t)]
    }
  }

  // MARK: Types

  mutating func scalarType() -> GType {
    let all: [GType] = [.int, .uint, .double, .string, .bytes, .bool, .duration, .timestamp]
    return all[rng.weighted([5, 3, 4, 5, 2, 4, 2, 2])]
  }

  mutating func randomType(scalarOnly: Bool = false, nesting: Int = 2) -> GType {
    if scalarOnly || nesting == 0 { return scalarType() }
    switch rng.weighted([14, 3, 2, full ? 2 : 0, 1, messages ? 3 : 0]) {
    case 0: return scalarType()
    case 4: return .dyn
    case 5: return .message(Self.messageNames[rng.weighted([4, 3, 1, 1, 1, 1])])
    case 1: return .list(randomType(nesting: nesting - 1))
    case 2:
      let keys: [GType] = [.int, .uint, .string, .bool]
      return .map(rng.pick(keys), randomType(nesting: nesting - 1))
    default: return .optional(randomType(nesting: nesting - 1))
    }
  }

  // MARK: Values

  mutating func value(_ t: GType, nesting: Int = 2) -> GValue {
    switch t {
    case .int: return .int(rng.chance(50) ? rng.pick(Self.ints) : Int64(rng.range(-50, 50)))
    case .uint: return .uint(rng.chance(50) ? rng.pick(Self.uints) : UInt64(rng.range(0, 50)))
    case .double:
      if rng.chance(8) { return .double(rng.pick(Self.specialDoubles)) }
      return .double(rng.chance(60) ? rng.pick(Self.doubles) : Double(rng.range(-400, 400)) / 8)
    case .string: return .string(rng.chance(40) ? rng.pick(Self.mapKeys) : rng.pick(Self.strings))
    case .bytes: return .bytes(rng.pick(Self.bytePools))
    case .bool: return .bool(rng.chance(50))
    case .null: return .null
    case .duration: return .duration(rng.pick(Self.durationNanos))
    case .timestamp:
      let nanos: Int32 = rng.chance(30) ? Int32(rng.range(0, 999_999_999)) : 0
      return .timestamp(seconds: rng.pick(Self.timestampSeconds), nanos: nanos)
    case .dyn: return value(randomType(nesting: 1), nesting: 1)
    case .list(let e):
      return .list((0..<rng.range(0, 4)).map { _ in value(e, nesting: nesting - 1) })
    case .map(let k, let v):
      var entries: [(GValue, GValue)] = []
      var seen: [String] = []
      for _ in 0..<rng.range(0, 3) {
        let key = value(k, nesting: 0)
        let text = key.json.rendered
        if seen.contains(text) { continue }
        seen.append(text)
        entries.append((key, value(v, nesting: nesting - 1)))
      }
      return .map(entries)
    case .optional(let e): return rng.chance(30) ? .optional(nil) : .optional(value(e, nesting: nesting - 1))
    case .message(let name): return messageValue(name, nesting: nesting)
    }
  }

  /// A message binding with a few fields set, each in range for its protobuf type.
  mutating func messageValue(_ name: String, nesting: Int) -> GValue {
    let fields = (Messages.fields[name] ?? []).filter { f in
      // NullValue fields take only null, which the generator does not bind.
      if f.name.contains("null_value") { return false }
      switch f.type {
      case .int, .uint, .double, .string, .bytes, .bool, .duration, .timestamp: return true
      case .list(let e), .map(_, let e): return e.isOrderable
      case .message: return nesting > 0
      default: return false
      }
    }
    var set: [(String, GValue)] = []
    for _ in 0..<(fields.isEmpty ? 0 : rng.range(0, 4)) {
      let f = rng.pick(fields)
      if set.contains(where: { $0.0 == f.name }) { continue }
      // Members of one oneof cannot both be set in protobuf JSON.
      let oneofs = [["single_nested_message", "single_nested_enum"], ["oneof_type", "oneof_msg", "oneof_bool"]]
      let clash = oneofs.contains { group in group.contains(f.name) && set.contains { group.contains($0.0) } }
      if clash { continue }
      set.append((f.name, fieldValue(f, nesting: nesting)))
    }
    return .message(name, set)
  }

  /// A value that fits a field: 32-bit fields get 32-bit numbers, enums their values, floats exact floats.
  /// The protobuf kind comes from the field name: `map_<key>_<value>`, `repeated_<kind>`, `single_<kind>`,
  /// and `bb` (NestedMessage's int32).
  mutating func fieldValue(_ f: Messages.Field, nesting: Int) -> GValue {
    func scalar(_ t: GType, _ kind: String) -> GValue {
      if kind.contains("enum") { return .int(Int64(rng.range(0, 2))) }
      switch t {
      case .int where kind.contains("32") || kind == "bb":
        return .int(Int64(rng.pick([0, 1, -1, 7, 2_147_483_647, -2_147_483_648])))
      case .uint where kind.contains("32"): return .uint(UInt64(rng.pick([0, 1, 7, 4_294_967_295])))
      case .double where kind.contains("float"): return .double(rng.pick([0, 1.5, -2.25, 0.5, 1e10, .infinity]))
      default: return value(t, nesting: 0)
      }
    }
    switch f.type {
    case .list(let e): return .list((0..<rng.range(0, 3)).map { _ in scalar(e, f.name) })
    case .map(let k, let v):
      // map_<key>_<value>: the key kind is the second word.
      let words = f.name.split(separator: "_").map(String.init)
      let keyKind = words.count > 1 ? words[1] : ""
      let valueKind = words.dropFirst(2).joined(separator: "_")
      var entries: [(GValue, GValue)] = []
      var seen: [String] = []
      for _ in 0..<rng.range(0, 2) {
        let key = scalar(k, keyKind)
        if seen.contains(key.json.rendered) { continue }
        seen.append(key.json.rendered)
        entries.append((key, scalar(v, valueKind)))
      }
      return .map(entries)
    case .message(let name): return messageValue(name, nesting: nesting - 1)
    default: return scalar(f.type, f.name)
    }
  }

  static func runtimeType(_ v: GValue) -> GType {
    switch v {
    case .null: return .null
    case .bool: return .bool
    case .int: return .int
    case .uint: return .uint
    case .double: return .double
    case .string: return .string
    case .bytes: return .bytes
    case .duration: return .duration
    case .timestamp: return .timestamp
    case .list: return .list(.dyn)
    case .map: return .map(.dyn, .dyn)
    case .optional: return .optional(.dyn)
    case .message(let name, _): return .message(name)
    }
  }

  // MARK: Cases

  /// Generates bindings and a root expression.
  mutating func makeCase() -> (root: Node, bindings: [(String, GValue)]) {
    var bindings: [(String, GValue)] = []
    for (name, type) in decls {
      let v = value(type)
      if type == .dyn {
        let rt = Self.runtimeType(v)
        if rt.isOrderable || rt == .null { dynTypes[name] = rt }
      }
      bindings.append((name, v))
    }
    let depth = rng.chance(10) ? 6 : rng.range(1, 5)
    let root: Node
    if rng.chance(4) {
      root = Node("type($0)", [gen(randomType(), depth - 1)], .dyn)
    } else {
      root = gen(randomType(), depth)
    }
    return (root, bindings)
  }

  /// A new comprehension or binding variable name; sometimes the name of one in scope, which the new one
  /// shadows.
  mutating func fresh(_ prefix: String) -> String {
    if !scope.isEmpty && rng.chance(8) {
      return rng.pick(scope).0
    }
    counter += 1
    return "\(prefix)\(counter)"
  }

  /// Variables and in-scope comprehension variables of exactly type `t`.
  func names(of t: GType) -> [String] {
    var out = scope.filter { $0.1 == t }.map(\.0)
    out += decls.filter { $0.1 == t }.map(\.0)
    out += dynTypes.filter { $0.value == t }.map(\.key)
    return out
  }

  mutating func leaf(_ t: GType) -> Node {
    if t == .int && messages && rng.chance(10) {
      return Node(rng.pick(Messages.enumConstants), [], .int)
    }
    let candidates = names(of: t)
    if !candidates.isEmpty && rng.chance(55) {
      let name = rng.pick(candidates)
      // A dyn variable standing in for its runtime type keeps the static type dyn.
      if dynTypes[name] == t && !decls.contains(where: { $0.0 == name && $0.1 == t }) {
        return Node(name, [], .dyn)
      }
      return Node(name, [], t)
    }
    return literal(t, 0)
  }

  /// A comprehension variable binding for the body of a macro.
  mutating func withScope<T>(_ vars: [(String, GType)], _ body: (inout Generator) -> T) -> T {
    let saved = scope
    scope = scope.filter { old in !vars.contains { $0.0 == old.0 } } + vars
    comprehensionDepth += 1
    defer {
      scope = saved
      comprehensionDepth -= 1
    }
    return body(&self)
  }

  /// An expression of type `t` with at most `depth` levels of productions.
  mutating func gen(_ t: GType, _ depth: Int) -> Node {
    if depth <= 0 || rng.chance(15) {
      return leaf(t)
    }
    var options: [(Int, (inout Generator) -> Node?)] = []
    let d = depth - 1
    func add(_ weight: Int, _ name: String, _ build: @escaping (inout Generator) -> Node?) {
      if Self.enabled(name) { options.append((weight, build)) }
    }
    // Productions available for every type.
    add(3, "cond") { g in Node("%0 ? %1 : %2", [g.gen(.bool, d), g.gen(t, d), g.gen(t, d)], t, op: true) }
    if full {
      add(1, "bind") { g in
        guard g.comprehensionDepth < 3 else { return nil }
        let u = g.randomType(nesting: 1)
        let name = g.fresh("b")
        let initial = g.gen(u, d)
        let body = g.withScope([(name, u)]) { $0.gen(t, d) }
        return Node("cel.bind(\(name), $0, $1)", [initial, body], t, ext: true)
      }
    }
    add(1, "dyn") { g in Node("dyn($0)", [g.gen(t, d)], .dyn) }
    // Element access producing any type.
    add(1, "list_index") { g in Node("%0[$1]", [g.gen(.list(t), d), g.index(d)], t) }
    add(1, "map_index_numeric") { g in
      guard g.rng.chance(30) else { return nil }
      // Map lookups with a key of another numeric type, which CEL resolves by numeric equality.
      let (k, key): (GType, String) = g.rng.pick([
        (.int, "dyn(\(g.rng.range(0, 3))u)"), (.int, "dyn(\(g.rng.range(0, 3)).0)"),
        (.uint, "dyn(\(g.rng.range(0, 3)))"),
        (.uint, "dyn(\(g.rng.range(0, 3)).5)"), (.int, "dyn(1e100)"),
      ])
      return Node("%0[$1]", [g.gen(.map(k, t), d), Node(key, [], .dyn)], t)
    }
    if messages {
      // Fields of type t on any generated message.
      let sources = Self.messageNames.flatMap { m in
        (Messages.fields[m] ?? []).filter { $0.type == t }.map { (m, $0.name) }
      }
      if !sources.isEmpty {
        add(4, "msg_field") { g in
          let (m, field) = g.rng.pick(sources)
          return Node("%0.\(field)", [g.gen(.message(m), d)], t)
        }
      }
    }
    add(1, "map_select") { g in
      Node("%0.\(g.rng.pick(Self.mapKeys.filter { !$0.isEmpty }))", [g.gen(.map(.string, t), d)], t)
    }
    add(1, "map_index") { g in
      let k: GType = g.rng.pick([.string, .int, .bool, .uint])
      return Node("%0[$1]", [g.gen(.map(k, t), d), g.literal(k, 0)], t)
    }
    if full {
      add(1, "opt_value") { g in Node("%0.value()", [g.gen(.optional(t), d)], t) }
      add(2, "opt_orValue") { g in Node("%0.orValue($1)", [g.gen(.optional(t), d), g.gen(t, d)], t) }
    }

    switch t {
    case .int: addInt(&options, d)
    case .uint: addUint(&options, d)
    case .double: addDouble(&options, d)
    case .string: addString(&options, d)
    case .bytes: addBytes(&options, d)
    case .bool: addBool(&options, d)
    case .duration: addDuration(&options, d)
    case .timestamp: addTimestamp(&options, d)
    case .list(let e): addList(&options, e, d)
    case .map(let k, let v): addMap(&options, k, v, d)
    case .optional(let e): addOptional(&options, e, d)
    case .dyn:
      add(4, "dyn_any") { g in g.gen(g.randomType(nesting: 1), d) }
      add(2, "dyn_binop") { g in
        // Operators dispatched at runtime, often on operands no overload accepts.
        let op = g.rng.pick(["+", "-", "*", "/", "%"])
        let a = g.rng.chance(60) ? g.randomType(nesting: 1) : .int
        let b = g.rng.chance(50) ? a : g.randomType(nesting: 1)
        return Node("dyn($0) \(op) dyn($1)", [g.gen(a, d), g.gen(b, d)], .dyn, op: true)
      }
      add(1, "dyn_neg") { g in Node("-dyn($0)", [g.gen(g.scalarType(), d)], .dyn, op: true) }
      add(1, "dyn_index") { g in
        // Indexing and field selection on values only known at runtime.
        let key: Node = g.rng.chance(50) ? g.index(d) : g.literal(.string, 0)
        return Node("dyn(%0)[$1]", [g.gen(g.randomType(nesting: 1), d), key], .dyn)
      }
      add(1, "dyn_select") { g in
        Node("dyn(%0).\(g.rng.pick(Self.mapKeys.filter { !$0.isEmpty }))", [g.gen(g.randomType(nesting: 1), d)], .dyn)
      }
    case .null: break
    case .message: break
    }

    for _ in 0..<8 {
      let i = rng.weighted(options.map(\.0))
      if let node = options[i].1(&self) {
        return node
      }
    }
    return leaf(t)
  }

  typealias Options = [(Int, (inout Generator) -> Node?)]

  func addIf(
    _ options: inout Options, _ cond: Bool, _ weight: Int, _ name: String, _ build: @escaping (inout Generator) -> Node?
  ) {
    if cond && Self.enabled(name) { options.append((weight, build)) }
  }

  // MARK: Productions by type

  mutating func addInt(_ o: inout Options, _ d: Int) {
    for op in ["+", "-", "*", "/", "%"] {
      addIf(&o, true, 2, "int\(op)") { g in Node("%0 \(op) %1", [g.gen(.int, d), g.gen(.int, d)], .int, op: true) }
    }
    addIf(&o, true, 1, "int_neg") { g in Node("-%0", [g.gen(.int, d)], .int, op: true) }
    addIf(&o, true, 3, "int_conv") { g in
      let from: GType = g.rng.pick([.uint, .double, .string, .timestamp, .int, .duration])
      if from == .string, g.rng.chance(60) {
        return Node(
          "int($0)",
          [
            g.stringLiteral(
              g.rng.pick(["42", "-7", "9223372036854775807", "9223372036854775808", "0x10", "1.5", " 3", "+5", ""]))
          ], .int)
      }
      return Node("int($0)", [g.gen(from, d)], .int)
    }
    addIf(&o, true, 3, "size") { g in
      let from: GType = g.rng.pick([.string, .bytes, .list(g.randomType(nesting: 1)), .map(.string, .int)])
      return Node(g.rng.chance(50) ? "size($0)" : "%0.size()", [g.gen(from, d)], .int)
    }
    for getter in [
      "getFullYear", "getMonth", "getDayOfYear", "getDayOfMonth", "getDate", "getDayOfWeek", "getHours", "getMinutes",
      "getSeconds", "getMilliseconds",
    ] {
      addIf(&o, true, 1, "ts_\(getter)") { g in
        if g.rng.chance(40) {
          return Node("%0.\(getter)($1)", [g.gen(.timestamp, d), g.stringLiteral(g.rng.pick(Self.timeZones))], .int)
        }
        return Node("%0.\(getter)()", [g.gen(.timestamp, d)], .int)
      }
    }
    // Not duration getMilliseconds: cel-swift returns the spec's milliseconds portion, cel-go the whole
    // duration in milliseconds (docs/divergences.md).
    for getter in ["getHours", "getMinutes", "getSeconds"] {
      addIf(&o, true, 1, "du_\(getter)") { g in Node("%0.\(getter)()", [g.gen(.duration, d)], .int) }
    }
    addIf(&o, comprehensionDepth < 2, 2, "size_filter") { g in
      let e = g.randomType(nesting: 1)
      let v = g.fresh("v")
      let src = g.gen(.list(e), d)
      let pred = g.withScope([(v, e)]) { $0.gen(.bool, d) }
      return Node("size(%0.filter(\(v), $1))", [src, pred], .int)
    }
    // Extensions.
    addIf(&o, full, 2, "math_greatest") { g in
      let fn = g.rng.pick(["math.greatest", "math.least"])
      let n = g.rng.range(1, 3)
      if g.rng.chance(25) {
        return Node("\(fn)($0)", [g.gen(.list(.int), d)], .int, ext: true)
      }
      let kids = (0..<n).map { _ in g.gen(.int, d) }
      return Node("\(fn)(" + (0..<n).map { "$\($0)" }.joined(separator: ", ") + ")", kids, .int, ext: true)
    }
    addIf(&o, full, 1, "net_int") { g in
      g.rng.chance(50)
        ? Node("ip($0).family()", [g.ipString(d, cidr: false)], .int, ext: true)
        : Node("cidr($0).prefixLength()", [g.ipString(d, cidr: true)], .int, ext: true)
    }
    for fn in ["math.abs", "math.sign", "math.bitNot"] {
      addIf(&o, full, 1, fn) { g in Node("\(fn)($0)", [g.gen(.int, d)], .int, ext: true) }
    }
    for fn in ["math.bitAnd", "math.bitOr", "math.bitXor"] {
      addIf(&o, full, 1, fn) { g in Node("\(fn)($0, $1)", [g.gen(.int, d), g.gen(.int, d)], .int, ext: true) }
    }
    for fn in ["math.bitShiftLeft", "math.bitShiftRight"] {
      addIf(&o, full, 1, fn) { g in Node("\(fn)($0, $1)", [g.gen(.int, d), g.smallInt(d)], .int, ext: true) }
    }
    for fn in ["indexOf", "lastIndexOf"] {
      addIf(&o, full, 2, "str_\(fn)") { g in
        if g.rng.chance(40) {
          // Offset 0: an offset past the end is an error in cel-swift and -1 in cel-go (docs/divergences.md),
          // which changes the cost and the outcome of the surrounding expression.
          return Node("%0.\(fn)($1, 0)", [g.gen(.string, d), g.gen(.string, d)], .int, ext: true)
        }
        return Node("%0.\(fn)($1)", [g.gen(.string, d), g.gen(.string, d)], .int, ext: true)
      }
    }
  }

  mutating func addUint(_ o: inout Options, _ d: Int) {
    for op in ["+", "-", "*", "/", "%"] {
      addIf(&o, true, 2, "uint\(op)") { g in Node("%0 \(op) %1", [g.gen(.uint, d), g.gen(.uint, d)], .uint, op: true) }
    }
    addIf(&o, true, 3, "uint_conv") { g in
      let from: GType = g.rng.pick([.int, .double, .string, .uint])
      if from == .string, g.rng.chance(60) {
        return Node(
          "uint($0)",
          [
            g.stringLiteral(g.rng.pick(["42", "-7", "18446744073709551615", "18446744073709551616", "0x10", "1u", ""]))
          ], .uint)
      }
      return Node("uint($0)", [g.gen(from, d)], .uint)
    }
    addIf(&o, full, 1, "math_greatest_uint") { g in
      Node(
        g.rng.pick(["math.greatest($0, $1)", "math.least($0, $1)"]), [g.gen(.uint, d), g.gen(.uint, d)], .uint,
        ext: true)
    }
    for fn in ["math.bitAnd", "math.bitOr", "math.bitXor"] {
      addIf(&o, full, 1, "\(fn)_uint") { g in
        Node("\(fn)($0, $1)", [g.gen(.uint, d), g.gen(.uint, d)], .uint, ext: true)
      }
    }
    addIf(&o, full, 1, "math.bitShift_uint") { g in
      Node(
        g.rng.pick(["math.bitShiftLeft($0, $1)", "math.bitShiftRight($0, $1)"]), [g.gen(.uint, d), g.smallInt(d)],
        .uint, ext: true)
    }
    addIf(&o, full, 1, "math.abs_uint") { g in Node("math.abs($0)", [g.gen(.uint, d)], .uint, ext: true) }
  }

  mutating func addDouble(_ o: inout Options, _ d: Int) {
    for op in ["+", "-", "*", "/"] {
      addIf(&o, true, 2, "double\(op)") { g in
        Node("%0 \(op) %1", [g.gen(.double, d), g.gen(.double, d)], .double, op: true)
      }
    }
    addIf(&o, true, 1, "double_neg") { g in Node("-%0", [g.gen(.double, d)], .double, op: true) }
    addIf(&o, true, 3, "double_conv") { g in
      let from: GType = g.rng.pick([.int, .uint, .string, .double])
      if from == .string, g.rng.chance(60) {
        return Node(
          "double($0)",
          [
            g.stringLiteral(
              g.rng.pick(["1.5", "-0", "1e400", "NaN", "inf", "-Infinity", "0x1p3", "abc", "1_000", ".5", "5."]))
          ], .double)
      }
      return Node("double($0)", [g.gen(from, d)], .double)
    }
    for fn in ["math.ceil", "math.floor", "math.round", "math.trunc", "math.abs", "math.sign"] {
      addIf(&o, full, 1, fn) { g in Node("\(fn)($0)", [g.gen(.double, d)], .double, ext: true) }
    }
    addIf(&o, full, 1, "math.sqrt") { g in
      Node("math.sqrt($0)", [g.gen(g.rng.pick([.double, .int, .uint]), d)], .double, ext: true)
    }
    addIf(&o, full, 1, "math_greatest_double") { g in
      Node(
        g.rng.pick(["math.greatest($0, $1)", "math.least($0, $1)"]), [g.gen(.double, d), g.gen(.double, d)], .double,
        ext: true)
    }
  }

  mutating func addString(_ o: inout Options, _ d: Int) {
    addIf(&o, true, 3, "str+") { g in Node("%0 + %1", [g.gen(.string, d), g.gen(.string, d)], .string, op: true) }
    addIf(&o, true, 3, "string_conv") { g in
      let from: GType = g.rng.pick([.int, .uint, .double, .bool, .bytes, .timestamp, .duration, .string])
      return Node("string($0)", [g.gen(from, d)], .string)
    }
    addIf(&o, full, 1, "str_charAt") { g in
      Node("%0.charAt($1)", [g.gen(.string, d), g.smallInt(d)], .string, ext: true)
    }
    for fn in ["lowerAscii", "upperAscii", "trim", "reverse"] {
      addIf(&o, full, 1, "str_\(fn)") { g in Node("%0.\(fn)()", [g.gen(.string, d)], .string, ext: true) }
    }
    addIf(&o, full, 1, "str_replace") { g in
      if g.rng.chance(40) {
        return Node(
          "%0.replace($1, $2, $3)", [g.gen(.string, d), g.gen(.string, d), g.gen(.string, d), g.smallInt(d)], .string,
          ext: true)
      }
      return Node("%0.replace($1, $2)", [g.gen(.string, d), g.gen(.string, d), g.gen(.string, d)], .string, ext: true)
    }
    addIf(&o, full, 2, "str_substring") { g in
      if g.rng.chance(50) {
        return Node("%0.substring($1, $2)", [g.gen(.string, d), g.smallInt(d), g.smallInt(d)], .string, ext: true)
      }
      return Node("%0.substring($1)", [g.gen(.string, d), g.smallInt(d)], .string, ext: true)
    }
    addIf(&o, full, 1, "str_join") { g in
      if g.rng.chance(50) { return Node("%0.join()", [g.gen(.list(.string), d)], .string, ext: true) }
      return Node("%0.join($1)", [g.gen(.list(.string), d), g.gen(.string, d)], .string, ext: true)
    }
    addIf(&o, full, 1, "net_string") { g in
      switch g.rng.below(3) {
      case 0: return Node("string(ip($0))", [g.ipString(d, cidr: false)], .string, ext: true)
      case 1: return Node("string(cidr($0).masked())", [g.ipString(d, cidr: true)], .string, ext: true)
      default: return Node("string(cidr($0).ip())", [g.ipString(d, cidr: true)], .string, ext: true)
      }
    }
    addIf(&o, full, 1, "strings.quote") { g in Node("strings.quote($0)", [g.gen(.string, d)], .string, ext: true) }
    addIf(&o, full, 2, "str_format") { g in
      let clauses: [(String, [GType])] = [
        ("%d", [.int]), ("%d", [.uint]), ("%s", [g.randomType(nesting: 1)]), ("%.2f", [.double]), ("%f", [.double]),
        ("%e", [.double]), ("%.3e", [.int]), ("%x", [.int]), ("%X", [.string]), ("%x", [.bytes]), ("%o", [.uint]),
        ("%b", [.int]), ("%b", [.bool]), ("%s and %d", [.string, .int]), ("%%", []), ("%.0f", [.double]),
        ("%10s", [.string]), ("%d", [.double]), ("%s", [.list(.int)]), ("%s", [.map(.string, .int)]),
      ]
      let (format, types) = g.rng.pick(clauses)
      let args = types.map { g.gen($0, d) }
      let list = "[" + (0..<args.count).map { "$\($0 + 1)" }.joined(separator: ", ") + "]"
      return Node("$0.format(\(list))", [Node(Self.quote(format), [], .string)] + args, .string, ext: true)
    }
    addIf(&o, full, 1, "base64.encode") { g in Node("base64.encode($0)", [g.gen(.bytes, d)], .string, ext: true) }
    addIf(&o, full, 1, "regex.replace") { g in
      let pattern = g.stringLiteral(g.rng.pick(Self.regexes))
      let repl = g.stringLiteral(g.rng.pick(["x", "\\1", "[$0]", "\\\\", ""]))
      if g.rng.chance(30) {
        return Node(
          "regex.replace($0, $1, $2, $3)", [g.gen(.string, d), pattern, repl, g.smallInt(d)], .string, ext: true)
      }
      return Node("regex.replace($0, $1, $2)", [g.gen(.string, d), pattern, repl], .string, ext: true)
    }
  }

  mutating func addBytes(_ o: inout Options, _ d: Int) {
    addIf(&o, true, 3, "bytes+") { g in Node("%0 + %1", [g.gen(.bytes, d), g.gen(.bytes, d)], .bytes, op: true) }
    addIf(&o, true, 3, "bytes_conv") { g in Node("bytes($0)", [g.gen(g.rng.chance(80) ? .string : .bytes, d)], .bytes) }
    addIf(&o, full, 1, "base64.decode") { g in
      if g.rng.chance(50) {
        return Node("base64.decode(base64.encode($0))", [g.gen(.bytes, d)], .bytes, ext: true)
      }
      return Node("base64.decode($0)", [g.gen(.string, d)], .bytes, ext: true)
    }
  }

  mutating func addBool(_ o: inout Options, _ d: Int) {
    addIf(&o, true, 2, "not") { g in Node("!%0", [g.gen(.bool, d)], .bool, op: true) }
    addIf(&o, true, 3, "and") { g in Node("%0 && %1", [g.gen(.bool, d), g.gen(.bool, d)], .bool, op: true) }
    addIf(&o, true, 3, "or") { g in Node("%0 || %1", [g.gen(.bool, d), g.gen(.bool, d)], .bool, op: true) }
    addIf(&o, true, 4, "eq") { g in
      let u = g.randomType()
      return Node(g.rng.chance(50) ? "%0 == %1" : "%0 != %1", [g.gen(u, d), g.gen(u, d)], .bool, op: true)
    }
    addIf(&o, true, 4, "cmp") { g in
      var u = g.scalarType()
      if !u.isOrderable { u = .int }
      let op = g.rng.pick(["<", "<=", ">", ">="])
      return Node("%0 \(op) %1", [g.gen(u, d), g.gen(u, d)], .bool, op: true)
    }
    addIf(&o, true, 2, "cross_numeric") { g in
      let nums: [GType] = [.int, .uint, .double]
      let op = g.rng.pick(["==", "!=", "<", "<=", ">", ">="])
      return Node("dyn($0) \(op) %1", [g.gen(g.rng.pick(nums), d), g.gen(g.rng.pick(nums), d)], .bool, op: true)
    }
    addIf(&o, true, 2, "dyn_eq") { g in
      // Heterogeneous equality and ordering, decided at runtime.
      let op = g.rng.pick(["==", "!=", "==", "<", ">="])
      return Node("dyn($0) \(op) dyn($1)", [g.gen(g.randomType(), d), g.gen(g.randomType(), d)], .bool, op: true)
    }
    addIf(&o, true, 1, "type_eq_type") { g in
      Node("type(%0) == type(%1)", [g.gen(g.randomType(), d), g.gen(g.randomType(), d)], .bool, op: true)
    }
    addIf(&o, true, 1, "dyn_in") { g in
      Node("dyn($0) in %1", [g.gen(g.scalarType(), d), g.gen(.list(.dyn), d)], .bool, op: true)
    }
    addIf(&o, true, 3, "in_list") { g in
      let u = g.randomType(nesting: 1)
      return Node("%0 in %1", [g.gen(u, d), g.gen(.list(u), d)], .bool, op: true)
    }
    addIf(&o, true, 1, "in_map_numeric") { g in
      let nums: [GType] = [.int, .uint, .double]
      return Node(
        "dyn($0) in %1", [g.gen(g.rng.pick(nums), d), g.gen(.map(g.rng.pick([.int, .uint]), .string), d)], .bool,
        op: true)
    }
    addIf(&o, true, 2, "in_map") { g in
      let k: GType = g.rng.pick([.string, .int, .bool, .uint])
      return Node("%0 in %1", [g.gen(k, d), g.gen(.map(k, g.scalarType()), d)], .bool, op: true)
    }
    addIf(&o, true, 2, "has") { g in
      let maps = g.decls.filter { if case .map(.string, _) = $0.1 { return true } else { return false } }.map(\.0)
      return Node("has(\(g.rng.pick(maps)).\(g.rng.pick(Self.mapKeys.filter { !$0.isEmpty })))", [], .bool)
    }
    addIf(&o, messages, 4, "msg_has") { g in
      let m = g.rng.pick(Self.messageNames)
      guard let f = Messages.fields[m]?.randomElement(using: &g.rng) else { return nil }
      return Node("has(%0.\(f.name))", [g.gen(.message(m), d)], .bool)
    }
    addIf(&o, true, 1, "has_expr") { g in
      // Presence tests on computed maps and on values that are not maps at all.
      let operand = g.rng.chance(60) ? g.gen(.map(.string, g.scalarType()), d) : g.gen(g.randomType(nesting: 1), d)
      return Node("has(dyn(%0).\(g.rng.pick(Self.mapKeys.filter { !$0.isEmpty })))", [operand], .bool)
    }
    for fn in ["contains", "startsWith", "endsWith"] {
      addIf(&o, true, 1, "str_\(fn)") { g in Node("%0.\(fn)($1)", [g.gen(.string, d), g.gen(.string, d)], .bool) }
    }
    addIf(&o, true, 2, "matches") { g in
      let pattern = g.rng.chance(80) ? g.stringLiteral(g.rng.pick(Self.regexes)) : g.gen(.string, d)
      return g.rng.chance(50)
        ? Node("%0.matches($1)", [g.gen(.string, d), pattern], .bool)
        : Node("matches($0, $1)", [g.gen(.string, d), pattern], .bool)
    }
    addIf(&o, true, 1, "bool_conv") { g in
      if g.rng.chance(20) { return Node("bool($0)", [g.gen(.bool, d)], .bool) }
      return Node(
        "bool($0)", [g.stringLiteral(g.rng.pick(["true", "false", "1", "t", "TRUE", "no", "f", "True"]))], .bool)
    }
    addIf(&o, true, 2, "type_eq") { g in
      let names = Self.typeNames + (g.messages ? ["proto3.TestAllTypes", "proto2.TestAllTypes"] : [])
      return Node("type(%0) == \(g.rng.pick(names))", [g.gen(g.randomType(), d)], .bool, op: true)
    }
    for macro in ["all", "exists", "exists_one"] {
      addIf(&o, comprehensionDepth < 2, 2, macro) { g in
        if g.rng.chance(30) {
          let k: GType = g.rng.pick([.string, .int, .bool])
          let src = g.gen(.map(k, g.scalarType()), d)
          let v = g.fresh("k")
          let pred = g.withScope([(v, k)]) { $0.gen(.bool, d) }
          return Node("%0.\(macro)(\(v), $1)", [src, pred], .bool)
        }
        let e = g.randomType(nesting: 1)
        let v = g.fresh("v")
        let src = g.gen(.list(e), d)
        let pred = g.withScope([(v, e)]) { $0.gen(.bool, d) }
        return Node("%0.\(macro)(\(v), $1)", [src, pred], .bool)
      }
    }
    for macro in ["all", "exists", "existsOne"] {
      addIf(&o, full && comprehensionDepth < 2, 1, "two_var_\(macro)") { g in
        let k = g.fresh("k")
        let v = g.fresh("v")
        if g.rng.chance(50) {
          let e = g.randomType(nesting: 1)
          let src = g.gen(.list(e), d)
          let pred = g.withScope([(k, .int), (v, e)]) { $0.gen(.bool, d) }
          return Node("%0.\(macro)(\(k), \(v), $1)", [src, pred], .bool, ext: true)
        }
        let kt: GType = g.rng.pick([.string, .int])
        let vt = g.scalarType()
        let src = g.gen(.map(kt, vt), d)
        let pred = g.withScope([(k, kt), (v, vt)]) { $0.gen(.bool, d) }
        return Node("%0.\(macro)(\(k), \(v), $1)", [src, pred], .bool, ext: true)
      }
    }
    addIf(&o, full, 2, "opt_hasValue") { g in
      Node("%0.hasValue()", [g.gen(.optional(g.randomType(nesting: 1)), d)], .bool)
    }
    for fn in ["sets.contains", "sets.equivalent", "sets.intersects"] {
      addIf(&o, full, 1, fn) { g in
        let e = g.randomType(nesting: 1)
        return Node("\(fn)($0, $1)", [g.gen(.list(e), d), g.gen(.list(e), d)], .bool, ext: true)
      }
    }
    for fn in ["isIP", "isCIDR", "ip.isCanonical"] {
      addIf(&o, full, 1, "net_\(fn)") { g in Node("\(fn)($0)", [g.ipString(d, cidr: fn == "isCIDR")], .bool, ext: true)
      }
    }
    for fn in ["isLoopback", "isGlobalUnicast", "isLinkLocalMulticast", "isLinkLocalUnicast", "isUnspecified"] {
      addIf(&o, full, 1, "net_\(fn)") { g in Node("ip($0).\(fn)()", [g.ipString(d, cidr: false)], .bool, ext: true) }
    }
    addIf(&o, full, 1, "net_contains") { g in
      switch g.rng.below(3) {
      case 0:
        return Node(
          "cidr($0).containsIP(ip($1))", [g.ipString(d, cidr: true), g.ipString(d, cidr: false)], .bool, ext: true)
      case 1:
        return Node(
          "cidr($0).containsIP($1)", [g.ipString(d, cidr: true), g.ipString(d, cidr: false)], .bool, ext: true)
      default:
        return Node(
          "cidr($0).containsCIDR(cidr($1))", [g.ipString(d, cidr: true), g.ipString(d, cidr: true)], .bool, ext: true)
      }
    }
    addIf(&o, full, 1, "net_eq") { g in
      g.rng.chance(50)
        ? Node(
          "ip($0) == ip($1)", [g.ipString(d, cidr: false), g.ipString(d, cidr: false)], .bool, op: true, ext: true)
        : Node(
          "cidr($0) == cidr($1)", [g.ipString(d, cidr: true), g.ipString(d, cidr: true)], .bool, op: true, ext: true)
    }
    for fn in ["math.isInf", "math.isNaN", "math.isFinite"] {
      addIf(&o, full, 1, fn) { g in Node("\(fn)($0)", [g.gen(.double, d)], .bool, ext: true) }
    }
  }

  mutating func addDuration(_ o: inout Options, _ d: Int) {
    addIf(&o, true, 2, "du+") { g in Node("%0 + %1", [g.gen(.duration, d), g.gen(.duration, d)], .duration, op: true) }
    addIf(&o, true, 2, "du-") { g in Node("%0 - %1", [g.gen(.duration, d), g.gen(.duration, d)], .duration, op: true) }
    addIf(&o, true, 2, "ts-ts") { g in
      Node("%0 - %1", [g.gen(.timestamp, d), g.gen(.timestamp, d)], .duration, op: true)
    }
    addIf(&o, true, 1, "du_conv") { g in
      if g.rng.chance(20) { return Node("duration($0)", [g.gen(.duration, d)], .duration) }
      return Node(
        "duration($0)", [g.stringLiteral(g.rng.pick(Self.durations + ["1d", "h", "1.5.5s", "-", "9223372037s"]))],
        .duration)
    }
  }

  mutating func addTimestamp(_ o: inout Options, _ d: Int) {
    addIf(&o, true, 2, "ts+du") { g in
      g.rng.chance(50)
        ? Node("%0 + %1", [g.gen(.timestamp, d), g.gen(.duration, d)], .timestamp, op: true)
        : Node("%0 + %1", [g.gen(.duration, d), g.gen(.timestamp, d)], .timestamp, op: true)
    }
    addIf(&o, true, 2, "ts-du") { g in
      Node("%0 - %1", [g.gen(.timestamp, d), g.gen(.duration, d)], .timestamp, op: true)
    }
    addIf(&o, true, 1, "ts_conv_int") { g in
      Node("timestamp($0)", [g.gen(g.rng.chance(80) ? .int : .timestamp, d)], .timestamp)
    }
    addIf(&o, true, 1, "ts_conv_str") { g in
      Node(
        "timestamp($0)",
        [
          g.stringLiteral(
            g.rng.pick(
              Self.timestamps + [
                "2020-13-01T00:00:00Z", "2020-01-01", "10000-01-01T00:00:00Z", "2020-01-01T00:00:00.1234567891Z",
              ]))
        ], .timestamp)
    }
  }

  mutating func addList(_ o: inout Options, _ e: GType, _ d: Int) {
    let t = GType.list(e)
    addIf(&o, true, 3, "list_literal") { g in g.literal(t, d) }
    addIf(&o, true, 2, "list+") { g in Node("%0 + %1", [g.gen(t, d), g.gen(t, d)], t, op: true) }
    addIf(&o, comprehensionDepth < 2, 3, "map_macro") { g in
      let src = g.randomType(nesting: 1)
      let v = g.fresh("v")
      let list = g.gen(.list(src), d)
      if g.rng.chance(30) {
        let (pred, body) = g.withScope([(v, src)]) { g2 in (g2.gen(.bool, d), g2.gen(e, d)) }
        return Node("%0.map(\(v), $1, $2)", [list, pred, body], t)
      }
      let body = g.withScope([(v, src)]) { $0.gen(e, d) }
      return Node("%0.map(\(v), $1)", [list, body], t)
    }
    addIf(&o, comprehensionDepth < 2, 1, "map_macro_keys") { g in
      let k: GType = g.rng.pick([.string, .int, .bool, .uint])
      let v = g.fresh("k")
      let m = g.gen(.map(k, g.scalarType()), d)
      let body = g.withScope([(v, k)]) { $0.gen(e, d) }
      return Node("%0.map(\(v), $1)", [m, body], t)
    }
    addIf(&o, comprehensionDepth < 2, 2, "filter") { g in
      let v = g.fresh("v")
      let list = g.gen(t, d)
      let pred = g.withScope([(v, e)]) { $0.gen(.bool, d) }
      return Node("%0.filter(\(v), $1)", [list, pred], t)
    }
    addIf(&o, e.isMapKey && comprehensionDepth < 2, 1, "map_keys_filter") { g in
      let v = g.fresh("k")
      let m = g.gen(.map(e, g.scalarType()), d)
      let pred = g.withScope([(v, e)]) { $0.gen(.bool, d) }
      return Node("%0.filter(\(v), $1)", [m, pred], t)
    }
    addIf(&o, full, 1, "lists.slice") { g in
      Node("%0.slice($1, $2)", [g.gen(t, d), g.smallInt(d), g.smallInt(d)], t, ext: true)
    }
    addIf(&o, full, 1, "lists.flatten") { g in Node("%0.flatten()", [g.gen(.list(t), d)], t, ext: true) }
    for fn in ["distinct", "reverse"] {
      addIf(&o, full, 1, "lists.\(fn)") { g in Node("%0.\(fn)()", [g.gen(t, d)], t, ext: true) }
    }
    addIf(&o, full && e.isOrderable, 1, "lists.sort") { g in Node("%0.sort()", [g.gen(t, d)], t, ext: true) }
    addIf(&o, full && comprehensionDepth < 2, 1, "lists.sortBy") { g in
      let v = g.fresh("v")
      let list = g.gen(t, d)
      var kt = g.scalarType()
      if !kt.isOrderable { kt = .int }
      let key = g.withScope([(v, e)]) { $0.gen(kt, d) }
      return Node("%0.sortBy(\(v), $1)", [list, key], t, ext: true)
    }
    addIf(&o, full && e == .int, 2, "lists.range") { g in Node("lists.range(\(g.rng.range(0, 6)))", [], t, ext: true) }
    addIf(&o, full && e == .string, 2, "str_split") { g in
      if g.rng.chance(30) {
        return Node("%0.split($1, $2)", [g.gen(.string, d), g.gen(.string, d), g.smallInt(d)], t, ext: true)
      }
      return Node("%0.split($1)", [g.gen(.string, d), g.gen(.string, d)], t, ext: true)
    }
    addIf(&o, full && e == .string, 1, "regex.extractAll") { g in
      Node("regex.extractAll($0, $1)", [g.gen(.string, d), g.stringLiteral(g.rng.pick(Self.regexes))], t, ext: true)
    }
    addIf(&o, full && comprehensionDepth < 2, 1, "transformList") { g in
      let k = g.fresh("k")
      let v = g.fresh("v")
      let src = g.randomType(nesting: 1)
      let list = g.gen(.list(src), d)
      if g.rng.chance(30) {
        let (pred, body) = g.withScope([(k, .int), (v, src)]) { g2 in (g2.gen(.bool, d), g2.gen(e, d)) }
        return Node("%0.transformList(\(k), \(v), $1, $2)", [list, pred, body], t, ext: true)
      }
      let body = g.withScope([(k, .int), (v, src)]) { $0.gen(e, d) }
      return Node("%0.transformList(\(k), \(v), $1)", [list, body], t, ext: true)
    }
    addIf(&o, full, 1, "optional.unwrap") { g in
      g.rng.chance(50)
        ? Node("optional.unwrap($0)", [g.gen(.list(.optional(e)), d)], t)
        : Node("%0.unwrapOpt()", [g.gen(.list(.optional(e)), d)], t)
    }
  }

  mutating func addMap(_ o: inout Options, _ k: GType, _ v: GType, _ d: Int) {
    let t = GType.map(k, v)
    addIf(&o, true, 4, "map_literal") { g in g.literal(t, d) }
    addIf(&o, full && comprehensionDepth < 2, 1, "transformMap") { g in
      let kv = g.fresh("k")
      let vv = g.fresh("v")
      let src = g.scalarType()
      if k == .int && g.rng.chance(40) {
        let list = g.gen(.list(src), d)
        let body = g.withScope([(kv, .int), (vv, src)]) { $0.gen(v, d) }
        return Node("%0.transformMap(\(kv), \(vv), $1)", [list, body], t, ext: true)
      }
      let m = g.gen(.map(k, src), d)
      if g.rng.chance(30) {
        let (pred, body) = g.withScope([(kv, k), (vv, src)]) { g2 in (g2.gen(.bool, d), g2.gen(v, d)) }
        return Node("%0.transformMap(\(kv), \(vv), $1, $2)", [m, pred, body], t, ext: true)
      }
      let body = g.withScope([(kv, k), (vv, src)]) { $0.gen(v, d) }
      return Node("%0.transformMap(\(kv), \(vv), $1)", [m, body], t, ext: true)
    }
    addIf(&o, full && comprehensionDepth < 2, 1, "transformMapEntry") { g in
      let kv = g.fresh("k")
      let vv = g.fresh("v")
      let sk: GType = g.rng.pick([.string, .int])
      let sv = g.scalarType()
      let m = g.gen(.map(sk, sv), d)
      let (key, value) = g.withScope([(kv, sk), (vv, sv)]) { g2 in (g2.gen(k, d), g2.gen(v, d)) }
      return Node("%0.transformMapEntry(\(kv), \(vv), {%1: %2})", [m, key, value], t, ext: true)
    }
  }

  mutating func addOptional(_ o: inout Options, _ e: GType, _ d: Int) {
    let t = GType.optional(e)
    guard full else { return }
    addIf(&o, true, 3, "optional.of") { g in Node("optional.of($0)", [g.gen(e, d)], t) }
    addIf(&o, true, 1, "optional.none") { _ in Node("optional.none()", [], t) }
    addIf(&o, true, 2, "optional.ofNonZeroValue") { g in Node("optional.ofNonZeroValue($0)", [g.gen(e, d)], t) }
    addIf(&o, true, 2, "opt_map_index") { g in
      let k: GType = g.rng.pick([.string, .int, .bool])
      return Node("%0[?$1]", [g.gen(.map(k, e), d), g.literal(k, 0)], t)
    }
    addIf(&o, true, 2, "opt_list_index") { g in Node("%0[?$1]", [g.gen(.list(e), d), g.smallInt(d)], t) }
    addIf(&o, true, 2, "opt_select") { g in
      let maps = g.decls.filter { $0.1 == .map(.string, e) }.map(\.0)
      guard !maps.isEmpty else { return nil }
      return Node("\(g.rng.pick(maps)).?\(g.rng.pick(Self.mapKeys.filter { !$0.isEmpty }))", [], t)
    }
    addIf(&o, messages, 3, "msg_opt_field") { g in
      let sources = Self.messageNames.flatMap { m in
        (Messages.fields[m] ?? []).filter { $0.type == e }.map { (m, $0.name) }
      }
      guard !sources.isEmpty else { return nil }
      let (m, field) = g.rng.pick(sources)
      return Node("%0.?\(field)", [g.gen(.message(m), d)], t)
    }
    addIf(&o, true, 2, "opt_or") { g in Node("%0.or(%1)", [g.gen(t, d), g.gen(t, d)], t) }
    addIf(&o, comprehensionDepth < 2, 1, "optMap") { g in
      let src = g.scalarType()
      let v = g.fresh("v")
      let opt = g.gen(.optional(src), d)
      let body = g.withScope([(v, src)]) { $0.gen(e, d) }
      return Node("%0.optMap(\(v), $1)", [opt, body], t)
    }
    addIf(&o, comprehensionDepth < 2, 1, "optFlatMap") { g in
      let src = g.scalarType()
      let v = g.fresh("v")
      let opt = g.gen(.optional(src), d)
      let body = g.withScope([(v, src)]) { $0.gen(t, d) }
      return Node("%0.optFlatMap(\(v), $1)", [opt, body], t)
    }
    for fn in ["first", "last"] {
      addIf(&o, true, 1, "list_\(fn)") { g in Node("%0.\(fn)()", [g.gen(.list(e), d)], t) }
    }
    addIf(&o, e == .string, 1, "regex.extract") { g in
      Node("regex.extract($0, $1)", [g.gen(.string, d), g.stringLiteral(g.rng.pick(Self.regexes))], t, ext: true)
    }
  }
}

extension String {
  /// Two lowercase hex digits.
  init(format2 value: UInt32) {
    let s = String(value, radix: 16)
    self = s.count == 1 ? "0" + s : s
  }
}
