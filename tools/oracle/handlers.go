package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	"cel.dev/cel-go/cel"
	"cel.dev/cel-go/checker"
	"cel.dev/cel-go/common"
	"cel.dev/cel-go/common/ast"
	"cel.dev/cel-go/common/debug"
	"cel.dev/cel-go/common/types"
	"cel.dev/cel-go/parser"

	exprpb "google.golang.org/genproto/googleapis/api/expr/v1alpha1"
)

// request is one line of input. See README.md for field semantics.
type request struct {
	ID            string                     `json:"id,omitempty"`
	Kind          string                     `json:"kind"`
	Expr          string                     `json:"expr"`
	Profile       string                     `json:"profile,omitempty"`
	Config        json.RawMessage            `json:"config,omitempty"`
	TestTypes     bool                       `json:"test_types,omitempty"`
	Container     string                     `json:"container,omitempty"`
	DisableMacros bool                       `json:"disable_macros,omitempty"`
	DeclsProto    []json.RawMessage          `json:"decls_proto,omitempty"`
	Parser        *parserOptions             `json:"parser,omitempty"`
	Check         *bool                      `json:"check,omitempty"`
	Bindings      map[string]json.RawMessage `json:"bindings,omitempty"`
	Unknowns      []unknownPattern           `json:"unknowns,omitempty"`
	CostLimit     *uint64                    `json:"cost_limit,omitempty"`
	SizeHints     map[string]sizeHint        `json:"size_hints,omitempty"`
}

type parserOptions struct {
	MaxRecursionDepth                int   `json:"max_recursion_depth,omitempty"`
	ErrorRecoveryLimit               int   `json:"error_recovery_limit,omitempty"`
	ErrorRecoveryLookaheadTokenLimit int   `json:"error_recovery_lookahead_token_limit,omitempty"`
	ErrorReportingLimit              int   `json:"error_reporting_limit,omitempty"`
	ExpressionSizeCodePointLimit     int   `json:"expression_size_code_point_limit,omitempty"`
	MaxExpressionNodeCount           int   `json:"max_expression_node_count,omitempty"`
	PopulateMacroCalls               *bool `json:"populate_macro_calls,omitempty"`
	OptionalSyntax                   bool  `json:"optional_syntax,omitempty"`
	IdentEscapeSyntax                bool  `json:"ident_escape_syntax,omitempty"`
	VariadicOperatorASTs             bool  `json:"variadic_operator_asts,omitempty"`
	HiddenAccumulatorName            bool  `json:"hidden_accumulator_name,omitempty"`
}

type unknownPattern struct {
	Variable string            `json:"variable"`
	Path     []json.RawMessage `json:"path,omitempty"`
}

type sizeHint struct {
	Min uint64 `json:"min"`
	Max uint64 `json:"max"`
}

type issue struct {
	Message string `json:"message"`
	Line    int    `json:"line"`
	Column  int    `json:"column"`
	ExprID  int64  `json:"expr_id,omitempty"`
}

type costRange struct {
	Min uint64 `json:"min"`
	Max uint64 `json:"max"`
}

type evalResult struct {
	Value   json.RawMessage `json:"value,omitempty"`
	Error   *string         `json:"error,omitempty"`
	Unknown []int64         `json:"unknown,omitempty"`
}

type response struct {
	ID          string `json:"id,omitempty"`
	Kind        string `json:"kind,omitempty"`
	OracleError string `json:"oracle_error,omitempty"`

	// Compile phase (parse and, where it applies, check).
	Error  string  `json:"error,omitempty"`
	Issues []issue `json:"issues,omitempty"`

	// parse
	Debug          *string         `json:"debug,omitempty"`
	DebugIDs       *string         `json:"debug_ids,omitempty"`
	DebugLocations *string         `json:"debug_locations,omitempty"`
	MacroCalls     *string         `json:"macro_calls,omitempty"`
	Unparse        *string         `json:"unparse,omitempty"`
	UnparseError   string          `json:"unparse_error,omitempty"`
	ParsedExpr     json.RawMessage `json:"parsed_expr,omitempty"`

	// check
	Type         *string         `json:"type,omitempty"`
	TypeProto    json.RawMessage `json:"type_proto,omitempty"`
	CheckedDebug *string         `json:"checked_debug,omitempty"`

	// eval
	Result       *evalResult `json:"result,omitempty"`
	Cost         *uint64     `json:"cost,omitempty"`
	CostEstimate *costRange  `json:"cost_estimate,omitempty"`
}

func strp(s string) *string { return &s }

