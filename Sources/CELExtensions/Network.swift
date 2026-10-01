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
// Ported from cel-go ext/network.go: the opaque `net.IP` and `net.CIDR` types and their
// functions, with Kubernetes-compatible overload ids. The `netip.Addr` / `netip.Prefix` type
// adapter has no Swift counterpart (hosts create values with `IPAddressValue` / `CIDRValue`
// directly). The literal argument validators and cost functions are not ported yet.

import CEL

extension Library {
  /// The network extension library: the `ip` and `cidr` opaque types with parsing, inspection and
  /// containment functions, compatible with the Kubernetes CEL network library.
  public static var network: Library { network() }

  /// The network extension library at a given version (version 1 is the first).
  ///
  /// - Parameter version: the library version.
  public static func network(version: UInt32 = 1) -> Library {
    NetworkLibrary.library(version: version)
  }
}

/// The CEL type of IP address values, `net.IP`.
let ipType = CELType.opaque(name: "net.IP", parameters: [])
/// The CEL type of CIDR range values, `net.CIDR`.
let cidrType = CELType.opaque(name: "net.CIDR", parameters: [])

/// An IP address value (cel-go `ext.IP`).
struct IPAddressValue: ObjectValue {
  let addr: NetAddr

  var celType: CELType { ipType }

  func isEqual(to other: any ObjectValue) -> Bool {
    (other as? IPAddressValue)?.addr == addr
  }
}

/// A CIDR range value (cel-go `ext.CIDR`).
struct CIDRValue: ObjectValue {
  let prefix: NetPrefix

  var celType: CELType { cidrType }

  func isEqual(to other: any ObjectValue) -> Bool {
    (other as? CIDRValue)?.prefix == prefix
  }
}

