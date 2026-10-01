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

// Ported from cel-go ext/extension_option_factory.go (ExtensionOptionFactory, the names config
// files use for extensions).

import CEL
import CELExtensions

/// The extension libraries a policy environment config can name (cel-go
/// `ext.ExtensionOptionFactory`).
enum PolicyExtensions {
  static let aliases: [String: String] = [
    "bindings": "cel.lib.ext.cel.bindings",
    "encoders": "cel.lib.ext.encoders",
    "lists": "cel.lib.ext.lists",
    "math": "cel.lib.ext.math",
    "protos": "cel.lib.ext.protos",
    "sets": "cel.lib.ext.sets",
    "strings": "cel.lib.ext.strings",
    "two-var-comprehensions": "cel.lib.ext.comprev2",
    "regex": "cel.lib.ext.regex",
  ]

  static func resolve(_ name: String, version: UInt32) -> Library? {
    switch aliases[name] ?? name {
    case "cel.lib.ext.cel.bindings": return .bindings(version: version)
    case "cel.lib.ext.encoders": return .encoders(version: version)
    case "cel.lib.ext.lists": return .lists(version: version)
    case "cel.lib.ext.math": return .math(version: version)
    case "cel.lib.ext.protos": return .protos(version: version)
    case "cel.lib.ext.sets": return .sets(version: version)
    case "cel.lib.ext.strings": return .strings(version: version)
    case "cel.lib.ext.comprev2": return .twoVarComprehensions(version: version)
    case "cel.lib.ext.regex": return .regex(version: version)
    default: return nil
    }
  }
}
