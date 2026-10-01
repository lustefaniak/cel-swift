module github.com/lustefaniak/cel-swift/tools/test-types

go 1.23.0

require (
	cel.dev/cel-go v0.32.0
	cel.dev/expr v0.25.1
	google.golang.org/protobuf v1.36.10
)

require (
	google.golang.org/genproto/googleapis/api v0.0.0-20240826202546-f6391c0de4c7 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20240826202546-f6391c0de4c7 // indirect
)

replace cel.dev/cel-go => ../../third_party/cel-go
