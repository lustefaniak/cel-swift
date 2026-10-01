// Command parsedump records cel-go's parser behaviour as JSON fixtures for the Swift parser tests.
//
// It writes three files into the output directory (default ../../Tests/CELTests/ParserFixtures):
//
//   - parser_test_cases.json: the testCases table of cel-go parser/parser_test.go and the TestUnparse
//     table of parser/unparser_test.go, extracted from the Go sources (options as source text).
//   - parse_conformance.json: every `expr` of the cel-spec simple conformance tests, parsed by cel-go.
//   - parse_fuzz.json: deterministic mutations of those expressions, parsed by cel-go, to pin down
//     error messages and error recovery.
//
// Usage: go run . [-out DIR] [-fuzz N]
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"math/rand"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"google.golang.org/protobuf/encoding/prototext"

	"cel.dev/cel-go/common"
	celast "cel.dev/cel-go/common/ast"
	"cel.dev/cel-go/common/debug"
	"cel.dev/cel-go/common/types"
	celparser "cel.dev/cel-go/parser"

	// Register the conformance test messages referenced from the textprotos.
	_ "cel.dev/expr/conformance/proto2"
	_ "cel.dev/expr/conformance/proto3"
	conformancetest "cel.dev/expr/conformance/test"
)

const (
	celGoDir   = "../../third_party/cel-go"
	celSpecDir = "../../third_party/cel-spec"
)

