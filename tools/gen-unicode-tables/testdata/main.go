// Command testdata writes Tests/CELRegexTests/Resources/unicode-classes.txt: the expected
// syntax dumps of the regexp/syntax parse tests whose expectations Go computes from package
// unicode at test time (mkCharClass in parse_test.go), so the Swift tests compare against Go
// rather than against the Swift tables.
//
// Usage (from the repository root):
//
//	go run ./tools/gen-unicode-tables/testdata > Tests/CELRegexTests/Resources/unicode-classes.txt
package main

import (
	"fmt"
	"strings"
	"unicode"
)

func mkCharClass(f func(rune) bool) string {
	var b strings.Builder
	b.WriteString("cc{")
	sep := ""
	lo := rune(-1)
	emit := func(lo, hi rune) {
		b.WriteString(sep)
		sep = " "
		if lo == hi {
			fmt.Fprintf(&b, "%#x", lo)
		} else {
			fmt.Fprintf(&b, "%#x-%#x", lo, hi)
		}
	}
	for i := rune(0); i <= unicode.MaxRune; i++ {
		if f(i) {
			if lo < 0 {
				lo = i
			}
		} else if lo >= 0 {
			emit(lo, i-1)
			lo = -1
		}
	}
	if lo >= 0 {
		emit(lo, unicode.MaxRune)
	}
	b.WriteString("}")
	return b.String()
}

func isUpperFold(r rune) bool {
	if unicode.IsUpper(r) {
		return true
	}
	c := unicode.SimpleFold(r)
	for c != r {
		if unicode.IsUpper(c) {
			return true
		}
		c = unicode.SimpleFold(c)
	}
	return false
}

func main() {
	upper := mkCharClass(unicode.IsUpper)
	for _, tt := range []struct{ re, dump string }{
		{`\p{Lu}`, upper},
		{`\p{Uppercase_Letter}`, upper},
		{`\p{upper case-let ter}`, upper},
		{`\p{__upper case-let ter}`, upper},
		{`[\p{Lu}]`, upper},
		{`(?i)[\p{Lu}]`, mkCharClass(isUpperFold)},
		{`\p{Assigned}`, mkCharClass(func(r rune) bool { return !unicode.In(r, unicode.Cn) })},
		{`\p{^Assigned}`, mkCharClass(func(r rune) bool { return unicode.In(r, unicode.Cn) })},
	} {
		fmt.Printf("%s\t%s\n", tt.re, tt.dump)
	}
}
