// Copyright 2018 Google LLC
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

// A hand-written lexer for the lexer rules of cel-go parser/gen/CEL.g4.
//
// cel-go runs ANTLR's lexer ATN simulator: all lexer rules are matched in parallel, the longest
// accepted prefix wins (ties go to the rule defined first), and when no prefix is accepted the
// simulator fails at the first code point no rule can consume. It then reports
// `token recognition error at: '<text>'`, where the text runs from the token start up to and including
// the failing code point, and skips that code point. This lexer reproduces those semantics rule by
// rule: every scanner returns its longest accepted length and how far it could consume.

/// CEL token types, numbered as in cel-go's generated lexer.
enum CELToken {
  static let eof = -1
  static let equals = 1
  static let notEquals = 2
  static let `in` = 3
  static let less = 4
  static let lessEquals = 5
  static let greaterEquals = 6
  static let greater = 7
  static let logicalAnd = 8
  static let logicalOr = 9
  static let lbracket = 10
  static let rbracket = 11
  static let lbrace = 12
  static let rbrace = 13
  static let lparen = 14
  static let rparen = 15
  static let dot = 16
  static let comma = 17
  static let minus = 18
  static let exclam = 19
  static let questionMark = 20
  static let colon = 21
  static let plus = 22
  static let star = 23
  static let slash = 24
  static let percent = 25
  static let celTrue = 26
  static let celFalse = 27
  static let null = 28
  static let whitespace = 29
  static let comment = 30
  static let numFloat = 31
  static let numInt = 32
  static let numUint = 33
  static let string = 34
  static let bytes = 35
  static let identifier = 36
  static let escIdentifier = 37

  static let literalNames = [
    "", "'=='", "'!='", "'in'", "'<'", "'<='", "'>='", "'>'", "'&&'", "'||'",
    "'['", "']'", "'{'", "'}'", "'('", "')'", "'.'", "','", "'-'", "'!'",
    "'?'", "':'", "'+'", "'*'", "'/'", "'%'", "'true'", "'false'", "'null'",
  ]

  static let symbolicNames = [
    "", "EQUALS", "NOT_EQUALS", "IN", "LESS", "LESS_EQUALS", "GREATER_EQUALS",
    "GREATER", "LOGICAL_AND", "LOGICAL_OR", "LBRACKET", "RPRACKET", "LBRACE",
    "RBRACE", "LPAREN", "RPAREN", "DOT", "COMMA", "MINUS", "EXCLAM", "QUESTIONMARK",
    "COLON", "PLUS", "STAR", "SLASH", "PERCENT", "CEL_TRUE", "CEL_FALSE",
    "NUL", "WHITESPACE", "COMMENT", "NUM_FLOAT", "NUM_INT", "NUM_UINT",
    "STRING", "BYTES", "IDENTIFIER", "ESC_IDENTIFIER",
  ]

  static let hiddenChannel = 1
  static let defaultChannel = 0
}

/// A lexed token. `start` and `stop` are inclusive code point indexes; `text` is the token text
/// (`<EOF>` for the end of input, `<missing ...>` for tokens conjured by error recovery).
///
/// A class so that the many token temporaries of the recursive-descent rules stay pointer sized.
final class Token {
  let type: Int
  let channel: Int
  let start: Int
  let stop: Int
  let line: Int
  let column: Int
  var tokenIndex: Int
  let text: String

  init(
    type: Int, channel: Int, start: Int, stop: Int, line: Int, column: Int, tokenIndex: Int,
    text: String
  ) {
    self.type = type
    self.channel = channel
    self.start = start
    self.stop = stop
    self.line = line
    self.column = column
    self.tokenIndex = tokenIndex
    self.text = text
  }
}

/// The result of one lexer step.
enum LexerStep {
  case token(Token)
  /// A token recognition error at the given token start, with the offending text.
  case error(line: Int, column: Int, text: String)
}

