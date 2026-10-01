// Environment construction for oracle requests.
//
// The "conformance" profile and celBlockLib are copied from cel-go
// conformance/conformance_test.go (Copyright Google LLC, Apache-2.0) so the oracle answers exactly as cel-go's own
// conformance runner does.

package main

import (
	"fmt"

	"go.yaml.in/yaml/v3"
	"google.golang.org/protobuf/encoding/protojson"

	celpb "cel.dev/expr"
	test2pb "cel.dev/expr/conformance/proto2"
	test3pb "cel.dev/expr/conformance/proto3"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/common/ast"
	"cel.dev/cel-go/common/env"
	"cel.dev/cel-go/common/types"
	"cel.dev/cel-go/ext"
)

// buildEnv returns the environment for a request: the profile's base, then the cel-go env config, then the
// request's container, disable_macros (SimpleTest.disable_macros) and proto declarations.
func buildEnv(req *request) (*cel.Env, error) {
	var opts []cel.EnvOption
	switch req.Profile {
	case "", "default":
		cfg := &env.Config{}
		if len(req.Config) > 0 && string(req.Config) != "null" {
			// The config is cel-go's env.Config, whose field names come from yaml tags. JSON is YAML, so the
			// yaml decoder reads it directly.
			if err := yaml.Unmarshal(req.Config, cfg); err != nil {
				return nil, fmt.Errorf("invalid config: %w", err)
			}
		}
		opts = append(opts, cel.FromConfig(cfg, ext.ExtensionOptionFactory, oracleExtensionFactory))
		if req.TestTypes {
			opts = append(opts, testTypes())
		}
	case "conformance":
		if len(req.Config) > 0 && string(req.Config) != "null" {
			return nil, fmt.Errorf("config is not supported with the conformance profile")
		}
		opts = append(opts, conformanceOptions()...)
	default:
		return nil, fmt.Errorf("unknown profile %q", req.Profile)
	}
	if req.Container != "" {
		opts = append(opts, cel.Container(req.Container))
	}
	if req.DisableMacros {
		opts = append(opts, cel.ClearMacros())
	}
	for i, raw := range req.DeclsProto {
		d := &celpb.Decl{}
		if err := protojson.Unmarshal(raw, d); err != nil {
			return nil, fmt.Errorf("decls_proto[%d]: %w", i, err)
		}
		opt, err := cel.ProtoAsDeclaration(d)
		if err != nil {
			return nil, fmt.Errorf("decls_proto[%d]: %w", i, err)
		}
		opts = append(opts, opt)
	}
	return cel.NewCustomEnv(opts...)
}

func testTypes() cel.EnvOption {
	return cel.Types(&test2pb.TestAllTypes{}, &test2pb.Proto2ExtensionScopedMessage{}, &test3pb.TestAllTypes{})
}

// conformanceOptions mirrors stdOpts plus the standard macros in cel-go conformance_test.go init().
func conformanceOptions() []cel.EnvOption {
	return []cel.EnvOption{
		cel.StdLib(),
		cel.ClearMacros(),
		cel.OptionalTypes(),
		cel.EagerlyValidateDeclarations(true),
		cel.EnableErrorOnBadPresenceTest(true),
		testTypes(),
		ext.Bindings(),
		ext.Encoders(),
		ext.Lists(),
		ext.Math(),
		ext.Protos(),
		ext.Strings(),
		ext.TwoVarComprehensions(),
		cel.Lib(celBlockLib{}),
		cel.EnableIdentifierEscapeSyntax(),
		cel.Macros(cel.StandardMacros...),
	}
}

// oracleExtensionFactory adds extension names that ext.ExtensionOptionFactory does not know.
func oracleExtensionFactory(configElement any) (cel.EnvOption, bool) {
	e, ok := configElement.(*env.Extension)
	if !ok {
		return nil, false
	}
	switch e.Name {
	case "network", "cel.lib.ext.network":
		return ext.Network(), true
	case "block", "cel.lib.ext.cel.block.conformance":
		return cel.Lib(celBlockLib{}), true
	case "test_types":
		return testTypes(), true
	}
	return nil, false
}

type celBlockLib struct{}

func (celBlockLib) LibraryName() string {
	return "cel.lib.ext.cel.block.conformance"
}

func (celBlockLib) CompileOptions() []cel.EnvOption {
	// Simulate indexed arguments which would normally have strong types associated
	// with the values as part of a static optimization pass
	maxIndices := 30
	indexOpts := make([]cel.EnvOption, maxIndices)
	for i := 0; i < maxIndices; i++ {
		indexOpts[i] = cel.Variable(fmt.Sprintf("@index%d", i), cel.DynType)
	}
	return append([]cel.EnvOption{
		cel.Macros(
			// cel.block([args], expr)
			cel.ReceiverMacro("block", 2, celBlock),
			// cel.index(int)
			cel.ReceiverMacro("index", 1, celIndex),
			// cel.iterVar(int, int)
			cel.ReceiverMacro("iterVar", 2, celCompreVar("cel.iterVar", "@it")),
			// cel.accuVar(int, int)
			cel.ReceiverMacro("accuVar", 2, celCompreVar("cel.accuVar", "@ac")),
		),
	}, indexOpts...)
}

func (celBlockLib) ProgramOptions() []cel.ProgramOption {
	return []cel.ProgramOption{}
}

func celBlock(mef cel.MacroExprFactory, target ast.Expr, args []ast.Expr) (ast.Expr, *cel.Error) {
	if !isCELNamespace(target) {
		return nil, nil
	}
	bindings := args[0]
	if bindings.Kind() != ast.ListKind {
		return bindings, mef.NewError(bindings.ID(), "cel.block requires the first arg to be a list literal")
	}
	return mef.NewCall("cel.@block", args...), nil
}

func celIndex(mef cel.MacroExprFactory, target ast.Expr, args []ast.Expr) (ast.Expr, *cel.Error) {
	if !isCELNamespace(target) {
		return nil, nil
	}
	index := args[0]
	if !isNonNegativeInt(index) {
		return index, mef.NewError(index.ID(), "cel.index requires a single non-negative int constant arg")
	}
	indexVal := index.AsLiteral().(types.Int)
	return mef.NewIdent(fmt.Sprintf("@index%d", indexVal)), nil
}

func celCompreVar(funcName, varPrefix string) cel.MacroFactory {
	return func(mef cel.MacroExprFactory, target ast.Expr, args []ast.Expr) (ast.Expr, *cel.Error) {
		if !isCELNamespace(target) {
			return nil, nil
		}
		depth := args[0]
		if !isNonNegativeInt(depth) {
			return depth, mef.NewError(depth.ID(), fmt.Sprintf("%s requires two non-negative int constant args", funcName))
		}
		unique := args[1]
		if !isNonNegativeInt(unique) {
			return unique, mef.NewError(unique.ID(), fmt.Sprintf("%s requires two non-negative int constant args", funcName))
		}
		depthVal := depth.AsLiteral().(types.Int)
		uniqueVal := unique.AsLiteral().(types.Int)
		return mef.NewIdent(fmt.Sprintf("%s:%d:%d", varPrefix, depthVal, uniqueVal)), nil
	}
}

func isCELNamespace(target ast.Expr) bool {
	return target.Kind() == ast.IdentKind && target.AsIdent() == "cel"
}

func isNonNegativeInt(expr ast.Expr) bool {
	if expr.Kind() != ast.LiteralKind {
		return false
	}
	val := expr.AsLiteral()
	return val.Type() == cel.IntType && val.(types.Int) >= 0
}
