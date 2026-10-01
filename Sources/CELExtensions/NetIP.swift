// Copyright 2020 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.
//
// Ported from Go src/net/netip/netip.go: ParseAddr, ParsePrefix, Addr.String (RFC 5952),
// Prefix.Masked / Contains / Overlaps and the address classification methods the network extension
// uses. Addresses are stored as 4 or 16 bytes; the zone is kept only so the extension can reject
// it, as cel-go does.

import CEL

/// An IPv4 or IPv6 address (Go `netip.Addr`, never the zero value).
struct NetAddr: Hashable, Sendable {
  /// 4 bytes for IPv4, 16 for IPv6.
  var bytes: [UInt8]
  /// The IPv6 zone, empty when absent.
  var zone: String = ""

  var is4: Bool { bytes.count == 4 }
  var is6: Bool { bytes.count == 16 }
  var bitLen: Int { bytes.count * 8 }

  /// Whether this is an IPv4-mapped IPv6 address (`::ffff:a.b.c.d`).
  var is4In6: Bool {
    is6 && bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
  }

  private func v6u16(_ i: Int) -> UInt16 {
    UInt16(bytes[2 * i]) << 8 | UInt16(bytes[2 * i + 1])
  }

  var isLoopback: Bool {
    if is4 {
      return bytes[0] == 127
    }
    return bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
  }

  var isMulticast: Bool {
    is4 ? bytes[0] & 0xF0 == 0xE0 : bytes[0] == 0xFF
  }

  var isLinkLocalUnicast: Bool {
    is4 ? bytes[0] == 169 && bytes[1] == 254 : v6u16(0) & 0xFFC0 == 0xFE80
  }

  var isLinkLocalMulticast: Bool {
    is4 ? bytes[0] == 224 && bytes[1] == 0 && bytes[2] == 0 : v6u16(0) & 0xFF0F == 0xFF02
  }

  var isUnspecified: Bool {
    bytes.allSatisfy { $0 == 0 } && zone.isEmpty
  }

  var isGlobalUnicast: Bool {
    if is4 && (bytes == [0, 0, 0, 0] || bytes == [255, 255, 255, 255]) {
      return false
    }
    return !(is6 && isUnspecified) && !isLoopback && !isMulticast && !isLinkLocalUnicast
  }

  /// The address with all but the first `bits` bits cleared.
  func masked(_ bits: Int) -> NetAddr {
    var out = bytes
    for i in out.indices {
      let keep = max(0, min(8, bits - i * 8))
      out[i] &= keep == 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - keep))
    }
    return NetAddr(bytes: out)
  }

  /// Go `Addr.String`: dotted quad, `::ffff:` + dotted quad, or RFC 5952 IPv6.
  var description: String {
    if is4 {
      return bytes.map(String.init).joined(separator: ".")
    }
    var out: String
    if is4In6 {
      out = "::ffff:" + bytes[12...].map(String.init).joined(separator: ".")
    } else {
      var zeroStart = 255
      var zeroEnd = 255
      var i = 0
      while i < 8 {
        var j = i
        while j < 8 && v6u16(j) == 0 {
          j += 1
        }
        let l = j - i
        if l >= 2 && l > zeroEnd - zeroStart {
          zeroStart = i
          zeroEnd = j
        }
        i += 1
      }
      out = ""
      i = 0
      while i < 8 {
        if i == zeroStart {
          out += "::"
          i = zeroEnd
          if i >= 8 {
            break
          }
        } else if i > 0 {
          out += ":"
        }
        out += String(v6u16(i), radix: 16)
        i += 1
      }
    }
    if !zone.isEmpty {
      out += "%" + zone
    }
    return out
  }
}

/// A Go `netip.ParseAddr` failure (`parseAddrError`).
struct NetParseError: Error {
  var message: String
}

enum NetIP {
  private static func addrError(_ input: String, _ msg: String, at: ArraySlice<UInt8>? = nil) -> NetParseError {
    var m = "ParseAddr(\(GoFormat.quote(input))): \(msg)"
    if let at, !at.isEmpty {
      m += " (at \(GoFormat.quote(String(decoding: at, as: UTF8.self))))"
    }
    return NetParseError(message: m)
  }

  /// Go `netip.ParseAddr`.
  static func parseAddr(_ s: String) -> Result<NetAddr, NetParseError> {
    let b = Array(s.utf8)
    for c in b {
      switch c {
      case UInt8(ascii: "."): return parseIPv4(s, b)
      case UInt8(ascii: ":"): return parseIPv6(s, b)
      case UInt8(ascii: "%"): return .failure(addrError(s, "missing IPv6 address"))
      default: continue
      }
    }
    return .failure(addrError(s, "unable to parse IP"))
  }