func main() {
	out := flag.String("out", "../../Tests/CELTests/ParserFixtures", "output directory")
	fuzzCount := flag.Int("fuzz", 3000, "number of fuzz cases")
	flag.Parse()
	if err := os.MkdirAll(*out, 0o755); err != nil {
		fail(err)
	}
	cases := extractTestCases()
	writeJSON(filepath.Join(*out, "parser_test_cases.json"), cases)
	conf := conformanceRecords()
	writeJSON(filepath.Join(*out, "parse_conformance.json"), conf)
	seeds := []string{}
	for _, r := range conf {
		seeds = append(seeds, r.Expr)
	}
	for _, c := range cases.Parser {
		seeds = append(seeds, c.I)
	}
	writeJSON(filepath.Join(*out, "parse_fuzz.json"), fuzzRecords(seeds, *fuzzCount))
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

func writeJSON(path string, v any) {
	f, err := os.Create(path)
	if err != nil {
		fail(err)
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", " ")
	if err := enc.Encode(v); err != nil {
		fail(err)
	}
}

// ---------------------------------------------------------------------------------------------
// Test table extraction

type parserCase struct {
	I    string   `json:"i"`
	P    string   `json:"p,omitempty"`
	E    string   `json:"e,omitempty"`
	L    string   `json:"l,omitempty"`
	M    string   `json:"m,omitempty"`
	Opts []string `json:"opts,omitempty"`
}

type unparserCase struct {
	Name               string   `json:"name"`
	In                 string   `json:"in"`
	Out                *string  `json:"out,omitempty"`
	RequiresMacroCalls bool     `json:"requiresMacroCalls,omitempty"`
	Options            []string `json:"options,omitempty"`
}

type testCases struct {
	Parser   []parserCase   `json:"parser"`
	Unparser []unparserCase `json:"unparser"`
}

func extractTestCases() testCases {
	var tc testCases
	src, file := parseGoFile(filepath.Join(celGoDir, "parser/parser_test.go"))
	ast.Inspect(file, func(n ast.Node) bool {
		vs, ok := n.(*ast.ValueSpec)
		if !ok || len(vs.Names) != 1 || vs.Names[0].Name != "testCases" {
			return true
		}
		lit := vs.Values[0].(*ast.CompositeLit)
		for _, elt := range lit.Elts {
			var c parserCase
			for _, f := range elt.(*ast.CompositeLit).Elts {
				kv := f.(*ast.KeyValueExpr)
				switch kv.Key.(*ast.Ident).Name {
				case "I":
					c.I = stringValue(kv.Value)
				case "P":
					c.P = stringValue(kv.Value)
				case "E":
					c.E = stringValue(kv.Value)
				case "L":
					c.L = stringValue(kv.Value)
				case "M":
					c.M = stringValue(kv.Value)
				case "Opts":
					c.Opts = sourceList(src, kv.Value)
				}
			}
			tc.Parser = append(tc.Parser, c)
		}
		return false
	})

	src, file = parseGoFile(filepath.Join(celGoDir, "parser/unparser_test.go"))
	ast.Inspect(file, func(n ast.Node) bool {
		fd, ok := n.(*ast.FuncDecl)
		if !ok || fd.Name.Name != "TestUnparse" {
			return true
		}
		assign := fd.Body.List[0].(*ast.AssignStmt)
		lit := assign.Rhs[0].(*ast.CompositeLit)
		for _, elt := range lit.Elts {
			var c unparserCase
			for _, f := range elt.(*ast.CompositeLit).Elts {
				kv := f.(*ast.KeyValueExpr)
				switch kv.Key.(*ast.Ident).Name {
				case "name":
					c.Name = stringValue(kv.Value)
				case "in":
					c.In = stringValue(kv.Value)
				case "out":
					s := stringValue(kv.Value)
					c.Out = &s
				case "requiresMacroCalls":
					c.RequiresMacroCalls = kv.Value.(*ast.Ident).Name == "true"
				case "unparserOptions":
					c.Options = sourceList(src, kv.Value)
				}
			}
			tc.Unparser = append(tc.Unparser, c)
		}
		return false
	})
	for _, c := range tc.Parser {
		if !utf8.ValidString(c.I) {
			fail(fmt.Errorf("parser test input is not valid UTF-8: %q", c.I))
		}
	}
	return tc
}

func parseGoFile(path string) ([]byte, *ast.File) {
	src, err := os.ReadFile(path)
	if err != nil {
		fail(err)
	}
	file, err := parser.ParseFile(token.NewFileSet(), path, src, 0)
	if err != nil {
		fail(err)
	}
	return src, file
}

func stringValue(e ast.Expr) string {
	switch v := e.(type) {
	case *ast.BasicLit:
		s, err := strconv.Unquote(v.Value)
		if err != nil {
			fail(err)
		}
		return s
	case *ast.BinaryExpr:
		if v.Op == token.ADD {
			return stringValue(v.X) + stringValue(v.Y)
		}
	case *ast.ParenExpr:
		return stringValue(v.X)
	}
	fail(fmt.Errorf("unsupported string expression %T", e))
	return ""
}

func sourceList(src []byte, e ast.Expr) []string {
	lit := e.(*ast.CompositeLit)
	var out []string
	for _, elt := range lit.Elts {
		// Positions are 1-based offsets into the file when the FileSet holds a single file.
		out = append(out, string(src[elt.Pos()-1:elt.End()-1]))
	}
	return out
}

// ---------------------------------------------------------------------------------------------
// Parsing and recording

// Parser configurations shared with the Swift test.
//
//	0: standard macros, optional syntax, identifier escapes, macro call tracking (conformance-like)
//	1: the defaults of parser_test.go: standard macros, max recursion depth 32, error recovery limit
//	   4, lookahead limit 4, macro call tracking
//	2: like 0 but without macros
func newParser(config int) *celparser.Parser {
	var opts []celparser.Option
	switch config {
	case 0:
		opts = []celparser.Option{celparser.Macros(celparser.AllMacros...),
			celparser.EnableOptionalSyntax(true), celparser.EnableIdentEscapeSyntax(true),
			celparser.PopulateMacroCalls(true)}
	case 1:
		opts = []celparser.Option{celparser.Macros(celparser.AllMacros...),
			celparser.MaxRecursionDepth(32), celparser.ErrorRecoveryLimit(4),
			celparser.ErrorRecoveryLookaheadTokenLimit(4), celparser.PopulateMacroCalls(true)}
	case 2:
		opts = []celparser.Option{celparser.EnableOptionalSyntax(true),
			celparser.EnableIdentEscapeSyntax(true), celparser.PopulateMacroCalls(true)}
	}
	p, err := celparser.NewParser(opts...)
	if err != nil {
		fail(err)
	}
	return p
}

type macroCall struct {
	ID    int64  `json:"id"`
	Debug string `json:"debug"`
}

type parseRecord struct {
	File       string      `json:"file,omitempty"`
	Name       string      `json:"name,omitempty"`
	Expr       string      `json:"expr"`
	Config     int         `json:"config"`
	Debug      string      `json:"debug,omitempty"`
	Offsets    [][3]int64  `json:"offsets,omitempty"`
	MacroCalls []macroCall `json:"macroCalls,omitempty"`
	Errors     string      `json:"errors,omitempty"`
}

func record(expr string, config int) (r parseRecord) {
	r.Expr = expr
	r.Config = config
	defer func() {
		if v := recover(); v != nil {
			r.Errors = fmt.Sprintf("PANIC: %v", v)
		}
	}()
	parsed, iss := newParser(config).Parse(common.NewTextSource(expr))
	if len(iss.GetErrors()) > 0 {
		r.Errors = iss.ToDisplayString()
		return r
	}
	info := parsed.SourceInfo()
	r.Debug = debug.ToAdornedDebugString(parsed.Expr(), &kindAndIDAdorner{sourceInfo: info})
	ids := []int64{}
	for id := range info.OffsetRanges() {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	for _, id := range ids {
		o := info.OffsetRanges()[id]
		r.Offsets = append(r.Offsets, [3]int64{id, int64(o.Start), int64(o.Stop)})
	}
	calls := []int64{}
	for id := range info.MacroCalls() {
		calls = append(calls, id)
	}
	sort.Slice(calls, func(i, j int) bool { return calls[i] < calls[j] })
	for _, id := range calls {
		r.MacroCalls = append(r.MacroCalls, macroCall{ID: id, Debug: debug.ToDebugStringWithIDs(info.MacroCalls()[id])})
	}
	return r
}

type kindAndIDAdorner struct {
	sourceInfo *celast.SourceInfo
}

func (k *kindAndIDAdorner) GetMetadata(elem any) string {
	switch e := elem.(type) {
	case celast.Expr:
		if macroCall, found := k.sourceInfo.GetMacroCall(e.ID()); found {
			return fmt.Sprintf("^#%d:%s#", e.ID(), macroCall.AsCall().FunctionName())
		}
		var valType string
		switch e.Kind() {
		case celast.CallKind:
			valType = "*expr.Expr_CallExpr"
		case celast.ComprehensionKind:
			valType = "*expr.Expr_ComprehensionExpr"
		case celast.IdentKind:
			valType = "*expr.Expr_IdentExpr"
		case celast.LiteralKind:
			switch e.AsLiteral().(type) {
			case types.Bool:
				valType = "*expr.Constant_BoolValue"
			case types.Bytes:
				valType = "*expr.Constant_BytesValue"
			case types.Double:
				valType = "*expr.Constant_DoubleValue"
			case types.Int:
				valType = "*expr.Constant_Int64Value"
			case types.Null:
				valType = "*expr.Constant_NullValue"
			case types.String:
				valType = "*expr.Constant_StringValue"
			case types.Uint:
				valType = "*expr.Constant_Uint64Value"
			}
		case celast.ListKind:
			valType = "*expr.Expr_ListExpr"
		case celast.MapKind, celast.StructKind:
			valType = "*expr.Expr_StructExpr"
		case celast.SelectKind:
			valType = "*expr.Expr_SelectExpr"
		}
		return fmt.Sprintf("^#%d:%s#", e.ID(), valType)
	case celast.EntryExpr:
		return fmt.Sprintf("^#%d:%s#", e.ID(), "*expr.Expr_CreateStruct_Entry")
	}
	return ""
}

// ---------------------------------------------------------------------------------------------
// Conformance expressions

func conformanceRecords() []parseRecord {
	files, err := filepath.Glob(filepath.Join(celSpecDir, "tests/simple/testdata/*.textproto"))
	if err != nil {
		fail(err)
	}
	sort.Strings(files)
	var out []parseRecord
	for _, path := range files {
		data, err := os.ReadFile(path)
		if err != nil {
			fail(err)
		}
		var tf conformancetest.SimpleTestFile
		if err := (prototext.UnmarshalOptions{}).Unmarshal(data, &tf); err != nil {
			fail(fmt.Errorf("%s: %w", path, err))
		}
		base := strings.TrimSuffix(filepath.Base(path), ".textproto")
		for _, section := range tf.GetSection() {
			for _, test := range section.GetTest() {
				config := 0
				if test.GetDisableMacros() {
					config = 2
				}
				r := record(test.GetExpr(), config)
				r.File = base
				r.Name = section.GetName() + "/" + test.GetName()
				out = append(out, r)
			}
		}
	}
	return out
}

// ---------------------------------------------------------------------------------------------
// Fuzzing

var fragments = []string{
	"a", "b.c", "x", "_", "1", "1u", "1.5", "0x1F", "0xFu", "-", "!", "+", "*", "/", "%", "==", "!=",
	"<", "<=", ">", ">=", "&&", "||", "?", ":", "(", ")", "[", "]", "{", "}", ",", ".", ".?", "[?",
	"in", "true", "false", "null", `"s"`, `'s'`, `b"x"`, `r"x"`, `"""t"""`, `'''t'''`, "has(", "all(",
	"exists(", "map(", "filter(", "exists_one(", "`a-b`", "`", `\`, `"`, "'", "\n", " ", "//c\n",
	"@", "#", "$", "é", "😁", `\u`, `\x`, `\0`, "1e", "1e+", ".5", "0x", "msg{", "f:", "var", "let",
	"__result__", "@result", "?.", "a.b(", "m.f", "&", "|", "=", "\t", "\r", "1.", "-1", "--", "!!",
	"x.y.z", "Foo{", "{a: 1}", "[1, 2]", "?a", "\"\\", "'\\", `"\a\b"`, `"é"`, `"\377"`, "r'",
	"b'", "R\"\"\"", "B'''", ".a", "a()", "a.b()", "a[1]",
}

func fuzzRecords(seeds []string, n int) []parseRecord {
	rnd := rand.New(rand.NewSource(20261001))
	seen := map[string]bool{}
	var out []parseRecord
	for attempts := 0; len(out) < n && attempts < n*20; attempts++ {
		var input string
		if rnd.Intn(4) == 0 {
			k := 1 + rnd.Intn(12)
			parts := make([]string, k)
			for i := range parts {
				parts[i] = fragments[rnd.Intn(len(fragments))]
			}
			sep := ""
			if rnd.Intn(2) == 0 {
				sep = " "
			}
			input = strings.Join(parts, sep)
		} else {
			input = mutate(rnd, seeds[rnd.Intn(len(seeds))])
		}
		if !utf8.ValidString(input) || seen[input] || len([]rune(input)) > 400 {
			continue
		}
		seen[input] = true
		out = append(out, record(input, len(out)%2))
	}
	return out
}

func mutate(rnd *rand.Rand, s string) string {
	r := []rune(s)
	for m := 1 + rnd.Intn(3); m > 0; m-- {
		pos := 0
		if len(r) > 0 {
			pos = rnd.Intn(len(r) + 1)
		}
		switch rnd.Intn(5) {
		case 0: // delete a span
			if len(r) > 0 {
				end := pos + 1 + rnd.Intn(3)
				if end > len(r) {
					end = len(r)
				}
				if pos < end {
					r = append(r[:pos:pos], r[end:]...)
				}
			}
		case 1: // insert a fragment
			f := []rune(fragments[rnd.Intn(len(fragments))])
			r = append(r[:pos:pos], append(f, r[pos:]...)...)
		case 2: // replace a span with a fragment
			f := []rune(fragments[rnd.Intn(len(fragments))])
			end := pos + 1 + rnd.Intn(3)
			if end > len(r) {
				end = len(r)
			}
			if pos > end {
				pos = end
			}
			r = append(r[:pos:pos], append(f, r[end:]...)...)
		case 3: // duplicate a span
			if len(r) > 0 {
				if pos >= len(r) {
					pos = len(r) - 1
				}
				end := pos + 1 + rnd.Intn(8)
				if end > len(r) {
					end = len(r)
				}
				dup := append([]rune{}, r[pos:end]...)
				r = append(r[:end:end], append(dup, r[end:]...)...)
			}
		case 4: // truncate
			r = r[:pos]
		}
	}
	return string(r)
}
