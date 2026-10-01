# Using protobuf messages

Generate CEL descriptions for your `.proto` files, register them, and pass messages in and out of
expressions.

## Overview

The examples use `google.expr.proto3.test.TestAllTypes`, cel-go's test message, in place of your
own; its Swift type is `Google_Expr_Proto3_Test_TestAllTypes`.

### Generate the descriptions

Build the plugin from this package (`swift build -c release --product protoc-gen-cel-swift`) and run
it with the same options as `protoc-gen-swift`, so the two outputs sit side by side:

```sh
protoc --swift_out=Sources/MyProtos --cel-swift_out=Sources/MyProtos \
  --swift_opt=Visibility=Public --cel-swift_opt=Visibility=Public \
  --plugin=protoc-gen-cel-swift=.build/release/protoc-gen-cel-swift \
  my/package/orders.proto
```

For `my/package/orders.proto` in package `my.package` it writes `my/package/orders.cel.swift`,
holding the constant `My_Package_Orders_CELFile` (swift-protobuf's type prefix, the file name and
`_CELFile`): a ``ProtobufFile`` with the file's messages, enums and extensions. The plugin accepts
`Visibility`, `FileNaming` and `ProtoPathModuleMappings` as `protoc-gen-swift` does.

### Register the types

``ProtobufTypes`` takes the generated files. Registering a file also registers the files it imports,
and the well-known types are always there. Add it to an environment with
`Environment.Option.typeProvider(_:)`; set the container to refer to messages by their short names:

```swift
import CEL
import CELProtobuf

let protos = ProtobufTypes(files: [Google_Expr_Proto3_Test_TestAllTypes_CELFile])
let env = try Environment(
  .typeProvider(protos),
  .container("google.expr.proto3.test"),
  .variable("msg", .objectType("google.expr.proto3.test.TestAllTypes"))
)
```

### Pass messages in

``ProtobufTypes/value(of:)`` wraps a message as a CEL value; its fields are converted only when an
expression reads them:

```swift
var message = Google_Expr_Proto3_Test_TestAllTypes()
message.singleInt64 = 7
message.repeatedString = ["a", "b"]

let program = try env.program(env.compile("msg.single_int64 > 5 && 'b' in msg.repeated_string"))
print(try program.evaluate(["msg": protos.value(of: message)]).value)   // true
```

Unset fields read as their defaults, and `has(msg.field)` tests presence with protobuf's rules.

### Get messages out

Expressions can construct messages. ``ProtobufTypes/message(from:as:)`` converts a result back to
the generated Swift type, and throws an `EvalError` when the value is not of that type:

```swift
let built = try env.program(env.compile("TestAllTypes{single_string: 'hi', single_int32: 3}"))
let value = try built.evaluate().value
let result = try protos.message(from: value, as: Google_Expr_Proto3_Test_TestAllTypes.self)
print(result.singleString, result.singleInt32)   // hi 3
```

### Options

``ProtobufTypes/init(files:jsonFieldNames:strongEnums:)`` selects fields by their JSON names
(`singleInt64`) with `jsonFieldNames`, and reads enum values as values of their enum type instead
of `int`s with `strongEnums`, which `Environment.Option.strongEnums` also turns on for the
environment's types.
