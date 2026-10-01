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
//
// Ported from cel-go common/types/traits/traits.go.

/// The capabilities of a type's values, used by function bindings to dispatch on an operand trait.
public struct TypeTraits: OptionSet, Sendable, Hashable {
  /// The raw bit mask, with the same bit positions as cel-go's `traits` package.
  public let rawValue: Int

  /// Creates a trait set from its raw bit mask.
  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  /// Types with a `+` operator overload.
  public static let adder = TypeTraits(rawValue: 1 << 0)
  /// Types supporting the ordering operators `<`, `<=`, `>`, `>=`.
  public static let comparer = TypeTraits(rawValue: 1 << 1)
  /// Types supporting `in`.
  public static let container = TypeTraits(rawValue: 1 << 2)
  /// Types supporting `/`.
  public static let divider = TypeTraits(rawValue: 1 << 3)
  /// Types supporting field presence tests.
  public static let fieldTester = TypeTraits(rawValue: 1 << 4)
  /// Types supporting index access with dynamic values.
  public static let indexer = TypeTraits(rawValue: 1 << 5)
  /// Types that can be iterated over in comprehensions.
  public static let iterable = TypeTraits(rawValue: 1 << 6)
  /// Iterator types.
  public static let iterator = TypeTraits(rawValue: 1 << 7)
  /// Types supporting `matches`.
  public static let matcher = TypeTraits(rawValue: 1 << 8)
  /// Types supporting `%`.
  public static let modder = TypeTraits(rawValue: 1 << 9)
  /// Types supporting `*`.
  public static let multiplier = TypeTraits(rawValue: 1 << 10)
  /// Types supporting negation with `!` or `-`.
  public static let negator = TypeTraits(rawValue: 1 << 11)
  /// Types supporting dynamic dispatch to instance methods.
  public static let receiver = TypeTraits(rawValue: 1 << 12)
  /// Types supporting `size()`.
  public static let sizer = TypeTraits(rawValue: 1 << 13)
  /// Types supporting `-`.
  public static let subtractor = TypeTraits(rawValue: 1 << 14)
  /// Types supporting two-variable comprehensions over (key, value) pairs.
  public static let foldable = TypeTraits(rawValue: 1 << 15)

  /// The traits of list values.
  public static let lister: TypeTraits = [.adder, .container, .indexer, .iterable, .sizer]
  /// The traits of map values.
  public static let mapper: TypeTraits = [.container, .indexer, .iterable, .sizer]
}
