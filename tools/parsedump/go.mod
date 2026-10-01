module github.com/lustefaniak/cel-swift/tools/parsedump

go 1.23.0

require (
	cel.dev/cel-go v0.32.0
	cel.dev/expr v0.25.1
	google.golang.org/protobuf v1.36.10
)

require (
	github.com/antlr4-go/antlr/v4 v4.13.1 // indirect
	golang.org/x/exp v0.0.0-20240823005443-9b4947da3948 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20240826202546-f6391c0de4c7 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20240826202546-f6391c0de4c7 // indirect
)

replace cel.dev/cel-go => ../../third_party/cel-go