struct CELLexer {
  private let input: [Unicode.Scalar]
  private var index = 0
  private var line = 1
  private var column = 0
  private var hitEOF = false

  init(input: [Unicode.Scalar]) {
    self.input = input
  }

  /// The next token, or a recognition error (after which the lexer has skipped the bad code point).
  mutating func nextStep() -> LexerStep {
    if hitEOF || index >= input.count {
      hitEOF = true
      return .token(
        Token(
          type: CELToken.eof, channel: CELToken.defaultChannel, start: index, stop: index - 1,
          line: line, column: column, tokenIndex: -1, text: "<EOF>"))
    }
    let start = index
    let startLine = line
    let startColumn = column
    let m = match(start)
    if let (type, length) = m.accepted {
      advance(to: start + length)
      let channel =
        (type == CELToken.whitespace || type == CELToken.comment)
        ? CELToken.hiddenChannel : CELToken.defaultChannel
      let text = TextSource.string(input[start..<(start + length)])
      return .token(
        Token(
          type: type, channel: channel, start: start, stop: start + length - 1, line: startLine,
          column: startColumn, tokenIndex: -1, text: text))
    }
    // No rule accepted a prefix: the simulator stopped at `failIndex`.
    let failIndex = m.alive
    advance(to: failIndex)
    let stop = min(failIndex, input.count - 1)
    let text = TextSource.string(input[start...stop])
    if failIndex < input.count {
      advance(to: failIndex + 1)
    }
    return .error(line: startLine, column: startColumn, text: text)
  }

  private mutating func advance(to target: Int) {
    while index < target {
      if input[index] == "\n" {
        line += 1
        column = 0
      } else {
        column += 1
      }
      index += 1
    }
  }

  // MARK: - Matching

  private struct Match {
    var accepted: (type: Int, length: Int)? = nil
    /// The index of the first code point no rule could consume.
    var alive: Int

    mutating func offer(_ type: Int, accept: Int?, alive end: Int) {
      if end > alive {
        alive = end
      }
      guard let accept, accept > 0 else {
        return
      }
      if let current = accepted {
        if accept > current.length || (accept == current.length && type < current.type) {
          accepted = (type, accept)
        }
      } else {
        accepted = (type, accept)
      }
    }
  }

  private func c(_ i: Int) -> UInt32? {
    i < input.count ? input[i].value : nil
  }

  private func isDigit(_ v: UInt32?) -> Bool {
    guard let v else { return false }
    return v >= 0x30 && v <= 0x39
  }

  private func isHex(_ v: UInt32?) -> Bool {
    guard let v else { return false }
    return (v >= 0x30 && v <= 0x39) || (v >= 0x61 && v <= 0x66) || (v >= 0x41 && v <= 0x46)
  }