func handle(req *request) *response {
	resp := &response{ID: req.ID, Kind: req.Kind}
	e, err := buildEnv(req)
	if err != nil {
		resp.OracleError = fmt.Sprintf("environment: %v", err)
		return resp
	}
	switch req.Kind {
	case "parse":
		handleParse(req, e, resp)
	case "check":
		handleCheck(req, e, resp)
	case "eval":
		handleEval(req, e, resp)
	default:
		resp.OracleError = fmt.Sprintf("unknown kind %q", req.Kind)
	}
	return resp
}

func reportIssues(resp *response, errs []*common.Error) {
	resp.Issues = make([]issue, 0, len(errs))
	for _, e := range errs {
		resp.Issues = append(resp.Issues, issue{
			Message: e.Message,
			Line:    e.Location.Line(),
			Column:  e.Location.Column(),
			ExprID:  e.ExprID,
		})
	}
}

func handleParse(req *request, e *cel.Env, resp *response) {
	var parsed *ast.AST
	src := common.NewTextSource(req.Expr)
	if req.Parser != nil {
		p, err := newParser(req, e)
		if err != nil {
			resp.OracleError = fmt.Sprintf("parser options: %v", err)
			return
		}
		var errs *common.Errors
		parsed, errs = p.Parse(src)
		if len(errs.GetErrors()) > 0 {
			resp.Error = errs.ToDisplayString()
			reportIssues(resp, errs.GetErrors())
			return
		}
	} else {
		a, iss := e.ParseSource(src)
		if iss.Err() != nil {
			resp.Error = iss.String()
			reportIssues(resp, iss.Errors())
			return
		}
		parsed = a.NativeRep()
	}
	resp.Debug = strp(debug.ToDebugString(parsed.Expr()))
	resp.DebugIDs = strp(debug.ToAdornedDebugString(parsed.Expr(), &kindAndIDAdorner{}))
	resp.DebugLocations = strp(debug.ToAdornedDebugString(parsed.Expr(), &locationAdorner{parsed.SourceInfo()}))
	resp.MacroCalls = strp(convertMacroCallsToString(parsed.SourceInfo()))
	if s, err := parser.Unparse(parsed.Expr(), parsed.SourceInfo()); err != nil {
		resp.UnparseError = err.Error()
	} else {
		resp.Unparse = strp(s)
	}
	if expr, err := ast.ExprToProto(parsed.Expr()); err == nil {
		if info, err := ast.SourceInfoToProto(parsed.SourceInfo()); err == nil {
			resp.ParsedExpr = protoJSON(&exprpb.ParsedExpr{Expr: expr, SourceInfo: info})
		}
	}
}

func newParser(req *request, e *cel.Env) (*parser.Parser, error) {
	o := req.Parser
	opts := []parser.Option{parser.Macros(e.Macros()...)}
	if o.MaxRecursionDepth != 0 {
		opts = append(opts, parser.MaxRecursionDepth(o.MaxRecursionDepth))
	}
	if o.ErrorRecoveryLimit != 0 {
		opts = append(opts, parser.ErrorRecoveryLimit(o.ErrorRecoveryLimit))
	}
	if o.ErrorRecoveryLookaheadTokenLimit != 0 {
		opts = append(opts, parser.ErrorRecoveryLookaheadTokenLimit(o.ErrorRecoveryLookaheadTokenLimit))
	}
	if o.ErrorReportingLimit != 0 {
		opts = append(opts, parser.ErrorReportingLimit(o.ErrorReportingLimit))
	}
	if o.ExpressionSizeCodePointLimit != 0 {
		opts = append(opts, parser.ExpressionSizeCodePointLimit(o.ExpressionSizeCodePointLimit))
	}
	if o.MaxExpressionNodeCount != 0 {
		opts = append(opts, parser.MaxExpressionNodeCount(o.MaxExpressionNodeCount))
	}
	opts = append(opts,
		parser.PopulateMacroCalls(o.PopulateMacroCalls == nil || *o.PopulateMacroCalls),
		parser.EnableOptionalSyntax(o.OptionalSyntax),
		parser.EnableIdentEscapeSyntax(o.IdentEscapeSyntax),
		parser.EnableVariadicOperatorASTs(o.VariadicOperatorASTs),
		parser.EnableHiddenAccumulatorName(o.HiddenAccumulatorName),
	)
	return parser.NewParser(opts...)
}

