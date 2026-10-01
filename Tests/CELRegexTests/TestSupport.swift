// Copyright 2011 The Go Authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

// Helpers shared by the ported Go regexp tests.

import Foundation

@testable import CELRegex

/// Loads a test data file copied from Go's src/regexp/testdata.
func resourceData(_ name: String) throws -> Data {
  guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources") else {
    throw CocoaError(.fileNoSuchFile)
  }
  return try Data(contentsOf: url)
}

/// Bytes of a Go string literal. Go source strings may hold invalid UTF-8 (e.g. "\xff"); in the
/// ported tables such strings are written with `b(...)` from explicit bytes.
func bytes(_ s: String) -> [UInt8] {
  Array(s.utf8)
}

/// Builds a Go string from mixed parts: String pieces are UTF-8 encoded, Int pieces are raw bytes.
func goBytes(_ parts: Any...) -> [UInt8] {
  var out: [UInt8] = []
  for p in parts {
    if let s = p as? String {
      out.append(contentsOf: s.utf8)
    } else if let b = p as? Int {
      out.append(UInt8(b))
    } else if let a = p as? [UInt8] {
      out.append(contentsOf: a)
    }
  }
  return out
}

/// Go's strconv.Quote, for messages.
func goQuote(_ b: [UInt8]) -> String {
  GoStrconv.quote(b)
}

func goQuote(_ s: String) -> String {
  GoStrconv.quote(Array(s.utf8))
}
