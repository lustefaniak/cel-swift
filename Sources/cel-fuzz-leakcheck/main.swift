// Replays fuzz inputs through a target's body without libFuzzer and reports the resident memory after
// each round, so a per-input leak shows as growth between rounds, and the slowest inputs. On macOS run it under
// `leaks --atExit --` to name the leaked objects and their retain cycles. Not a ported file; see
// Fuzz/README.md.
//
//   cel-fuzz-leakcheck <parser|checker|evaluator> <rounds> <file or directory>...

import CELFuzzSupport
import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// The resident set size in MB.
func residentMB() -> Int {
  #if canImport(Darwin)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? Int(info.resident_size) / 1_048_576 : -1
  #else
    // /proc/self/statm: total and resident pages.
    guard let statm = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else { return -1 }
    let fields = statm.split(separator: " ")
    guard fields.count > 1, let pages = Int(fields[1]) else { return -1 }
    return pages * Int(sysconf(Int32(_SC_PAGESIZE))) / 1_048_576
  #endif
}

let arguments = CommandLine.arguments
guard arguments.count >= 4, let target = FuzzTarget(rawValue: arguments[1]), let rounds = Int(arguments[2]) else {
  print("usage: cel-fuzz-leakcheck <parser|checker|evaluator> <rounds> <file or directory>...")
  exit(2)
}

var inputs: [(path: String, text: String)] = []
for path in arguments[3...] {
  var isDirectory: ObjCBool = false
  guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
  let files =
    isDirectory.boolValue
    ? ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted().map { path + "/" + $0 } : [path]
  for file in files {
    if let data = FileManager.default.contents(atPath: file) {
      inputs.append((file, String(decoding: data, as: UTF8.self)))
    }
  }
}

print("\(target.rawValue): \(inputs.count) inputs, rss \(residentMB()) MB")
let clock = ContinuousClock()
var slowest: [(Duration, String)] = []
for round in 1...max(rounds, 1) {
  for input in inputs {
    let elapsed = clock.measure { target.run(input.text) }
    if round == 1 {
      slowest.append((elapsed, input.path))
    }
  }
  print("round \(round): rss \(residentMB()) MB")
}
print("slowest inputs (first round):")
for (elapsed, path) in slowest.sorted(by: { $0.0 > $1.0 }).prefix(5) {
  print("  \(elapsed) \(path)")
}
