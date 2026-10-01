// Copyright 2023 Google LLC
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
// Ported from cel-go common/stdlib/standard.go.

/// The standard library function and type declarations, with their runtime bindings.
package enum StandardLibrary {
  /// The standard function declarations: operators, conversions, string, size, timestamp and
  /// duration functions.
  package static let functions: [FunctionDecl] = makeFunctions()

  /// The standard type identifiers: `bool`, `bytes`, `double`, `google.protobuf.Duration`, `int`,
  /// `list`, `map`, `null_type`, `string`, `google.protobuf.Timestamp`, `type` and `uint`.
  package static let types: [VariableDecl] = {
    let paramA = CELType.typeParam("A")
    let paramB = CELType.typeParam("B")
    return [
      .typeIdentifier(.bool),
      .typeIdentifier(.bytes),
      .typeIdentifier(.double),
      .typeIdentifier(.duration),
      .typeIdentifier(.int),
      .typeIdentifier(.list(paramA)),
      .typeIdentifier(.map(key: paramA, value: paramB)),
      .typeIdentifier(.null),
      .typeIdentifier(.string),
      .typeIdentifier(.timestamp),
      .typeIdentifier(.type(nil)),
      .typeIdentifier(.uint),
    ]
  }()

  private static func makeFunctions() -> [FunctionDecl] {
    do {
      return try declareFunctions()
    } catch {
      preconditionFailure("invalid standard library declaration: \(error)")
    }
  }

  // swift-format-ignore: FunctionLength
  private static func declareFunctions() throws -> [FunctionDecl] {
    typealias O = Overloads
    let paramA = CELType.typeParam("A")
    let paramB = CELType.typeParam("B")
    let listOfA = CELType.list(paramA)
    let mapOfAB = CELType.map(key: paramA, value: paramB)

    func comparison(
      _ name: String, _ docs: String, ids: [String], _ test: @escaping @Sendable (Int64) -> Bool
    ) throws -> FunctionDecl {
      let signatures: [(CELType, CELType)] = [
        (.bool, .bool), (.int, .int), (.int, .double), (.int, .uint), (.uint, .uint),
        (.uint, .double), (.uint, .int), (.double, .double), (.double, .int), (.double, .uint),
        (.string, .string), (.bytes, .bytes), (.timestamp, .timestamp), (.duration, .duration),
      ]
      var options: [FunctionDecl.Option] = [.documentation(docs)]
      for (id, (lhs, rhs)) in zip(ids, signatures) {
        options.append(.overload(id, argTypes: [lhs, rhs], resultType: .bool))
      }
      options.append(
        .singletonBinaryBinding(
          { lhs, rhs in
            if lhs.isNaNDouble || rhs.isNaNDouble {
              return .bool(false)
            }
            let cmp = lhs.compare(rhs)
            if case .int(let c) = cmp {
              return .bool(test(c))
            }
            return cmp
          }, traits: .comparer))
      return try FunctionDecl(name, options: options)
    }

    return [
      // Logical operators. Special-cased within the interpreter.
      // The singleton binding prevents extensions from overriding the operator behavior.
      try FunctionDecl(
        Operators.conditional,
        .documentation(
          "The ternary operator tests a boolean predicate and returns the left-hand side "
            + "(truthy) expression if true, or the right-hand side (falsy) expression if false"),
        .overload(
          O.conditional, argTypes: [.bool, paramA, paramA], resultType: paramA, .nonStrict,
          .examples(
            "'hello'.contains('lo') ? 'hi' : 'bye' // 'hi'",
            "32 % 3 == 0 ? 'divisible' : 'not divisible' // 'not divisible'")),
        .singletonFunctionBinding { _ in .noSuchOverload }),

      try FunctionDecl(
        Operators.logicalAnd,
        .documentation(
          "logically AND two boolean values. Errors and unknown values",
          "are valid inputs and will not halt evaluation."),
        .overload(
          O.logicalAnd, argTypes: [.bool, .bool], resultType: .bool, .nonStrict,
          .examples(
            "true && true   // true", "true && false  // false", "error && true  // error",
            "error && false // false")),
        .singletonBinaryBinding { _, _ in .noSuchOverload }),

      try FunctionDecl(
        Operators.logicalOr,
        .documentation(
          "logically OR two boolean values. Errors and unknown values",
          "are valid inputs and will not halt evaluation."),
        .overload(
          O.logicalOr, argTypes: [.bool, .bool], resultType: .bool, .nonStrict,
          .examples(
            "true || false // true", "false || false // false", "error || true // true",
            "error || error // true")),
        .singletonBinaryBinding { _, _ in .noSuchOverload }),

      try FunctionDecl(
        Operators.logicalNot,
        .documentation("logically negate a boolean value."),
        .overload(
          O.logicalNot, argTypes: [.bool], resultType: .bool,
          .examples("!true // false", "!false // true", "!error // error")),
        .singletonUnaryBinding { val in
          guard case .bool(let b) = val else { return Value.maybeNoSuchOverload(val) }
          return .bool(!b)
        }),

      // Comprehension short-circuiting related function.
      try FunctionDecl(
        Operators.notStrictlyFalse,
        .overload(
          O.notStrictlyFalse, argTypes: [.bool], resultType: .bool, .nonStrict,
          .unaryBinding(notStrictlyFalse))),
      // Deprecated: __not_strictly_false__
      try FunctionDecl(
        Operators.oldNotStrictlyFalse,
        .disableDeclaration(true),
        .overload(
          Operators.oldNotStrictlyFalse, argTypes: [.bool], resultType: .bool, .nonStrict,
          .unaryBinding(notStrictlyFalse))),

      // Equality / inequality. Special-cased in the interpreter.
      try FunctionDecl(
        Operators.equals,
        .documentation("compare two values of the same type for equality"),
        .overload(
          O.equals, argTypes: [paramA, paramA], resultType: .bool,
          .examples(
            "1 == 1 // true", "'hello' == 'world' // false", "bytes('hello') == b'hello' // true",
            "duration('1h') == duration('60m') // true", "dyn(3.0) == 3 // true")),
        .singletonBinaryBinding { _, _ in .noSuchOverload }),
      try FunctionDecl(
        Operators.notEquals,
        .documentation("compare two values of the same type for inequality"),
        .overload(
          O.notEquals, argTypes: [paramA, paramA], resultType: .bool,
          .examples("1 != 2     // true", "\"a\" != \"a\" // false", "3.0 != 3.1 // true")),
        .singletonBinaryBinding { _, _ in .noSuchOverload }),

      // Mathematical operators.
      try FunctionDecl(
        Operators.add,
        .documentation("adds two numeric values or concatenates two strings, bytes,", "or lists."),
        .overload(
          O.addBytes, argTypes: [.bytes, .bytes], resultType: .bytes,
          .examples("b'hi' + bytes('ya') // b'hiya'")),
        .overload(
          O.addDouble, argTypes: [.double, .double], resultType: .double,
          .examples("3.14 + 1.59 // 4.73")),
        .overload(
          O.addDurationDuration, argTypes: [.duration, .duration], resultType: .duration,
          .examples("duration('1m') + duration('1s') // duration('1m1s')")),
        .overload(
          O.addDurationTimestamp, argTypes: [.duration, .timestamp], resultType: .timestamp,
          .examples(
            "duration('24h') + timestamp('2023-01-01T00:00:00Z') // timestamp('2023-01-02T00:00:00Z')"
          )),
        .overload(
          O.addTimestampDuration, argTypes: [.timestamp, .duration], resultType: .timestamp,
          .examples(
            "timestamp('2023-01-01T00:00:00Z') + duration('24h1m2s') // timestamp('2023-01-02T00:01:02Z')"
          )),
        .overload(O.addInt64, argTypes: [.int, .int], resultType: .int, .examples("1 + 2 // 3")),
        .overload(
          O.addList, argTypes: [listOfA, listOfA], resultType: listOfA,
          .examples("[1] + [2, 3] // [1, 2, 3]")),
        .overload(
          O.addString, argTypes: [.string, .string], resultType: .string,
          .examples("\"Hello, \" + \"world!\" // \"Hello, world!\"")),
        .overload(
          O.addUint64, argTypes: [.uint, .uint], resultType: .uint, .examples("22u + 33u // 55u")),
        .singletonBinaryBinding({ lhs, rhs in lhs.add(rhs) }, traits: .adder)),

      try FunctionDecl(
        Operators.divide,
        .documentation("divide two numbers"),
        .overload(
          O.divideDouble, argTypes: [.double, .double], resultType: .double,
          .examples("7.0 / 2.0 // 3.5")),
        .overload(O.divideInt64, argTypes: [.int, .int], resultType: .int, .examples("10 / 2 // 5")),
        .overload(
          O.divideUint64, argTypes: [.uint, .uint], resultType: .uint, .examples("42u / 2u // 21u")),
        .singletonBinaryBinding({ lhs, rhs in lhs.divide(rhs) }, traits: .divider)),

      try FunctionDecl(
        Operators.modulo,
        .documentation("compute the modulus of one integer into another"),
        .overload(O.moduloInt64, argTypes: [.int, .int], resultType: .int, .examples("3 % 2 // 1")),
        .overload(
          O.moduloUint64, argTypes: [.uint, .uint], resultType: .uint, .examples("6u % 3u // 0u")),
        .singletonBinaryBinding({ lhs, rhs in lhs.modulo(rhs) }, traits: .modder)),

      try FunctionDecl(
        Operators.multiply,
        .documentation("multiply two numbers"),
        .overload(
          O.multiplyDouble, argTypes: [.double, .double], resultType: .double,
          .examples("3.5 * 40.0 // 140.0")),
        .overload(
          O.multiplyInt64, argTypes: [.int, .int], resultType: .int, .examples("-2 * 6 // -12")),
        .overload(
          O.multiplyUint64, argTypes: [.uint, .uint], resultType: .uint,
          .examples("13u * 3u // 39u")),
        .singletonBinaryBinding({ lhs, rhs in lhs.multiply(rhs) }, traits: .multiplier)),

      try FunctionDecl(
        Operators.negate,
        .documentation("negate a numeric value"),
        .overload(
          O.negateDouble, argTypes: [.double], resultType: .double, .examples("-(3.14) // -3.14")),
        .overload(O.negateInt64, argTypes: [.int], resultType: .int, .examples("-(5) // -5")),
        .singletonUnaryBinding(
          { val in
            if case .bool = val {
              return Value.maybeNoSuchOverload(val)
            }
            return val.negate()
          }, traits: .negator)),

      try FunctionDecl(
        Operators.subtract,
        .documentation("subtract two numbers, or two time-related values"),
        .overload(
          O.subtractDouble, argTypes: [.double, .double], resultType: .double,
          .examples("10.5 - 2.0 // 8.5")),
        .overload(
          O.subtractDurationDuration, argTypes: [.duration, .duration], resultType: .duration,
          .examples("duration('1m') - duration('1s') // duration('59s')")),
        .overload(O.subtractInt64, argTypes: [.int, .int], resultType: .int, .examples("5 - 3 // 2")),
        .overload(
          O.subtractTimestampDuration, argTypes: [.timestamp, .duration], resultType: .timestamp,
          .examples(
            "timestamp('2023-01-10T12:00:00Z')\n  - duration('12h') // timestamp('2023-01-10T00:00:00Z')"
          )),
        .overload(
          O.subtractTimestampTimestamp, argTypes: [.timestamp, .timestamp], resultType: .duration,
          .examples(
            "timestamp('2023-01-10T12:00:00Z')\n  - timestamp('2023-01-10T00:00:00Z') // duration('12h')"
          )),
        .overload(
          O.subtractUint64, argTypes: [.uint, .uint], resultType: .uint,
          .examples(
            "// the subtraction result must be positive, otherwise an overflow\n// error is generated.\n42u - 3u // 39u"
          )),
        .singletonBinaryBinding({ lhs, rhs in lhs.subtract(rhs) }, traits: .subtractor)),

      // Relations operators.
      try comparison(
        Operators.less, "compare two values and return true if the first value is\nless than the second",
        ids: [
          O.lessBool, O.lessInt64, O.lessInt64Double, O.lessInt64Uint64, O.lessUint64,
          O.lessUint64Double, O.lessUint64Int64, O.lessDouble, O.lessDoubleInt64, O.lessDoubleUint64,
          O.lessString, O.lessBytes, O.lessTimestamp, O.lessDuration,
        ]
      ) { $0 == -1 },
      try comparison(
        Operators.lessEquals,
        "compare two values and return true if the first value is\nless than or equal to the second",
        ids: [
          O.lessEqualsBool, O.lessEqualsInt64, O.lessEqualsInt64Double, O.lessEqualsInt64Uint64,
          O.lessEqualsUint64, O.lessEqualsUint64Double, O.lessEqualsUint64Int64, O.lessEqualsDouble,
          O.lessEqualsDoubleInt64, O.lessEqualsDoubleUint64, O.lessEqualsString, O.lessEqualsBytes,
          O.lessEqualsTimestamp, O.lessEqualsDuration,
        ]
      ) { $0 == -1 || $0 == 0 },
      try comparison(
        Operators.greater,
        "compare two values and return true if the first value is\ngreater than the second",
        ids: [
          O.greaterBool, O.greaterInt64, O.greaterInt64Double, O.greaterInt64Uint64,
          O.greaterUint64, O.greaterUint64Double, O.greaterUint64Int64, O.greaterDouble,
          O.greaterDoubleInt64, O.greaterDoubleUint64, O.greaterString, O.greaterBytes,
          O.greaterTimestamp, O.greaterDuration,
        ]
      ) { $0 == 1 },
      try comparison(
        Operators.greaterEquals,
        "compare two values and return true if the first value is\ngreater than or equal to the second",
        ids: [
          O.greaterEqualsBool, O.greaterEqualsInt64, O.greaterEqualsInt64Double,
          O.greaterEqualsInt64Uint64, O.greaterEqualsUint64, O.greaterEqualsUint64Double,
          O.greaterEqualsUint64Int64, O.greaterEqualsDouble, O.greaterEqualsDoubleInt64,
          O.greaterEqualsDoubleUint64, O.greaterEqualsString, O.greaterEqualsBytes,
          O.greaterEqualsTimestamp, O.greaterEqualsDuration,
        ]
      ) { $0 == 1 || $0 == 0 },

      // Indexing.
      try FunctionDecl(
        Operators.index,
        .documentation("select a value from a list by index, or value from a map by key"),
        .overload(
          O.indexList, argTypes: [listOfA, .int], resultType: paramA,
          .examples("[1, 2, 3][1] // 2")),
        .overload(
          O.indexMap, argTypes: [mapOfAB, paramA], resultType: paramB,
          .examples("{'key': 'value'}['key'] // 'value'", "{'key': 'value'}['missing'] // error")),
        .singletonBinaryBinding({ lhs, rhs in lhs.get(rhs) }, traits: .indexer)),

      // Collections operators.
      try FunctionDecl(
        Operators.in,
        .documentation("test whether a value exists in a list, or a key exists in a map"),
        .overload(
          O.inList, argTypes: [paramA, listOfA], resultType: .bool,
          .examples("2 in [1, 2, 3] // true", "\"a\" in [\"b\", \"c\"] // false")),
        .overload(
          O.inMap, argTypes: [paramA, mapOfAB], resultType: .bool,
          .examples(
            "'key1' in {'key1': 'value1', 'key2': 'value2'} // true",
            "3 in {1: \"one\", 2: \"two\"} // false")),
        .singletonBinaryBinding(inAggregate)),
      try FunctionDecl(
        Operators.oldIn,
        .disableDeclaration(true),
        .overload(O.inList, argTypes: [paramA, listOfA], resultType: .bool),
        .overload(O.inMap, argTypes: [paramA, mapOfAB], resultType: .bool),
        .singletonBinaryBinding(inAggregate)),
      try FunctionDecl(
        O.deprecatedIn,
        .disableDeclaration(true),
        .overload(O.inList, argTypes: [paramA, listOfA], resultType: .bool),
        .overload(O.inMap, argTypes: [paramA, mapOfAB], resultType: .bool),
        .singletonBinaryBinding(inAggregate)),

      try FunctionDecl(
        O.size,
        .documentation(
          "compute the size of a list or map, the number of characters in a string,",
          "or the number of bytes in a sequence"),
        .overload(
          O.sizeBytes, argTypes: [.bytes], resultType: .int, .examples("size(b'123') // 3")),
        .memberOverload(
          O.sizeBytesInst, argTypes: [.bytes], resultType: .int, .examples("b'123'.size() // 3")),
        .overload(
          O.sizeList, argTypes: [listOfA], resultType: .int, .examples("size([1, 2, 3]) // 3")),
        .memberOverload(
          O.sizeListInst, argTypes: [listOfA], resultType: .int,
          .examples("[1, 2, 3].size() // 3")),
        .overload(
          O.sizeMap, argTypes: [mapOfAB], resultType: .int,
          .examples("size({'a': 1, 'b': 2}) // 2")),
        .memberOverload(
          O.sizeMapInst, argTypes: [mapOfAB], resultType: .int,
          .examples("{'a': 1, 'b': 2}.size() // 2")),
        .overload(
          O.sizeString, argTypes: [.string], resultType: .int, .examples("size('hello') // 5")),
        .memberOverload(
          O.sizeStringInst, argTypes: [.string], resultType: .int,
          .examples("'hello'.size() // 5")),
        .singletonUnaryBinding({ val in val.size() }, traits: .sizer)),

      // Type conversions.
      try FunctionDecl(
        O.typeConvertType,
        .documentation("convert a value to its type identifier"),
        .overload(
          O.typeConvertType, argTypes: [paramA], resultType: .type(paramA),
          .examples("type(1) // int", "type('hello') // string", "type(int) // type", "type(type) // type")),
        .singletonUnaryBinding(convertToType(.type(nil)))),

      // Bool conversions.
      try FunctionDecl(
        O.typeConvertBool,
        .documentation("convert a value to a boolean"),
        .overload(
          O.boolToBool, argTypes: [.bool], resultType: .bool, .examples("bool(true) // true"),
          .unaryBinding(identity)),
        .overload(
          O.stringToBool, argTypes: [.string], resultType: .bool,
          .examples("bool('true') // true", "bool('false') // false"),
          .unaryBinding(convertToType(.bool)))),

      // Bytes conversions.
      try FunctionDecl(
        O.typeConvertBytes,
        .documentation("convert a value to bytes"),
        .overload(
          O.bytesToBytes, argTypes: [.bytes], resultType: .bytes,
          .examples("bytes(b'abc') // b'abc'"), .unaryBinding(identity)),
        .overload(
          O.stringToBytes, argTypes: [.string], resultType: .bytes,
          .examples("bytes('hello') // b'hello'"), .unaryBinding(convertToType(.bytes)))),

      // Double conversions.
      try FunctionDecl(
        O.typeConvertDouble,
        .documentation("convert a value to a double"),
        .overload(
          O.doubleToDouble, argTypes: [.double], resultType: .double,
          .examples("double(1.23) // 1.23"), .unaryBinding(identity)),
        .overload(
          O.intToDouble, argTypes: [.int], resultType: .double, .examples("double(123) // 123.0"),
          .unaryBinding(convertToType(.double))),
        .overload(
          O.stringToDouble, argTypes: [.string], resultType: .double,
          .examples("double('1.23') // 1.23"), .unaryBinding(convertToType(.double))),
        .overload(
          O.uintToDouble, argTypes: [.uint], resultType: .double,
          .examples("double(123u) // 123.0"), .unaryBinding(convertToType(.double)))),

      // Duration conversions.
      try FunctionDecl(
        O.typeConvertDuration,
        .documentation("convert a value to a google.protobuf.Duration"),
        .overload(
          O.durationToDuration, argTypes: [.duration], resultType: .duration,
          .examples("duration(duration('1s')) // duration('1s')"), .unaryBinding(identity)),
        .overload(
          O.stringToDuration, argTypes: [.string], resultType: .duration,
          .examples("duration('1h2m3s') // duration('3723s')"),
          .unaryBinding(convertToType(.duration)))),

      // Dyn conversions.
      try FunctionDecl(
        O.typeConvertDyn,
        .documentation("indicate that the type is dynamic for type-checking purposes"),
        .overload(O.toDyn, argTypes: [paramA], resultType: .dyn, .examples("dyn(1) // 1")),
        .singletonUnaryBinding(identity)),

      // Int conversions.
      try FunctionDecl(
        O.typeConvertInt,
        .documentation("convert a value to an int"),
        .overload(
          O.intToInt, argTypes: [.int], resultType: .int, .examples("int(123) // 123"),
          .unaryBinding(identity)),
        .overload(
          O.doubleToInt, argTypes: [.double], resultType: .int, .examples("int(123.45) // 123"),
          .unaryBinding(convertToType(.int))),
        .overload(
          O.durationToInt, argTypes: [.duration], resultType: .int,
          .examples("int(duration('1s')) // 1000000000"), .unaryBinding(convertToType(.int))),
        .overload(
          O.stringToInt, argTypes: [.string], resultType: .int,
          .examples("int('123') // 123", "int('-456') // -456"),
          .unaryBinding(convertToType(.int))),
        .overload(
          O.timestampToInt, argTypes: [.timestamp], resultType: .int,
          .examples("int(timestamp('1970-01-01T00:00:01Z')) // 1"),
          .unaryBinding(convertToType(.int))),
        .overload(
          O.uintToInt, argTypes: [.uint], resultType: .int, .examples("int(123u) // 123"),
          .unaryBinding(convertToType(.int)))),

      // String conversions.
      try FunctionDecl(
        O.typeConvertString,
        .documentation("convert a value to a string"),
        .overload(
          O.stringToString, argTypes: [.string], resultType: .string,
          .examples("string('hello') // 'hello'"), .unaryBinding(identity)),
        .overload(
          O.boolToString, argTypes: [.bool], resultType: .string,
          .examples("string(true) // 'true'"), .unaryBinding(convertToType(.string))),
        .overload(
          O.bytesToString, argTypes: [.bytes], resultType: .string,
          .examples("string(b'hello') // 'hello'"), .unaryBinding(convertToType(.string))),
        .overload(
          O.doubleToString, argTypes: [.double], resultType: .string,
          .unaryBinding(convertToType(.string)), .examples("string(-1.23e4) // '-12300'")),
        .overload(
          O.durationToString, argTypes: [.duration], resultType: .string,
          .examples("string(duration('1h30m')) // '5400s'"), .unaryBinding(convertToType(.string))),
        .overload(
          O.intToString, argTypes: [.int], resultType: .string,
          .examples("string(-123) // '-123'"), .unaryBinding(convertToType(.string))),
        .overload(
          O.timestampToString, argTypes: [.timestamp], resultType: .string,
          .examples("string(timestamp('1970-01-01T00:00:00Z')) // '1970-01-01T00:00:00Z'"),
          .unaryBinding(convertToType(.string))),
        .overload(
          O.uintToString, argTypes: [.uint], resultType: .string,
          .examples("string(123u) // '123'"), .unaryBinding(convertToType(.string)))),

      // Timestamp conversions.
      try FunctionDecl(
        O.typeConvertTimestamp,
        .documentation("convert a value to a google.protobuf.Timestamp"),
        .overload(
          O.timestampToTimestamp, argTypes: [.timestamp], resultType: .timestamp,
          .examples(
            "timestamp(timestamp('2023-01-01T00:00:00Z')) // timestamp('2023-01-01T00:00:00Z')"),
          .unaryBinding(identity)),
        .overload(
          O.intToTimestamp, argTypes: [.int], resultType: .timestamp,
          .examples("timestamp(1) // timestamp('1970-01-01T00:00:01Z')"),
          .unaryBinding(convertToType(.timestamp))),
        .overload(
          O.stringToTimestamp, argTypes: [.string], resultType: .timestamp,
          .examples("timestamp('2025-01-01T12:34:56Z') // timestamp('2025-01-01T12:34:56Z')"),
          .unaryBinding(convertToType(.timestamp)))),

      // Uint conversions.
      try FunctionDecl(
        O.typeConvertUint,
        .documentation("convert a value to a uint"),
        .overload(
          O.uintToUint, argTypes: [.uint], resultType: .uint, .examples("uint(123u) // 123u"),
          .unaryBinding(identity)),
        .overload(
          O.doubleToUint, argTypes: [.double], resultType: .uint,
          .examples("uint(123.45) // 123u"), .unaryBinding(convertToType(.uint))),
        .overload(
          O.intToUint, argTypes: [.int], resultType: .uint, .examples("uint(123) // 123u"),
          .unaryBinding(convertToType(.uint))),
        .overload(
          O.stringToUint, argTypes: [.string], resultType: .uint,
          .examples("uint('123') // 123u"), .unaryBinding(convertToType(.uint)))),

      // String functions.
      try FunctionDecl(
        O.contains,
        .documentation("test whether a string contains a substring"),
        .memberOverload(
          O.containsString, argTypes: [.string, .string], resultType: .bool,
          .examples(
            "'hello world'.contains('o w') // true", "'hello world'.contains('goodbye') // false"),
          .binaryBinding(stringContains)),
        .disableTypeGuards(true)),
      try FunctionDecl(
        O.endsWith,
        .documentation("test whether a string ends with a substring suffix"),
        .memberOverload(
          O.endsWithString, argTypes: [.string, .string], resultType: .bool,
          .examples(
            "'hello world'.endsWith('world') // true", "'hello world'.endsWith('hello') // false"),
          .binaryBinding(stringEndsWith)),
        .disableTypeGuards(true)),
      try FunctionDecl(
        O.startsWith,
        .documentation("test whether a string starts with a substring prefix"),
        .memberOverload(
          O.startsWithString, argTypes: [.string, .string], resultType: .bool,
          .examples(
            "'hello world'.startsWith('hello') // true",
            "'hello world'.startsWith('world') // false"),
          .binaryBinding(stringStartsWith)),
        .disableTypeGuards(true)),
      try FunctionDecl(
        O.matches,
        .documentation("test whether a string matches an RE2 regular expression"),
        .overload(
          O.matches, argTypes: [.string, .string], resultType: .bool,
          .examples(
            "matches('123-456', '^[0-9]+(-[0-9]+)?$') // true", "matches('hello', '^h.*o$') // true")),
        .memberOverload(
          O.matchesString, argTypes: [.string, .string], resultType: .bool,
          .examples(
            "'123-456'.matches('^[0-9]+(-[0-9]+)?$') // true", "'hello'.matches('^h.*o$') // true")),
        .singletonBinaryBinding({ str, pattern in str.match(pattern) }, traits: .matcher)),

      // Timestamp / duration functions.
      try timestampAccessor(
        O.timeGetFullYear,
        "get the 0-based full year from a timestamp, UTC unless an IANA timezone is specified.",
        O.timestampToYear, O.timestampToYearWithTz,
        examples: (
          "timestamp('2023-07-14T10:30:45.123Z').getFullYear() // 2023",
          "timestamp('2023-01-01T05:30:00Z').getFullYear('-08:00') // 2022"
        )
      ) { $0.year },
      try timestampAccessor(
        O.timeGetMonth,
        "get the 0-based month from a timestamp, UTC unless an IANA timezone is specified.",
        O.timestampToMonth, O.timestampToMonthWithTz,
        examples: (
          "timestamp('2023-07-14T10:30:45.123Z').getMonth() // 6",
          "timestamp('2023-01-01T05:30:00Z').getMonth('America/Los_Angeles') // 11"
        )
      ) { $0.month - 1 },
      try timestampAccessor(
        O.timeGetDayOfYear,
        "get the 0-based day of the year from a timestamp, UTC unless an IANA timezone is specified.",
        O.timestampToDayOfYear, O.timestampToDayOfYearWithTz,
        examples: (
          "timestamp('2023-01-02T00:00:00Z').getDayOfYear() // 1",
          "timestamp('2023-01-01T05:00:00Z').getDayOfYear('America/Los_Angeles') // 364"
        )
      ) { $0.yearDay - 1 },
      try timestampAccessor(
        O.timeGetDayOfMonth,
        "get the 0-based day of the month from a timestamp, UTC unless an IANA timezone is specified.",
        O.timestampToDayOfMonthZeroBased, O.timestampToDayOfMonthZeroBasedWithTz,
        examples: (
          "timestamp('2023-07-14T10:30:45.123Z').getDayOfMonth() // 13",
          "timestamp('2023-07-01T05:00:00Z').getDayOfMonth('America/Los_Angeles') // 29"
        )
      ) { $0.day - 1 },
      try timestampAccessor(
        O.timeGetDate,
        "get the 1-based day of the month from a timestamp, UTC unless an IANA timezone is specified.",
        O.timestampToDayOfMonthOneBased, O.timestampToDayOfMonthOneBasedWithTz,
        examples: (
          "timestamp('2023-07-14T10:30:45.123Z').getDate() // 14",
          "timestamp('2023-07-01T05:00:00Z').getDate('America/Los_Angeles') // 30"
        )
      ) { $0.day },
      try timestampAccessor(
        O.timeGetDayOfWeek,
        "get the 0-based day of the week from a timestamp, UTC unless an IANA timezone is specified.",
        O.timestampToDayOfWeek, O.timestampToDayOfWeekWithTz,
        examples: (
          "timestamp('2023-07-14T10:30:45.123Z').getDayOfWeek() // 5",
          "timestamp('2023-07-16T05:00:00Z').getDayOfWeek('America/Los_Angeles') // 6"
        )
      ) { $0.weekday },
      try timestampAccessor(
        O.timeGetHours, "get the hours portion from a timestamp, or convert a duration to hours",
        O.timestampToHours, O.timestampToHoursWithTz,
        examples: (
          "timestamp('2023-07-14T10:30:45.123Z').getHours() // 10",
          "timestamp('2023-07-14T10:30:45.123Z').getHours('America/Los_Angeles') // 2"
        ),
        duration: (O.durationToHours, "duration('3723s').getHours() // 1", { $0.hours })
      ) { $0.hour },
      try timestampAccessor(
        O.timeGetMinutes,
        "get the minutes portion from a timestamp, or convert a duration to minutes",
        O.timestampToMinutes, O.timestampToMinutesWithTz,
        examples: (
          "timestamp('2023-07-14T10:30:45.123Z').getMinutes() // 30",
          "timestamp('2023-07-14T10:30:45.123Z').getMinutes('America/Los_Angeles') // 30"
        ),
        duration: (O.durationToMinutes, "duration('3723s').getMinutes() // 62", { $0.minutes })
      ) { $0.minute },
      try timestampAccessor(
        O.timeGetSeconds,
        "get the seconds portion from a timestamp, or convert a duration to seconds",
        O.timestampToSeconds, O.timestampToSecondsWithTz,
        examples: (
          "timestamp('2023-07-14T10:30:45.123Z').getSeconds() // 45",
          "timestamp('2023-07-14T10:30:45.123Z').getSeconds('America/Los_Angeles') // 45"
        ),
        duration: (O.durationToSeconds, "duration('3723.456s').getSeconds() // 3723", { $0.seconds })
      ) { $0.second },
      try timestampAccessor(
        O.timeGetMilliseconds, "get the milliseconds portion from a timestamp",
        O.timestampToMilliseconds, O.timestampToMillisecondsWithTz,
        examples: (
          "timestamp('2023-07-14T10:30:45.123Z').getMilliseconds() // 123",
          "timestamp('2023-07-14T10:30:45.123Z').getMilliseconds('America/Los_Angeles') // 123"
        ),
        // The spec's milliseconds portion, not cel-go's conversion (docs/divergences.md).
        duration: (O.durationToMilliseconds, nil, { $0.millisecondsOfSecond })
      ) { $0.nanosecond / 1_000_000 },
    ]
  }

  /// Declares a timestamp accessor with UTC and time zone overloads and, for the time-of-day
  /// accessors, the duration overload.
  private static func timestampAccessor(
    _ name: String,
    _ docs: String,
    _ utcID: String,
    _ tzID: String,
    examples: (String, String),
    duration: (id: String, example: String?, accessor: @Sendable (CELDuration) -> Int64)? = nil,
    _ field: @escaping @Sendable (CivilTime) -> Int64
  ) throws -> FunctionDecl {
    var options: [FunctionDecl.Option] = [
      .documentation(docs),
      .memberOverload(
        utcID, argTypes: [.timestamp], resultType: .int, .examples(examples.0),
        .unaryBinding { ts in timestampField(ts, .string("UTC"), field) }),
      .memberOverload(
        tzID, argTypes: [.timestamp, .string], resultType: .int, .examples(examples.1),
        .binaryBinding { ts, tz in timestampField(ts, tz, field) }),
    ]
    if let duration {
      let accessor = duration.accessor
      var durationOptions: [OverloadDecl.Option] = []
      if let example = duration.example {
        durationOptions.append(.examples(example))
      }
      durationOptions.append(
        .unaryBinding { val in
          guard case .duration(let d) = val else { return Value.maybeNoSuchOverload(val) }
          return .int(accessor(d))
        })
      options.append(
        .overload(
          try OverloadDecl(
            id: duration.id, argTypes: [.duration], resultType: .int, isMemberFunction: true,
            options: durationOptions)))
    }
    return try FunctionDecl(name, options: options)
  }
}

// MARK: - Binding implementations

private func notStrictlyFalse(_ value: Value) -> Value {
  if case .bool = value {
    return value
  }
  return .bool(true)
}

private func inAggregate(_ lhs: Value, _ rhs: Value) -> Value {
  if rhs.traits.contains(.container) {
    return rhs.contains(lhs)
  }
  return Value.valOrError(rhs, "no such overload")
}

private func identity(_ value: Value) -> Value {
  value
}

private func convertToType(_ type: CELType) -> FunctionBinding.Unary {
  { value in value.convert(to: type) }
}

/// Port of cel-go `timestampGet*` with `inTimeZone`.
private func timestampField(
  _ ts: Value, _ tz: Value, _ field: (CivilTime) -> Int64
) -> Value {
  guard case .timestamp(let t) = ts, case .string(let zone) = tz else {
    return .noSuchOverload
  }
  switch timeZoneOffset(zone, at: t) {
  case .success(let offset):
    return .int(field(t.civil(offsetSeconds: offset)))
  case .failure(let err):
    return .error(err)
  }
}

extension Value {
  var isNaNDouble: Bool {
    if case .double(let d) = self { return d.isNaN }
    return false
  }
}
