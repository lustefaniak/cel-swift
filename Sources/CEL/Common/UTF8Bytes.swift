// Byte-wise string operations on the UTF-8 storage of Swift strings. Not a ported file.
//
// Go strings are byte slices, so cel-go compares, hashes and searches them byte by byte. Swift's
// `String` operators use canonical equivalence and are wrong for CEL; iterating `utf8` views is
// correct but walks the string through an iterator one byte at a time. These helpers borrow the
// contiguous UTF-8 buffer of a native string instead (copying only bridged or shared strings that
// have none), which turns equality, ordering, hashing and substring search into buffer loops.

/// Calls `body` with the UTF-8 bytes of `string`, without copying when the string is native.
func withUTF8Bytes<R>(_ string: String, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
  if let result = try string.utf8.withContiguousStorageIfAvailable(body) {
    return result
  }
  var copy = string
  return try copy.withUTF8(body)
}

/// Whether two strings have the same UTF-8 bytes (Go `==` on strings).
func utf8Equal(_ a: String, _ b: String) -> Bool {
  guard a.utf8.count == b.utf8.count else { return false }
  return withUTF8Bytes(a) { x in
    withUTF8Bytes(b) { y in
      bytesEqual(x, y)
    }
  }
}

/// Whether two byte buffers of equal length hold the same bytes.
func bytesEqual(_ x: UnsafeBufferPointer<UInt8>, _ y: UnsafeBufferPointer<UInt8>) -> Bool {
  guard x.count == y.count else { return false }
  guard let xb = x.baseAddress, let yb = y.baseAddress, xb != yb else { return true }
  var i = 0
  // Eight bytes at a time, then the tail.
  while i + 8 <= x.count {
    if UnsafeRawPointer(xb + i).loadUnaligned(as: UInt64.self)
      != UnsafeRawPointer(yb + i).loadUnaligned(as: UInt64.self)
    {
      return false
    }
    i += 8
  }
  while i < x.count {
    if xb[i] != yb[i] { return false }
    i += 1
  }
  return true
}

/// Lexicographic comparison of two byte buffers: -1, 0 or 1 (Go `bytes.Compare`).
func compareByteBuffers(_ x: UnsafeBufferPointer<UInt8>, _ y: UnsafeBufferPointer<UInt8>) -> Int64 {
  let n = min(x.count, y.count)
  var i = 0
  while i < n {
    let a = x[i]
    let b = y[i]
    if a != b { return a < b ? -1 : 1 }
    i += 1
  }
  return x.count == y.count ? 0 : (x.count < y.count ? -1 : 1)
}

/// The offset of the first occurrence of `needle` in `haystack`, as Go `strings.Index`.
func bytesIndex(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: UnsafeBufferPointer<UInt8>) -> Int? {
  if needle.isEmpty {
    return 0
  }
  if needle.count > haystack.count {
    return nil
  }
  let first = needle[0]
  let last = haystack.count - needle.count
  var i = 0
  while i <= last {
    if haystack[i] == first
      && bytesEqual(UnsafeBufferPointer(rebasing: haystack[i..<(i + needle.count)]), needle)
    {
      return i
    }
    i += 1
  }
  return nil
}
