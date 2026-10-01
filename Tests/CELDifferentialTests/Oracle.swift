// The cel-go side: builds tools/oracle once per test process and streams JSON lines requests through it.

import Foundation

enum Oracle {
  /// The package root, from this file's location.
  static let packageRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  /// The oracle binary, or why it is unavailable. Built at most once per process.
  static let binary: Result<URL, OracleUnavailable> = build()

  static var isAvailable: Bool {
    if case .success = binary { return true }
    return false
  }

  static var unavailableReason: String {
    if case .failure(let reason) = binary { return reason.description }
    return ""
  }

  struct OracleUnavailable: Error, CustomStringConvertible {
    var description: String
  }

  private static func build() -> Result<URL, OracleUnavailable> {
    let env = ProcessInfo.processInfo.environment
    if let path = env["CEL_DIFF_ORACLE"], !path.isEmpty {
      return .success(URL(fileURLWithPath: path))
    }
    let source = packageRoot.appendingPathComponent("tools/oracle")
    let celGo = packageRoot.appendingPathComponent("third_party/cel-go/cel")
    guard FileManager.default.fileExists(atPath: celGo.path) else {
      return .failure(OracleUnavailable(description: "third_party/cel-go is empty (git submodule update --init)"))
    }
    let output = packageRoot.appendingPathComponent(".build/cel-oracle/oracle")
    let (status, log) = run(["go", "build", "-o", output.path, "."], in: source)
    guard status == 0 else {
      if log.contains("No such file") || status == 127 {
        return .failure(
          OracleUnavailable(description: "Go is not installed; the differential suite needs it to build tools/oracle"))
      }
      return .failure(OracleUnavailable(description: "go build tools/oracle failed (\(status)): \(log)"))
    }
    return .success(output)
  }

  private static func run(_ args: [String], in directory: URL) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = args
    process.currentDirectoryURL = directory
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
    } catch {
      return (127, "\(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  /// Sends requests to one oracle process and returns the responses in order.
  static func evaluate(_ requests: [JSON]) throws -> [JSON] {
    let url = try binary.get()
    let input = requests.map(\.rendered).joined(separator: "\n") + "\n"
    let dir = FileManager.default.temporaryDirectory
    let inputFile = dir.appendingPathComponent("cel-diff-\(UUID().uuidString).jsonl")
    try Data(input.utf8).write(to: inputFile)
    defer { try? FileManager.default.removeItem(at: inputFile) }
    let process = Process()
    process.executableURL = url
    process.standardInput = try FileHandle(forReadingFrom: inputFile)
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
    guard lines.count == requests.count else {
      throw OracleUnavailable(
        description: "oracle answered \(lines.count) of \(requests.count) requests (exit \(process.terminationStatus))")
    }
    return try lines.map { try JSON.parse(String($0)) }
  }
}