  private static func parseIPv4(_ input: String, _ b: [UInt8]) -> Result<NetAddr, NetParseError> {
    var fields = [UInt8](repeating: 0, count: 4)
    if let err = parseIPv4Fields(input, b[...], &fields) {
      return .failure(err)
    }
    return .success(NetAddr(bytes: fields))
  }

  private static func parseIPv4Fields(
    _ input: String, _ s: ArraySlice<UInt8>, _ fields: inout [UInt8]
  ) -> NetParseError? {
    var val = 0
    var pos = 0
    var digLen = 0
    var i = s.startIndex
    while i < s.endIndex {
      let c = s[i]
      if c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") {
        if digLen == 1 && val == 0 {
          return addrError(input, "IPv4 field has octet with leading zero")
        }
        val = val * 10 + Int(c - UInt8(ascii: "0"))
        digLen += 1
        if val > 255 {
          return addrError(input, "IPv4 field has value >255")
        }
      } else if c == UInt8(ascii: ".") {
        if i == s.startIndex || i == s.endIndex - 1 || s[i - 1] == UInt8(ascii: ".") {
          return addrError(input, "IPv4 field must have at least one digit", at: s[i...])
        }
        if pos == 3 {
          return addrError(input, "IPv4 address too long")
        }
        fields[pos] = UInt8(val)
        pos += 1
        val = 0
        digLen = 0
      } else {
        return addrError(input, "unexpected character", at: s[i...])
      }
      i += 1
    }
    if pos < 3 {
      return addrError(input, "IPv4 address too short")
    }
    fields[3] = UInt8(val)
    return nil
  }

  // swift-format-ignore: FunctionLength
  private static func parseIPv6(_ input: String, _ inBytes: [UInt8]) -> Result<NetAddr, NetParseError> {
    var s = inBytes[...]
    var zone = ""
    if let pct = s.firstIndex(of: UInt8(ascii: "%")) {
      zone = String(decoding: s[(pct + 1)...], as: UTF8.self)
      s = s[..<pct]
      if zone.isEmpty {
        return .failure(addrError(input, "zone must be a non-empty string"))
      }
    }
    var ip = [UInt8](repeating: 0, count: 16)
    var ellipsis = -1
    if s.count >= 2 && s[s.startIndex] == UInt8(ascii: ":") && s[s.startIndex + 1] == UInt8(ascii: ":") {
      ellipsis = 0
      s = s[(s.startIndex + 2)...]
      if s.isEmpty {
        return .success(NetAddr(bytes: ip, zone: zone))
      }
    }
    var i = 0
    loop: while i < 16 {
      var off = 0
      var acc: UInt32 = 0
      while off < s.count {
        let c = s[s.startIndex + off]
        if c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") {
          acc = (acc << 4) + UInt32(c - UInt8(ascii: "0"))
        } else if c >= UInt8(ascii: "a") && c <= UInt8(ascii: "f") {
          acc = (acc << 4) + UInt32(c - UInt8(ascii: "a") + 10)
        } else if c >= UInt8(ascii: "A") && c <= UInt8(ascii: "F") {
          acc = (acc << 4) + UInt32(c - UInt8(ascii: "A") + 10)
        } else {
          break
        }
        if off > 3 {
          return .failure(addrError(input, "each group must have 4 or less digits", at: s))
        }
        if acc > 0xFFFF {
          return .failure(addrError(input, "IPv6 field has value >=2^16", at: s))
        }
        off += 1
      }
      if off == 0 {
        return .failure(addrError(input, "each colon-separated field must have at least one digit", at: s))
      }
      if off < s.count && s[s.startIndex + off] == UInt8(ascii: ".") {
        if ellipsis < 0 && i != 12 {
          return .failure(
            addrError(input, "embedded IPv4 address must replace the final 2 fields of the address", at: s))
        }
        if i + 4 > 16 {
          return .failure(
            addrError(input, "too many hex fields to fit an embedded IPv4 at the end of the address", at: s))
        }
        var end = inBytes.count
        if !zone.isEmpty {
          end -= zone.utf8.count + 1
        }
        var fields = [UInt8](repeating: 0, count: 4)
        if let err = parseIPv4Fields(input, inBytes[(end - s.count)..<end], &fields) {
          return .failure(err)
        }
        ip.replaceSubrange(i..<(i + 4), with: fields)
        s = s[s.endIndex...]
        i += 4
        break loop
      }
      ip[i] = UInt8(acc >> 8)
      ip[i + 1] = UInt8(acc & 0xFF)
      i += 2
      s = s[(s.startIndex + off)...]
      if s.isEmpty {
        break loop
      }
      if s[s.startIndex] != UInt8(ascii: ":") {
        return .failure(addrError(input, "unexpected character, want colon", at: s))
      } else if s.count == 1 {
        return .failure(addrError(input, "colon must be followed by more characters", at: s))
      }
      s = s[(s.startIndex + 1)...]
      if s[s.startIndex] == UInt8(ascii: ":") {
        if ellipsis >= 0 {
          return .failure(addrError(input, "multiple :: in address", at: s))
        }
        ellipsis = i
        s = s[(s.startIndex + 1)...]
        if s.isEmpty {
          break loop
        }
      }
    }
    if !s.isEmpty {
      return .failure(addrError(input, "trailing garbage after address", at: s))
    }
    if i < 16 {
      if ellipsis < 0 {
        return .failure(addrError(input, "address string too short"))
      }
      let n = 16 - i
      var j = i - 1
      while j >= ellipsis {
        ip[j + n] = ip[j]
        j -= 1
      }
      for k in ellipsis..<(ellipsis + n) {
        ip[k] = 0
      }
    } else if ellipsis >= 0 {
      return .failure(addrError(input, "the :: must expand to at least one field of zeros"))
    }
    return .success(NetAddr(bytes: ip, zone: zone))
  }

  /// Go `netip.ParsePrefix`.
  static func parsePrefix(_ s: String) -> Result<NetPrefix, NetParseError> {
    func prefixError(_ msg: String) -> NetParseError {
      NetParseError(message: "netip.ParsePrefix(\(GoFormat.quote(s))): \(msg)")
    }
    let b = Array(s.utf8)
    guard let slash = b.lastIndex(of: UInt8(ascii: "/")) else {
      return .failure(prefixError("no '/'"))
    }
    let ip: NetAddr
    switch parseAddr(String(decoding: b[..<slash], as: UTF8.self)) {
    case .success(let a): ip = a
    case .failure(let e): return .failure(prefixError(e.message))
    }
    if ip.is6 && !ip.zone.isEmpty {
      return .failure(prefixError("IPv6 zones cannot be present in a prefix"))
    }
    let bitsBytes = b[(slash + 1)...]
    let bitsStr = String(decoding: bitsBytes, as: UTF8.self)
    let bad = prefixError("bad bits after slash: \(GoFormat.quote(bitsStr))")
    if bitsBytes.count > 1
      && (bitsBytes[bitsBytes.startIndex] < UInt8(ascii: "1")
        || bitsBytes[bitsBytes.startIndex] > UInt8(ascii: "9"))
    {
      return .failure(bad)
    }
    // strconv.Atoi: digits only here (a sign is rejected above unless alone).
    guard !bitsBytes.isEmpty,
      bitsBytes.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
      let bits = Int(bitsStr)
    else {
      return .failure(bad)
    }
    if bits > ip.bitLen {
      return .failure(prefixError("prefix length out of range"))
    }
    return .success(NetPrefix(addr: ip, bits: bits))
  }
}

/// An IP network prefix (Go `netip.Prefix`, always valid here).
struct NetPrefix: Hashable, Sendable {
  var addr: NetAddr
  var bits: Int

  init(addr: NetAddr, bits: Int) {
    var a = addr
    a.zone = ""
    self.addr = a
    self.bits = bits
  }

  var masked: NetPrefix {
    NetPrefix(addr: addr.masked(bits), bits: bits)
  }

  /// Go `Prefix.Contains`.
  func contains(_ ip: NetAddr) -> Bool {
    if !ip.zone.isEmpty || addr.bitLen != ip.bitLen {
      return false
    }
    return ip.masked(bits).bytes == addr.masked(bits).bytes
  }

  /// Go `Prefix.Overlaps`.
  func overlaps(_ o: NetPrefix) -> Bool {
    if self == o {
      return true
    }
    if addr.is4 != o.addr.is4 {
      return false
    }
    let minBits = min(bits, o.bits)
    if minBits == 0 {
      return true
    }
    return addr.masked(minBits).bytes == o.addr.masked(minBits).bytes
  }

  var description: String {
    "\(addr.description)/\(bits)"
  }
}