// compile parses and, unless check is false, type-checks the expression. It fills resp.Error on failure.
func compile(req *request, e *cel.Env, resp *response, check bool) *cel.Ast {
	src := common.NewTextSource(req.Expr)
	a, iss := e.ParseSource(src)
	if iss.Err() != nil {
		resp.Error = iss.String()
		reportIssues(resp, iss.Errors())
		return nil
	}
	if !check {
		return a
	}
	checked, iss := e.Check(a)
	if iss.Err() != nil {
		resp.Error = iss.String()
		reportIssues(resp, iss.Errors())
		return nil
	}
	resp.Type = strp(cel.FormatCELType(checked.OutputType()))
	if tp, err := types.TypeToProto(checked.OutputType()); err == nil {
		resp.TypeProto = protoJSON(tp)
	}
	resp.CheckedDebug = strp(checker.Print(checked.NativeRep().Expr(), checked.NativeRep()))
	return checked
}

func handleCheck(req *request, e *cel.Env, resp *response) {
	compile(req, e, resp, true)
}

func handleEval(req *request, e *cel.Env, resp *response) {
	check := req.Check == nil || *req.Check
	a := compile(req, e, resp, check)
	if a == nil {
		return
	}
	if check {
		est, err := e.EstimateCost(a, sizeEstimator(req.SizeHints))
		if err == nil {
			resp.CostEstimate = &costRange{Min: est.Min, Max: est.Max}
		}
	}
	progOpts := []cel.ProgramOption{cel.CostTracking(nil)}
	if req.CostLimit != nil {
		progOpts = append(progOpts, cel.CostLimit(*req.CostLimit))
	}
	if len(req.Unknowns) > 0 {
		progOpts = append(progOpts, cel.EvalOptions(cel.OptPartialEval))
	}
	prg, err := e.Program(a, progOpts...)
	if err != nil {
		resp.Error = err.Error()
		return
	}
	vars := make(map[string]any, len(req.Bindings))
	for name, raw := range req.Bindings {
		v, err := decodeValue(e, raw)
		if err != nil {
			resp.OracleError = fmt.Sprintf("binding %q: %v", name, err)
			return
		}
		vars[name] = v
	}
	var act any = vars
	if len(req.Unknowns) > 0 {
		patterns := make([]*cel.AttributePatternType, 0, len(req.Unknowns))
		for _, u := range req.Unknowns {
			p, err := attributePattern(e, u)
			if err != nil {
				resp.OracleError = fmt.Sprintf("unknowns: %v", err)
				return
			}
			patterns = append(patterns, p)
		}
		pa, err := cel.PartialVars(vars, patterns...)
		if err != nil {
			resp.OracleError = fmt.Sprintf("unknowns: %v", err)
			return
		}
		act = pa
	}
	out, details, err := prg.Eval(act)
	if details != nil {
		resp.Cost = details.ActualCost()
	}
	resp.Result = &evalResult{}
	switch {
	case err != nil:
		resp.Result.Error = strp(err.Error())
	case types.IsUnknown(out):
		ids := append([]int64(nil), out.(*types.Unknown).IDs()...)
		sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
		resp.Result.Unknown = ids
	case types.IsError(out):
		resp.Result.Error = strp(out.(*types.Err).String())
	default:
		v, err := encodeValue(out)
		if err != nil {
			resp.OracleError = fmt.Sprintf("result: %v", err)
			return
		}
		resp.Result.Value = v
	}
}

func attributePattern(e *cel.Env, u unknownPattern) (*cel.AttributePatternType, error) {
	p := cel.AttributePattern(u.Variable)
	for _, q := range u.Path {
		if string(q) == `"*"` {
			p = p.Wildcard()
			continue
		}
		v, err := decodeValue(e, q)
		if err != nil {
			return nil, err
		}
		switch qv := v.(type) {
		case types.String:
			p = p.QualString(string(qv))
		case types.Int:
			p = p.QualInt(int64(qv))
		case types.Uint:
			p = p.QualUint(uint64(qv))
		case types.Bool:
			p = p.QualBool(bool(qv))
		default:
			return nil, fmt.Errorf("unsupported qualifier %s", q)
		}
	}
	return p, nil
}

// sizeEstimator returns size hints keyed by the dotted AstNode path (e.g. "x" or "msg.list_field").
type sizeEstimator map[string]sizeHint

func (s sizeEstimator) EstimateSize(element checker.AstNode) *checker.SizeEstimate {
	if h, ok := s[strings.Join(element.Path(), ".")]; ok {
		return &checker.SizeEstimate{Min: h.Min, Max: h.Max}
	}
	return nil
}

func (s sizeEstimator) EstimateCallCost(string, string, *checker.AstNode, []checker.AstNode) *checker.CallEstimate {
	return nil
}

func protoJSON(m proto.Message) json.RawMessage {
	b, err := protojson.MarshalOptions{UseProtoNames: true}.Marshal(m)
	if err != nil {
		return nil
	}
	return compactJSON(b)
}