  private func isLetter(_ v: UInt32?) -> Bool {
    guard let v else { return false }
    return (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
  }

  private func isIdentStart(_ v: UInt32?) -> Bool {
    isLetter(v) || v == 0x5F
  }

  private func isIdentPart(_ v: UInt32?) -> Bool {
    isIdentStart(v) || isDigit(v)
  }

  private func digits(_ i: Int) -> Int {
    var j = i
    while isDigit(c(j)) { j += 1 }
    return j - i
  }

  private func hexDigits(_ i: Int) -> Int {
    var j = i
    while isHex(c(j)) { j += 1 }
    return j - i
  }

  private func match(_ p: Int) -> Match {
    var m = Match(alive: p)
    guard let c0 = c(p) else {
      return m
    }
    // Fixed tokens, in rule order.
    literal(&m, p, [0x3D, 0x3D], CELToken.equals)  // ==
    literal(&m, p, [0x21, 0x3D], CELToken.notEquals)  // !=
    literal(&m, p, [0x69, 0x6E], CELToken.in)  // in
    literal(&m, p, [0x3C], CELToken.less)
    literal(&m, p, [0x3C, 0x3D], CELToken.lessEquals)
    literal(&m, p, [0x3E, 0x3D], CELToken.greaterEquals)
    literal(&m, p, [0x3E], CELToken.greater)
    literal(&m, p, [0x26, 0x26], CELToken.logicalAnd)
    literal(&m, p, [0x7C, 0x7C], CELToken.logicalOr)
    literal(&m, p, [0x5B], CELToken.lbracket)
    literal(&m, p, [0x5D], CELToken.rbracket)
    literal(&m, p, [0x7B], CELToken.lbrace)
    literal(&m, p, [0x7D], CELToken.rbrace)
    literal(&m, p, [0x28], CELToken.lparen)
    literal(&m, p, [0x29], CELToken.rparen)
    literal(&m, p, [0x2E], CELToken.dot)
    literal(&m, p, [0x2C], CELToken.comma)
    literal(&m, p, [0x2D], CELToken.minus)
    literal(&m, p, [0x21], CELToken.exclam)
    literal(&m, p, [0x3F], CELToken.questionMark)
    literal(&m, p, [0x3A], CELToken.colon)
    literal(&m, p, [0x2B], CELToken.plus)
    literal(&m, p, [0x2A], CELToken.star)
    literal(&m, p, [0x2F], CELToken.slash)
    literal(&m, p, [0x25], CELToken.percent)
    literal(&m, p, [0x74, 0x72, 0x75, 0x65], CELToken.celTrue)  // true
    literal(&m, p, [0x66, 0x61, 0x6C, 0x73, 0x65], CELToken.celFalse)  // false
    literal(&m, p, [0x6E, 0x75, 0x6C, 0x6C], CELToken.null)  // null

    // WHITESPACE : ( '\t' | ' ' | '\r' | '\n'| '\u000C' )+
    var ws = p
    while let v = c(ws), v == 0x09 || v == 0x20 || v == 0x0D || v == 0x0A || v == 0x0C {
      ws += 1
    }
    m.offer(CELToken.whitespace, accept: ws - p, alive: ws)

    // COMMENT : '//' (~'\n')*
    if c0 == 0x2F {
      if c(p + 1) == 0x2F {
        var j = p + 2
        while let v = c(j), v != 0x0A { j += 1 }
        m.offer(CELToken.comment, accept: j - p, alive: j)
      } else {
        m.offer(CELToken.comment, accept: nil, alive: p + 1)
      }
    }

    if isDigit(c0) || c0 == 0x2E {
      numbers(&m, p)
    }

    if c0 == 0x22 || c0 == 0x27 || c0 == 0x72 || c0 == 0x52 {
      let r = string(p)
      m.offer(CELToken.string, accept: r.accept.map { $0 - p }, alive: r.alive)
    }
    if c0 == 0x62 || c0 == 0x42 {
      // BYTES : ('b' | 'B') STRING
      let r = string(p + 1)
      m.offer(CELToken.bytes, accept: r.accept.map { $0 - p }, alive: max(r.alive, p + 1))
    }

    // IDENTIFIER : (LETTER | '_') ( LETTER | DIGIT | '_')*
    if isIdentStart(c0) {
      var j = p + 1
      while isIdentPart(c(j)) { j += 1 }
      m.offer(CELToken.identifier, accept: j - p, alive: j)
    }

    // ESC_IDENTIFIER : '`' (LETTER | DIGIT | '_' | '.' | '-' | '/' | ' ')+ '`'
    if c0 == 0x60 {
      var j = p + 1
      while let v = c(j),
        isLetter(v) || isDigit(v) || v == 0x5F || v == 0x2E || v == 0x2D || v == 0x2F || v == 0x20
      {
        j += 1
      }
      if j > p + 1 && c(j) == 0x60 {
        m.offer(CELToken.escIdentifier, accept: j + 1 - p, alive: j + 1)
      } else {
        m.offer(CELToken.escIdentifier, accept: nil, alive: j)
      }
    }
    return m
  }

  private func literal(_ m: inout Match, _ p: Int, _ text: [UInt32], _ type: Int) {
    var k = 0
    while k < text.count, c(p + k) == text[k] {
      k += 1
    }
    m.offer(type, accept: k == text.count ? k : nil, alive: p + k)
  }

  /// EXPONENT : ('e' | 'E') ( '+' | '-' )? DIGIT+ ; returns the end when matched and how far it got.
  private func exponent(_ i: Int) -> (end: Int?, alive: Int) {
    guard let v = c(i), v == 0x65 || v == 0x45 else {
      return (nil, i)
    }
    var j = i + 1
    if let s = c(j), s == 0x2B || s == 0x2D {
      j += 1
    }
    let d = digits(j)
    if d > 0 {
      return (j + d, j + d)
    }
    return (nil, j)
  }

  private func numbers(_ m: inout Match, _ p: Int) {
    let d1 = digits(p)
    // NUM_FLOAT
    var floatAccept: Int? = nil
    var floatAlive = p
    func floatOffer(_ accept: Int?, _ alive: Int) {
      if let accept, accept > (floatAccept ?? 0) { floatAccept = accept }
      floatAlive = max(floatAlive, alive)
    }
    if d1 > 0 {
      // DIGIT+ ('.' DIGIT+) EXPONENT?
      let i = p + d1
      if c(i) == 0x2E {
        let d2 = digits(i + 1)
        if d2 > 0 {
          let base = i + 1 + d2
          let e = exponent(base)
          floatOffer((e.end ?? base) - p, max(e.alive, base))
        } else {
          floatOffer(nil, i + 1)
        }
      } else {
        floatOffer(nil, i)
      }
      // DIGIT+ EXPONENT
      let e = exponent(p + d1)
      floatOffer(e.end.map { $0 - p }, e.alive)
    } else if c(p) == 0x2E {
      // '.' DIGIT+ EXPONENT?
      let d = digits(p + 1)
      if d > 0 {
        let base = p + 1 + d
        let e = exponent(base)
        floatOffer((e.end ?? base) - p, max(e.alive, base))
      } else {
        floatOffer(nil, p + 1)
      }
    }
    m.offer(CELToken.numFloat, accept: floatAccept, alive: floatAlive)

    guard d1 > 0 else {
      return
    }
    // NUM_INT : DIGIT+ | '0x' HEXDIGIT+
    var intAccept = d1
    var intAlive = p + d1
    var hexEnd: Int? = nil
    if c(p) == 0x30 && c(p + 1) == 0x78 {
      let h = hexDigits(p + 2)
      if h > 0 {
        hexEnd = p + 2 + h
        intAccept = max(intAccept, 2 + h)
        intAlive = max(intAlive, p + 2 + h)
      } else {
        intAlive = max(intAlive, p + 2)
      }
    }
    m.offer(CELToken.numInt, accept: intAccept, alive: intAlive)

    // NUM_UINT : DIGIT+ ( 'u' | 'U' ) | '0x' HEXDIGIT+ ( 'u' | 'U' )
    var uintAccept: Int? = nil
    var uintAlive = p + d1
    if let u = c(p + d1), u == 0x75 || u == 0x55 {
      uintAccept = d1 + 1
      uintAlive = p + d1 + 1
    }
    if c(p) == 0x30 && c(p + 1) == 0x78 {
      if let hexEnd {
        if let u = c(hexEnd), u == 0x75 || u == 0x55 {
          uintAccept = max(uintAccept ?? 0, hexEnd + 1 - p)
          uintAlive = max(uintAlive, hexEnd + 1)
        } else {
          uintAlive = max(uintAlive, hexEnd)
        }
      } else {
        uintAlive = max(uintAlive, p + 2)
      }
    }
    m.offer(CELToken.numUint, accept: uintAccept, alive: uintAlive)
  }

  /// ESC_SEQ starting at the backslash at `i`; returns the end when matched and how far it got.
  private func escapeSequence(_ i: Int) -> (end: Int?, alive: Int) {
    // i points at '\'.
    guard let v = c(i + 1) else {
      return (nil, i + 1)
    }
    switch v {
    case 0x61, 0x62, 0x66, 0x6E, 0x72, 0x74, 0x76, 0x22, 0x27, 0x5C, 0x3F, 0x60:
      return (i + 2, i + 2)
    case 0x78, 0x58:
      // ( 'x' | 'X' ) HEXDIGIT HEXDIGIT
      var j = i + 2
      for _ in 0..<2 {
        guard isHex(c(j)) else { return (nil, j) }
        j += 1
      }
      return (j, j)
    case 0x75:
      var j = i + 2
      for _ in 0..<4 {
        guard isHex(c(j)) else { return (nil, j) }
        j += 1
      }
      return (j, j)
    case 0x55:
      var j = i + 2
      for _ in 0..<8 {
        guard isHex(c(j)) else { return (nil, j) }
        j += 1
      }
      return (j, j)
    case 0x30...0x33:
      var j = i + 2
      for _ in 0..<2 {
        guard let o = c(j), o >= 0x30 && o <= 0x37 else { return (nil, j) }
        j += 1
      }
      return (j, j)
    default:
      return (nil, i + 1)
    }
  }

  /// The STRING rule starting at `p`; `accept` is the end index of the longest match.
  private func string(_ p: Int) -> (accept: Int?, alive: Int) {
    var accept: Int? = nil
    var alive = p
    func offer(_ a: Int?, _ l: Int) {
      if let a, a > (accept ?? -1) { accept = a }
      alive = max(alive, l)
    }
    guard let c0 = c(p) else {
      return (nil, p)
    }
    if c0 == 0x22 || c0 == 0x27 {
      let q = c0
      // Single-line quoted: q (ESC_SEQ | ~('\\'|q|'\n'|'\r'))* q
      var i = p + 1
      while true {
        guard let v = c(i) else {
          offer(nil, i)
          break
        }
        if v == q {
          offer(i + 1, i + 1)
          break
        }
        if v == 0x5C {
          let e = escapeSequence(i)
          guard let end = e.end else {
            offer(nil, e.alive)
            break
          }
          i = end
          continue
        }
        if v == 0x0A || v == 0x0D {
          offer(nil, i)
          break
        }
        i += 1
      }
      // Triple quoted: qqq (ESC_SEQ | ~('\\'))*? qqq
      if c(p + 1) == q {
        if c(p + 2) == q {
          var i = p + 3
          while true {
            guard let v = c(i) else {
              offer(nil, i)
              break
            }
            if v == q && c(i + 1) == q && c(i + 2) == q {
              offer(i + 3, i + 3)
              break
            }
            if v == 0x5C {
              let e = escapeSequence(i)
              guard let end = e.end else {
                offer(nil, e.alive)
                break
              }
              i = end
              continue
            }
            i += 1
          }
        } else {
          offer(nil, p + 2)
        }
      }
    } else if c0 == 0x72 || c0 == 0x52 {
      // RAW quoted forms.
      guard let q = c(p + 1), q == 0x22 || q == 0x27 else {
        return (nil, p + 1)
      }
      // RAW q ~(q|'\n'|'\r')* q
      var i = p + 2
      while true {
        guard let v = c(i) else {
          offer(nil, i)
          break
        }
        if v == q {
          offer(i + 1, i + 1)
          break
        }
        if v == 0x0A || v == 0x0D {
          offer(nil, i)
          break
        }
        i += 1
      }
      // RAW qqq .*? qqq
      if c(p + 2) == q {
        if c(p + 3) == q {
          var i = p + 4
          while true {
            guard let v = c(i) else {
              offer(nil, i)
              break
            }
            if v == q && c(i + 1) == q && c(i + 2) == q {
              offer(i + 3, i + 3)
              break
            }
            i += 1
          }
        } else {
          offer(nil, p + 3)
        }
      }
    } else {
      return (nil, p)
    }
    return (accept, alive)
  }
}