enum NetworkLibrary {
  // swift-format-ignore: FunctionLength
  static func library(version: UInt32) -> Library {
    func ipFn(_ name: String, _ id: String, _ f: @escaping @Sendable (NetAddr) -> Value) -> FunctionDecl.Option {
      .memberOverload(
        id, argTypes: [ipType], resultType: .bool,
        .unaryBinding { v in
          guard let ip = asIP(v) else { return noSuchOverload(v) }
          return f(ip)
        })
    }
    let decls = makeDeclarations([
      try FunctionDecl(
        "cidr",
        .overload(
          "string_to_cidr", argTypes: [.string], resultType: cidrType,
          .unaryBinding { v in
            guard case .string(let s) = v else { return noSuchOverload(v) }
            switch parseCIDR(s) {
            case .success(let p): return .object(CIDRValue(prefix: p))
            case .failure(let e): return errorValue(e.message)
            }
          })),
      try FunctionDecl(
        "string",
        .overload(
          "cidr_to_string", argTypes: [cidrType], resultType: .string,
          .unaryBinding { v in
            guard let c = asCIDR(v) else { return noSuchOverload(v) }
            return .string(c.description)
          }),
        .overload(
          "ip_to_string", argTypes: [ipType], resultType: .string,
          .unaryBinding { v in
            guard let ip = asIP(v) else { return noSuchOverload(v) }
            return .string(ip.description)
          })),
      try FunctionDecl(
        "containsCIDR",
        .memberOverload(
          "cidr_contains_cidr", argTypes: [cidrType, cidrType], resultType: .bool,
          .binaryBinding { a, b in
            guard let parent = asCIDR(a), let child = asCIDR(b) else { return noSuchOverload(a, b) }
            return .bool(parent.overlaps(child) && parent.bits <= child.bits)
          }),
        .memberOverload(
          "cidr_contains_cidr_string", argTypes: [cidrType, .string], resultType: .bool,
          .binaryBinding { a, b in
            guard let parent = asCIDR(a), case .string(let s) = b else { return noSuchOverload(a, b) }
            switch parseCIDR(s) {
            case .success(let child): return .bool(parent.overlaps(child) && parent.bits <= child.bits)
            case .failure(let e): return errorValue(e.message)
            }
          })),
      try FunctionDecl(
        "containsIP",
        .memberOverload(
          "cidr_contains_ip_ip", argTypes: [cidrType, ipType], resultType: .bool,
          .binaryBinding { a, b in
            guard let cidr = asCIDR(a), let ip = asIP(b) else { return noSuchOverload(a, b) }
            return .bool(cidr.contains(ip))
          }),
        .memberOverload(
          "cidr_contains_ip_string", argTypes: [cidrType, .string], resultType: .bool,
          .binaryBinding { a, b in
            guard let cidr = asCIDR(a), case .string(let s) = b else { return noSuchOverload(a, b) }
            switch parseIP(s) {
            case .success(let ip): return .bool(cidr.contains(ip))
            case .failure(let e): return errorValue(e.message)
            }
          })),
      try FunctionDecl(
        "family",
        .memberOverload(
          "ip_family", argTypes: [ipType], resultType: .int,
          .unaryBinding { v in
            guard let ip = asIP(v) else { return noSuchOverload(v) }
            return .int(ip.is4 ? 4 : 6)
          })),
      try FunctionDecl(
        "ip",
        .overload(
          "string_to_ip", argTypes: [.string], resultType: ipType,
          .unaryBinding { v in
            guard case .string(let s) = v else { return noSuchOverload(v) }
            switch parseIP(s) {
            case .success(let ip): return .object(IPAddressValue(addr: ip))
            case .failure(let e): return errorValue(e.message)
            }
          }),
        .memberOverload(
          "cidr_ip", argTypes: [cidrType], resultType: ipType,
          .unaryBinding { v in
            guard let c = asCIDR(v) else { return noSuchOverload(v) }
            return .object(IPAddressValue(addr: c.addr))
          })),
      try FunctionDecl(
        "ip.isCanonical",
        .overload(
          "ip_is_canonical", argTypes: [.string], resultType: .bool,
          .unaryBinding { v in
            guard case .string(let s) = v else { return noSuchOverload(v) }
            switch parseIP(s) {
            case .success(let ip): return .bool(Array(ip.description.utf8) == Array(s.utf8))
            case .failure(let e): return errorValue(e.message)
            }
          })),
      try FunctionDecl(
        "isCIDR",
        .overload(
          "is_cidr", argTypes: [.string], resultType: .bool,
          .unaryBinding { v in
            guard case .string(let s) = v else { return noSuchOverload(v) }
            if case .success = parseCIDR(s) {
              return .bool(true)
            }
            return .bool(false)
          })),
      try FunctionDecl("isGlobalUnicast", ipFn("isGlobalUnicast", "ip_is_global_unicast") { .bool($0.isGlobalUnicast) }),
      try FunctionDecl(
        "isIP",
        .overload(
          "is_ip", argTypes: [.string], resultType: .bool,
          .unaryBinding { v in
            guard case .string(let s) = v else { return noSuchOverload(v) }
            if case .success = parseIP(s) {
              return .bool(true)
            }
            return .bool(false)
          })),
      try FunctionDecl(
        "isLinkLocalMulticast",
        ipFn("isLinkLocalMulticast", "ip_is_link_local_multicast") { .bool($0.isLinkLocalMulticast) }),
      try FunctionDecl(
        "isLinkLocalUnicast",
        ipFn("isLinkLocalUnicast", "ip_is_link_local_unicast") { .bool($0.isLinkLocalUnicast) }),
      try FunctionDecl("isLoopback", ipFn("isLoopback", "ip_is_loopback") { .bool($0.isLoopback) }),
      try FunctionDecl(
        "isMask",
        .memberOverload(
          "cidr_is_mask", argTypes: [cidrType], resultType: .bool,
          .unaryBinding { v in
            guard let c = asCIDR(v) else { return noSuchOverload(v) }
            return .bool(c.addr == c.masked.addr)
          })),
      try FunctionDecl(
        "isUnspecified", ipFn("isUnspecified", "ip_is_unspecified") { .bool($0.isUnspecified) }),
      try FunctionDecl(
        "masked",
        .memberOverload(
          "cidr_masked", argTypes: [cidrType], resultType: cidrType,
          .unaryBinding { v in
            guard let c = asCIDR(v) else { return noSuchOverload(v) }
            return .object(CIDRValue(prefix: c.masked))
          })),
      try FunctionDecl(
        "prefixLength",
        .memberOverload(
          "cidr_prefix_length", argTypes: [cidrType], resultType: .int,
          .unaryBinding { v in
            guard let c = asCIDR(v) else { return noSuchOverload(v) }
            return .int(Int64(c.bits))
          })),
    ])
    return Library(
      name: "cel.lib.ext.network", alias: "network", version: version, functions: decls,
      types: [ipType, cidrType])
  }

  static func asIP(_ v: Value) -> NetAddr? {
    if case .object(let o) = v, let ip = o as? IPAddressValue {
      return ip.addr
    }
    return nil
  }

  static func asCIDR(_ v: Value) -> NetPrefix? {
    if case .object(let o) = v, let c = o as? CIDRValue {
      return c.prefix
    }
    return nil
  }

  /// Port of `parseIPAddr`: strict parsing, no zones, no IPv4-mapped IPv6.
  static func parseIP(_ raw: String) -> Result<NetAddr, NetParseError> {
    let q = GoFormat.quote(raw)
    switch NetIP.parseAddr(raw) {
    case .failure(let e):
      return .failure(
        NetParseError(message: "IP Address \(q) parse error during conversion from string: \(e.message)"))
    case .success(let addr):
      if !addr.zone.isEmpty {
        return .failure(NetParseError(message: "IP address \(q) with zone value is not allowed"))
      }
      if addr.is4In6 {
        return .failure(NetParseError(message: "IPv4-mapped IPv6 address \(q) is not allowed"))
      }
      return .success(addr)
    }
  }

  /// Port of `parseCIDR`.
  static func parseCIDR(_ raw: String) -> Result<NetPrefix, NetParseError> {
    let q = GoFormat.quote(raw)
    switch NetIP.parsePrefix(raw) {
    case .failure(let e):
      return .failure(
        NetParseError(message: "CIDR \(q) parse error during conversion from string: \(e.message)"))
    case .success(let prefix):
      if prefix.addr.is4In6 {
        return .failure(NetParseError(message: "IPv4-mapped IPv6 address \(q) is not allowed"))
      }
      return .success(prefix)
    }
  }
}
