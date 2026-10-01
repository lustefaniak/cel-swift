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

// Debug-string adorners copied verbatim from cel-go parser/parser_test.go, so the oracle's "debug_ids",
// "debug_locations" and "macro_calls" outputs use the exact formats of that file's P, L and M columns.

package main

import (
	"fmt"
	"reflect"
	"sort"
	"strings"

	"cel.dev/cel-go/common"
	"cel.dev/cel-go/common/ast"
	"cel.dev/cel-go/common/debug"
	"cel.dev/cel-go/common/types"
)

type metadata interface {
	GetLocation(exprID int64) (common.Location, bool)
}

type kindAndIDAdorner struct {
	sourceInfo *ast.SourceInfo
}

func (k *kindAndIDAdorner) GetMetadata(elem any) string {
	switch e := elem.(type) {
	case ast.Expr:
		if macroCall, found := k.sourceInfo.GetMacroCall(e.ID()); found {
			return fmt.Sprintf("^#%d:%s#", e.ID(), macroCall.AsCall().FunctionName())
		}
		var valType string
		switch e.Kind() {
		case ast.CallKind:
			valType = "*expr.Expr_CallExpr"
		case ast.ComprehensionKind:
			valType = "*expr.Expr_ComprehensionExpr"
		case ast.IdentKind:
			valType = "*expr.Expr_IdentExpr"
		case ast.LiteralKind:
			lit := e.AsLiteral()
			switch lit.(type) {
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
			default:
				valType = reflect.TypeOf(lit).String()
			}
		case ast.ListKind:
			valType = "*expr.Expr_ListExpr"
		case ast.MapKind, ast.StructKind:
			valType = "*expr.Expr_StructExpr"
		case ast.SelectKind:
			valType = "*expr.Expr_SelectExpr"
		}
		return fmt.Sprintf("^#%d:%s#", e.ID(), valType)
	case ast.EntryExpr:
		return fmt.Sprintf("^#%d:%s#", e.ID(), "*expr.Expr_CreateStruct_Entry")
	}
	return ""
}

type locationAdorner struct {
	sourceInfo *ast.SourceInfo
}

var _ metadata = &locationAdorner{}

func (l *locationAdorner) GetLocation(exprID int64) (common.Location, bool) {
	loc := l.sourceInfo.GetStartLocation(exprID)
	return loc, loc != common.NoLocation
}

func (l *locationAdorner) GetMetadata(elem any) string {
	var elemID int64
	switch elem := elem.(type) {
	case ast.Expr:
		elemID = elem.ID()
	case ast.EntryExpr:
		elemID = elem.ID()
	}
	location, _ := l.GetLocation(elemID)
	return fmt.Sprintf("^#%d[%d,%d]#", elemID, location.Line(), location.Column())
}

func convertMacroCallsToString(source *ast.SourceInfo) string {
	macroCalls := source.MacroCalls()
	keys := make([]int64, len(macroCalls))
	adornedStrings := make([]string, len(macroCalls))
	i := 0
	for k := range macroCalls {
		keys[i] = k
		i++
	}
	fac := ast.NewExprFactory()
	// Sort the keys in descending order to create a stable ordering for tests and improve readability.
	sort.Slice(keys, func(i, j int) bool { return keys[i] > keys[j] })
	i = 0
	for _, key := range keys {
		call := macroCalls[int64(key)].AsCall()
		var callWithID ast.Expr
		if call.IsMemberFunction() {
			callWithID = fac.NewMemberCall(int64(key), call.FunctionName(), call.Target(), call.Args()...)
		} else {
			callWithID = fac.NewCall(int64(key), call.FunctionName(), call.Args()...)
		}
		adornedStrings[i] = debug.ToAdornedDebugString(
			callWithID,
			&kindAndIDAdorner{sourceInfo: source})
		i++
	}
	return strings.Join(adornedStrings, ",\n")
}
