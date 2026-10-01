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

// The rule functions of cel-go's generated parser (parser/gen/cel_parser.go, from CEL.g4), written
// out by hand. They follow the generated code statement by statement, including the ATN state
// numbers, so that adaptive prediction, `Sync` and error recovery behave exactly as in cel-go.
// `break body` stands for the generated `goto errorExit`.

extension ParserRuntime {
  private func inSet(_ la: Int, _ mask: Int64) -> Bool {
    la >= 0 && la < 64 && (Int64(1) << Int64(la)) & mask != 0
  }

  private func newContext(_ rule: Int, _ label: ContextLabel) -> ParserRuleContext {
    ParserRuleContext(parent: ctx, invokingState: state, ruleIndex: rule, label: label)
  }

  // start : e=expr EOF ;
  func start() throws -> ParserRuleContext {
    let localctx = newContext(CELRule.start, .start)
    try enterRule(localctx, 0)
    enterOuterAlt(localctx)
    body: do {
      state = 34
      localctx.e = try expr()
      state = 35
      _ = try match(CELToken.eof)
      if error != nil { break body }
    }
    try handleErrorExit(localctx)
    try exitRule()
    return localctx
  }

  // expr : e=conditionalOr (op='?' e1=conditionalOr ':' e2=expr)? ;
  func expr() throws -> ParserRuleContext {
    let localctx = newContext(CELRule.expr, .expr)
    try enterRule(localctx, 2)
    enterOuterAlt(localctx)
    body: do {
      state = 37
      localctx.e = try conditionalOr()
      state = 43
      try sync()
      if error != nil { break body }
      if try la(1) == CELToken.questionMark {
        state = 38
        localctx.op = try match(CELToken.questionMark)
        if error != nil { break body }
        state = 39
        localctx.e1 = try conditionalOr()
        state = 40
        _ = try match(CELToken.colon)
        if error != nil { break body }
        state = 41
        localctx.e2 = try expr()
      }
    }
    try handleErrorExit(localctx)
    try exitRule()
    return localctx
  }

  // conditionalOr : e=conditionalAnd (ops+='||' e1+=conditionalAnd)* ;
  func conditionalOr() throws -> ParserRuleContext {
    let localctx = newContext(CELRule.conditionalOr, .conditionalOr)
    try enterRule(localctx, 4)
    enterOuterAlt(localctx)
    body: do {
      state = 45
      localctx.e = try conditionalAnd()
      state = 50
      try sync()
      if error != nil { break body }
      var la = try self.la(1)
      while la == CELToken.logicalOr {
        state = 46
        let m = try match(CELToken.logicalOr)
        if error != nil { break body }
        if let m { localctx.ops.append(m) }
        state = 47
        localctx.exprs.append(try conditionalAnd())
        state = 52
        try sync()
        if error != nil { break body }
        la = try self.la(1)
      }
    }
    try handleErrorExit(localctx)
    try exitRule()
    return localctx
  }

  // conditionalAnd : e=relation (ops+='&&' e1+=relation)* ;
  func conditionalAnd() throws -> ParserRuleContext {
    let localctx = newContext(CELRule.conditionalAnd, .conditionalAnd)
    try enterRule(localctx, 6)
    enterOuterAlt(localctx)
    body: do {
      state = 53
      localctx.e = try relation(0)
      state = 58
      try sync()
      if error != nil { break body }
      var la = try self.la(1)
      while la == CELToken.logicalAnd {
        state = 54
        let m = try match(CELToken.logicalAnd)
        if error != nil { break body }
        if let m { localctx.ops.append(m) }
        state = 55
        localctx.exprs.append(try relation(0))
        state = 60
        try sync()
        if error != nil { break body }
        la = try self.la(1)
      }
    }
    try handleErrorExit(localctx)
    try exitRule()
    return localctx
  }

  // relation : calc | relation op=('<'|'<='|'>='|'>'|'=='|'!='|'in') relation ;
  @discardableResult
  func relation(_ p: Int) throws -> ParserRuleContext {
    let parentctx = ctx
    let parentState = state
    var localctx = newContext(CELRule.relation, .relation)
    let startState = 8
    try enterRecursionRule(localctx, 8, p)
    enterOuterAlt(localctx)
    body: do {
      state = 62
      try calc(0)
      ctx?.stop = try lt(-1)
      state = 69
      try sync()
      if error != nil { break body }
      var alt = try adaptivePredict(3)
      if error != nil { break body }
      while alt != 2 && alt != 0 {
        if alt == 1 {
          triggerExitRule()
          localctx = ParserRuleContext(
            parent: parentctx, invokingState: parentState, ruleIndex: CELRule.relation,
            label: .relation)
          try pushNewRecursionContext(localctx, startState)
          state = 64
          if !precpred(1) {
            error = try failedPredicate("p.Precpred(p.GetParserRuleContext(), 1)")
            break body
          }
          state = 65
          localctx.op = try lt(1)
          if !inSet(try la(1), 254) {
            localctx.op = try recoverInline()
          } else {
            reportMatch()
            try consume()
          }
          state = 66
          try relation(2)
        }
        state = 71
        try sync()
        if error != nil { break body }
        alt = try adaptivePredict(3)
        if error != nil { break body }
      }
    }
    try handleErrorExit(localctx)
    try unrollRecursionContexts(parentctx)
    return localctx
  }

  // calc : unary | calc op=('*'|'/'|'%') calc | calc op=('+'|'-') calc ;
  @discardableResult
  func calc(_ p: Int) throws -> ParserRuleContext {
    let parentctx = ctx
    let parentState = state
    var localctx = newContext(CELRule.calc, .calc)
    let startState = 10
    try enterRecursionRule(localctx, 10, p)
    enterOuterAlt(localctx)
    body: do {
      state = 73
      try unary()
      ctx?.stop = try lt(-1)
      state = 83
      try sync()
      if error != nil { break body }
      var alt = try adaptivePredict(5)
      if error != nil { break body }
      while alt != 2 && alt != 0 {
        if alt == 1 {
          triggerExitRule()
          state = 81
          try sync()
          if error != nil { break body }
          switch try adaptivePredict(4) {
          case 1:
            localctx = ParserRuleContext(
              parent: parentctx, invokingState: parentState, ruleIndex: CELRule.calc, label: .calc)
            try pushNewRecursionContext(localctx, startState)
            state = 75
            if !precpred(2) {
              error = try failedPredicate("p.Precpred(p.GetParserRuleContext(), 2)")
              break body
            }
            state = 76
            localctx.op = try lt(1)
            if !inSet(try la(1), 58_720_256) {
              localctx.op = try recoverInline()
            } else {
              reportMatch()
              try consume()
            }
            state = 77
            try calc(3)
          case 2:
            localctx = ParserRuleContext(
              parent: parentctx, invokingState: parentState, ruleIndex: CELRule.calc, label: .calc)
            try pushNewRecursionContext(localctx, startState)
            state = 78
            if !precpred(1) {
              error = try failedPredicate("p.Precpred(p.GetParserRuleContext(), 1)")
              break body
            }
            state = 79
            localctx.op = try lt(1)
            let la = try self.la(1)
            if !(la == CELToken.minus || la == CELToken.plus) {
              localctx.op = try recoverInline()
            } else {
              reportMatch()
              try consume()
            }
            state = 80
            try calc(2)
          case 0:
            break body
          default:
            break
          }
        }
        state = 85
        try sync()
        if error != nil { break body }
        alt = try adaptivePredict(5)
        if error != nil { break body }
      }
    }
    try handleErrorExit(localctx)
    try unrollRecursionContexts(parentctx)
    return localctx
  }

  // unary : member # MemberExpr | (ops+='!')+ member # LogicalNot | (ops+='-')+ member # Negate ;
  @discardableResult
  func unary() throws -> ParserRuleContext {
    var localctx = newContext(CELRule.unary, .unary)
    try enterRule(localctx, 12)
    body: do {
      state = 99
      try sync()
      if error != nil { break body }
      switch try adaptivePredict(8) {
      case 1:
        localctx = try unaryAlt1(localctx)
      case 2:
        localctx = try unaryAlt2(localctx)
      case 3:
        localctx = try unaryAlt3(localctx)
      case 0:
        break body
      default:
        break
      }
    }
    try handleErrorExit(localctx)
    try exitRule()
    return localctx
  }

  @inline(never)
  private func unaryAlt1(_ base: ParserRuleContext) throws -> ParserRuleContext {
    let localctx = ParserRuleContext(copying: base, label: .memberExpr)
    enterOuterAlt(localctx)
    state = 86
    try member(0)
    return localctx
  }

  @inline(never)
  private func unaryAlt2(_ base: ParserRuleContext) throws -> ParserRuleContext {
    let localctx = ParserRuleContext(copying: base, label: .logicalNot)
    enterOuterAlt(localctx)
    state = 88
    try sync()
    if error != nil { return localctx }
    var la = try self.la(1)
    repeat {
      state = 87
      let m = try match(CELToken.exclam)
      if error != nil { return localctx }
      if let m { localctx.ops.append(m) }
      state = 90
      try sync()
      if error != nil { return localctx }
      la = try self.la(1)
    } while la == CELToken.exclam
    state = 92
    try member(0)
    return localctx
  }

  @inline(never)
  private func unaryAlt3(_ base: ParserRuleContext) throws -> ParserRuleContext {
    let localctx = ParserRuleContext(copying: base, label: .negate)
    enterOuterAlt(localctx)
    state = 94
    try sync()
    if error != nil { return localctx }
    var alt = 1
    repeat {
      switch alt {
      case 1:
        state = 93
        let m = try match(CELToken.minus)
        if error != nil { return localctx }
        if let m { localctx.ops.append(m) }
      default:
        error = try noViableAltHere()
        return localctx
      }
      state = 96
      try sync()
      alt = try adaptivePredict(7)
      if error != nil { return localctx }
    } while alt != 2 && alt != 0
    state = 98
    try member(0)
    return localctx
  }

  // member : primary # PrimaryExpr | member op='.' (opt='?')? id=escapeIdent # Select
  //        | member op='.' id=IDENTIFIER open='(' args=exprList? ')' # MemberCall
  //        | member op='[' (opt='?')? index=expr ']' # Index ;
  @discardableResult
  func member(_ p: Int) throws -> ParserRuleContext {
    let parentctx = ctx
    let parentState = state
    var localctx = newContext(CELRule.member, .member)
    let startState = 14
    try enterRecursionRule(localctx, 14, p)
    enterOuterAlt(localctx)
    localctx = ParserRuleContext(copying: localctx, label: .primaryExpr)
    ctx = localctx
    body: do {
      state = 102
      try primary()
      ctx?.stop = try lt(-1)
      state = 128
      try sync()
      if error != nil { break body }
      var alt = try adaptivePredict(13)
      if error != nil { break body }
      while alt != 2 && alt != 0 {
        if alt == 1 {
          triggerExitRule()
          state = 126
          try sync()
          if error != nil { break body }
          switch try adaptivePredict(12) {
          case 1:
            let (next, stop) = try memberSelect(parentctx, parentState, startState)
            localctx = next
            if stop { break body }
          case 2:
            let (next, stop) = try memberCall(parentctx, parentState, startState)
            localctx = next
            if stop { break body }
          case 3:
            let (next, stop) = try memberIndex(parentctx, parentState, startState)
            localctx = next
            if stop { break body }
          case 0:
            break body
          default:
            break
          }
        }
        state = 130
        try sync()
        if error != nil { break body }
        alt = try adaptivePredict(13)
        if error != nil { break body }
      }
    }
    try handleErrorExit(localctx)
    try unrollRecursionContexts(parentctx)
    return localctx
  }

  // The alternatives of the member loop live in their own functions so that the recursive member
  // frame stays small; each returns the new context and whether to jump to the error exit.

  @inline(never)
  private func memberSelect(_ parentctx: ParserRuleContext?, _ parentState: Int, _ startState: Int)
    throws -> (ParserRuleContext, Bool)
  {
    let localctx = ParserRuleContext(
      copying: ParserRuleContext(
        parent: parentctx, invokingState: parentState, ruleIndex: CELRule.member, label: .member),
      label: .select)
    try pushNewRecursionContext(localctx, startState)
    state = 104
    if !precpred(3) {
      error = try failedPredicate("p.Precpred(p.GetParserRuleContext(), 3)")
      return (localctx, true)
    }
    state = 105
    localctx.op = try match(CELToken.dot)
    if error != nil { return (localctx, true) }
    state = 107
    try sync()
    if error != nil { return (localctx, true) }
    if try la(1) == CELToken.questionMark {
      state = 106
      localctx.opt = try match(CELToken.questionMark)
      if error != nil { return (localctx, true) }
    }
    state = 109
    localctx.idContext = try escapeIdent()
    return (localctx, false)
  }

  @inline(never)
  private func memberCall(_ parentctx: ParserRuleContext?, _ parentState: Int, _ startState: Int)
    throws -> (ParserRuleContext, Bool)
  {
    let localctx = ParserRuleContext(
      copying: ParserRuleContext(
        parent: parentctx, invokingState: parentState, ruleIndex: CELRule.member, label: .member),
      label: .memberCall)
    try pushNewRecursionContext(localctx, startState)
    state = 110
    if !precpred(2) {
      error = try failedPredicate("p.Precpred(p.GetParserRuleContext(), 2)")
      return (localctx, true)
    }
    state = 111
    localctx.op = try match(CELToken.dot)
    if error != nil { return (localctx, true) }
    state = 112
    localctx.idToken = try match(CELToken.identifier)
    if error != nil { return (localctx, true) }
    state = 113
    localctx.open = try match(CELToken.lparen)
    if error != nil { return (localctx, true) }
    state = 115
    try sync()
    if error != nil { return (localctx, true) }
    if inSet(try la(1), 135_762_105_344) {
      state = 114
      localctx.args = try exprList()
    }
    state = 117
    _ = try match(CELToken.rparen)
    if error != nil { return (localctx, true) }
    return (localctx, false)
  }

  @inline(never)
  private func memberIndex(_ parentctx: ParserRuleContext?, _ parentState: Int, _ startState: Int)
    throws -> (ParserRuleContext, Bool)
  {
    let localctx = ParserRuleContext(
      copying: ParserRuleContext(
        parent: parentctx, invokingState: parentState, ruleIndex: CELRule.member, label: .member),
      label: .index)
    try pushNewRecursionContext(localctx, startState)
    state = 118
    if !precpred(1) {
      error = try failedPredicate("p.Precpred(p.GetParserRuleContext(), 1)")
      return (localctx, true)
    }
    state = 119
    localctx.op = try match(CELToken.lbracket)
    if error != nil { return (localctx, true) }
    state = 121
    try sync()
    if error != nil { return (localctx, true) }
    if try la(1) == CELToken.questionMark {
      state = 120
      localctx.opt = try match(CELToken.questionMark)
      if error != nil { return (localctx, true) }
    }
    state = 123
    localctx.index = try expr()
    state = 124
    _ = try match(CELToken.rbracket)
    if error != nil { return (localctx, true) }
    return (localctx, false)
  }

  // primary : leadingDot='.'? id=IDENTIFIER # Ident
  //         | leadingDot='.'? id=IDENTIFIER (op='(' args=exprList? ')') # GlobalCall
  //         | '(' e=expr ')' # Nested
  //         | op='[' elems=listInit? ','? ']' # CreateList
  //         | op='{' entries=mapInitializerList? ','? '}' # CreateStruct
  //         | leadingDot='.'? ids+=IDENTIFIER (ops+='.' ids+=IDENTIFIER)*
  //             op='{' entries=fieldInitializerList? ','? '}' # CreateMessage
  //         | literal # ConstantLiteral ;
  @discardableResult
  func primary() throws -> ParserRuleContext {
    var localctx = newContext(CELRule.primary, .primary)
    try enterRule(localctx, 16)
    body: do {
      state = 184
      try sync()
      if error != nil { break body }
      switch try adaptivePredict(25) {
      case 1:
        localctx = try primaryAlt1(localctx)
      case 2:
        localctx = try primaryAlt2(localctx)
      case 3:
        localctx = try primaryAlt3(localctx)
      case 4:
        localctx = try primaryAlt4(localctx)
      case 5:
        localctx = try primaryAlt5(localctx)
      case 6:
        localctx = try primaryAlt6(localctx)
      case 7:
        localctx = try primaryAlt7(localctx)
      case 0:
        break body
      default:
        break
      }
    }
    try handleErrorExit(localctx)
    try exitRule()
    return localctx
  }

  @inline(never)
  private func primaryAlt1(_ base: ParserRuleContext) throws -> ParserRuleContext {
    let localctx = ParserRuleContext(copying: base, label: .ident)
    enterOuterAlt(localctx)
    state = 132
    try sync()
    if error != nil { return localctx }
    if try la(1) == CELToken.dot {
      state = 131
      localctx.leadingDot = try match(CELToken.dot)
      if error != nil { return localctx }
    }
    state = 134
    localctx.idToken = try match(CELToken.identifier)
    if error != nil { return localctx }
    return localctx
  }

  @inline(never)
  private func primaryAlt2(_ base: ParserRuleContext) throws -> ParserRuleContext {
    let localctx = ParserRuleContext(copying: base, label: .globalCall)
    enterOuterAlt(localctx)
    state = 136
    try sync()
    if error != nil { return localctx }
    if try la(1) == CELToken.dot {
      state = 135
      localctx.leadingDot = try match(CELToken.dot)
      if error != nil { return localctx }
    }
    state = 138
    localctx.idToken = try match(CELToken.identifier)
    if error != nil { return localctx }
    state = 139
    localctx.op = try match(CELToken.lparen)
    if error != nil { return localctx }
    state = 141
    try sync()
    if error != nil { return localctx }
    if inSet(try la(1), 135_762_105_344) {
      state = 140
      localctx.args = try exprList()
    }
    state = 143
    _ = try match(CELToken.rparen)
    if error != nil { return localctx }
    return localctx
  }

  @inline(never)
  private func primaryAlt3(_ base: ParserRuleContext) throws -> ParserRuleContext {
    let localctx = ParserRuleContext(copying: base, label: .nested)
    enterOuterAlt(localctx)
    state = 144
    _ = try match(CELToken.lparen)
    if error != nil { return localctx }
    state = 145
    localctx.e = try expr()
    state = 146
    _ = try match(CELToken.rparen)
    if error != nil { return localctx }
    return localctx
  }

  @inline(never)
  private func primaryAlt4(_ base: ParserRuleContext) throws -> ParserRuleContext {
    let localctx = ParserRuleContext(copying: base, label: .createList)
    enterOuterAlt(localctx)
    state = 148
    localctx.op = try match(CELToken.lbracket)
    if error != nil { return localctx }
    state = 150
    try sync()
    if error != nil { return localctx }
    if inSet(try la(1), 135_763_153_920) {
      state = 149
      localctx.elems = try listInit()
    }
    state = 153
    try sync()
    if error != nil { return localctx }
    if try la(1) == CELToken.comma {
      state = 152
      _ = try match(CELToken.comma)
      if error != nil { return localctx }
    }
    state = 155
    _ = try match(CELToken.rbracket)
    if error != nil { return localctx }
    return localctx
  }

  @inline(never)
  private func primaryAlt5(_ base: ParserRuleContext) throws -> ParserRuleContext {
    let localctx = ParserRuleContext(copying: base, label: .createStruct)
    enterOuterAlt(localctx)
    state = 156
    localctx.op = try match(CELToken.lbrace)
    if error != nil { return localctx }
    state = 158
    try sync()
    if error != nil { return localctx }
    if inSet(try la(1), 135_763_153_920) {
      state = 157
      localctx.entries = try mapInitializerList()
    }
    state = 161
    try sync()
    if error != nil { return localctx }
    if try la(1) == CELToken.comma {
      state = 160
      _ = try match(CELToken.comma)
      if error != nil { return localctx }
    }
    state = 163
    _ = try match(CELToken.rbrace)
    if error != nil { return localctx }
    return localctx
  }

  @inline(never)
  private func primaryAlt6(_ base: ParserRuleContext) throws -> ParserRuleContext {
    let localctx = ParserRuleContext(copying: base, label: .createMessage)
    enterOuterAlt(localctx)
    state = 165
    try sync()
    if error != nil { return localctx }
    if try la(1) == CELToken.dot {
      state = 164
      localctx.leadingDot = try match(CELToken.dot)
      if error != nil { return localctx }
    }
    state = 167
    let first = try match(CELToken.identifier)
    if error != nil { return localctx }
    if let first { localctx.ids.append(first) }
    state = 172
    try sync()
    if error != nil { return localctx }
    var la = try self.la(1)
    while la == CELToken.dot {
      state = 168
      let dot = try match(CELToken.dot)
      if error != nil { return localctx }
      if let dot { localctx.ops.append(dot) }
      state = 169
      let id = try match(CELToken.identifier)
      if error != nil { return localctx }
      if let id { localctx.ids.append(id) }
      state = 174
      try sync()
      if error != nil { return localctx }
      la = try self.la(1)
    }
    state = 175
    localctx.op = try match(CELToken.lbrace)
    if error != nil { return localctx }
    state = 177
    try sync()
    if error != nil { return localctx }
    if inSet(try self.la(1), 206_159_478_784) {
      state = 176
      localctx.entries = try fieldInitializerList()
    }
    state = 180
    try sync()
    if error != nil { return localctx }
    if try self.la(1) == CELToken.comma {
      state = 179
      _ = try match(CELToken.comma)
      if error != nil { return localctx }
    }
    state = 182
    _ = try match(CELToken.rbrace)
    if error != nil { return localctx }
    return localctx
  }

  @inline(never)
  private func primaryAlt7(_ base: ParserRuleContext) throws -> ParserRuleContext {
    let localctx = ParserRuleContext(copying: base, label: .constantLiteral)
    enterOuterAlt(localctx)
    state = 183
    try literal()
    return localctx
  }

  // exprList : e+=expr (',' e+=expr)* ;
  func exprList() throws -> ParserRuleContext {
    let localctx = newContext(CELRule.exprList, .exprList)
    try enterRule(localctx, 18)
    enterOuterAlt(localctx)
    body: do {
      state = 186
      localctx.exprs.append(try expr())
      state = 191
      try sync()
      if error != nil { break body }
      var la = try self.la(1)
      while la == CELToken.comma {
        state = 187
        _ = try match(CELToken.comma)
        if error != nil { break body }
        state = 188
        localctx.exprs.append(try expr())
        state = 193
        try sync()
        if error != nil { break body }
        la = try self.la(1)
      }
    }
    try handleErrorExit(localctx)
    try exitRule()
    return localctx
  }

  // listInit : elems+=optExpr (',' elems+=optExpr)* ;
  func listInit() throws -> ParserRuleContext {
    let localctx = newContext(CELRule.listInit, .listInit)
    try enterRule(localctx, 20)
    enterOuterAlt(localctx)
    body: do {
      state = 194
      localctx.elemList.append(try optExpr())
      state = 199
      try sync()
      if error != nil { break body }
      var alt = try adaptivePredict(27)
      if error != nil { break body }
      while alt != 2 && alt != 0 {
        if alt == 1 {
          state = 195
          _ = try match(CELToken.comma)
          if error != nil { break body }
          state = 196
          localctx.elemList.append(try optExpr())
        }
        state = 201
        try sync()
        if error != nil { break body }
        alt = try adaptivePredict(27)
        if error != nil { break body }
      }
    }
    try handleErrorExit(localctx)
    try exitRule()
    return localctx
  }

  // fieldInitializerList : fields+=optField cols+=':' values+=expr
  //                        (',' fields+=optField cols+=':' values+=expr)* ;
  func fieldInitializerList() throws -> ParserRuleContext {
    let localctx = newContext(CELRule.fieldInitializerList, .fieldInitializerList)
    try enterRule(localctx, 22)
    enterOuterAlt(localctx)
    body: do {
      state = 202
      localctx.fields.append(try optField())
      state = 203
      let col = try match(CELToken.colon)
      if error != nil { break body }
      if let col { localctx.cols.append(col) }
      state = 204
      localctx.values.append(try expr())
      state = 212
      try sync()
      if error != nil { break body }
      var alt = try adaptivePredict(28)
      if error != nil { break body }
      while alt != 2 && alt != 0 {
        if alt == 1 {
          state = 205
          _ = try match(CELToken.comma)
          if error != nil { break body }
          state = 206
          localctx.fields.append(try optField())
          state = 207
          let col = try match(CELToken.colon)
          if error != nil { break body }
          if let col { localctx.cols.append(col) }
          state = 208
          localctx.values.append(try expr())
        }
        state = 214
        try sync()
        if error != nil { break body }
        alt = try adaptivePredict(28)
        if error != nil { break body }
      }
    }
    try handleErrorExit(localctx)
    try exitRule()
    return localctx
  }

  // optField : (opt='?')? escapeIdent ;
  func optField() throws -> ParserRuleContext {
    let localctx = newContext(CELRule.optField, .optField)
    try enterRule(localctx, 24)
    enterOuterAlt(localctx)
    body: do {
      state = 216
      try sync()
      if error != nil { break body }
      if try la(1) == CELToken.questionMark {
        state = 215
        localctx.opt = try match(CELToken.questionMark)
        if error != nil { break body }
      }
      state = 218
      _ = try escapeIdent()
    }
    try handleErrorExit(localctx)
    try exitRule()
    return localctx
  }

  // mapInitializerList : keys+=optExpr cols+=':' values+=expr (',' keys+=optExpr cols+=':' values+=expr)* ;
  func mapInitializerList() throws -> ParserRuleContext {
    let localctx = newContext(CELRule.mapInitializerList, .mapInitializerList)
    try enterRule(localctx, 26)
    enterOuterAlt(localctx)
    body: do {
      state = 220
      localctx.keys.append(try optExpr())
      state = 221
      let col = try match(CELToken.colon)
      if error != nil { break body }
      if let col { localctx.cols.append(col) }
      state = 222
      localctx.values.append(try expr())
      state = 230
      try sync()
      if error != nil { break body }
      var alt = try adaptivePredict(30)
      if error != nil { break body }
      while alt != 2 && alt != 0 {
        if alt == 1 {
          state = 223
          _ = try match(CELToken.comma)
          if error != nil { break body }
          state = 224
          localctx.keys.append(try optExpr())
          state = 225
          let col = try match(CELToken.colon)
          if error != nil { break body }
          if let col { localctx.cols.append(col) }
          state = 226
          localctx.values.append(try expr())
        }
        state = 232
        try sync()
        if error != nil { break body }
        alt = try adaptivePredict(30)
        if error != nil { break body }
      }
    }
    try handleErrorExit(localctx)
    try exitRule()
    return localctx
  }

  // escapeIdent : id=IDENTIFIER # SimpleIdentifier | id=ESC_IDENTIFIER # EscapedIdentifier ;
  func escapeIdent() throws -> ParserRuleContext {
    var localctx = newContext(CELRule.escapeIdent, .escapeIdent)
    try enterRule(localctx, 28)
    body: do {
      state = 235
      try sync()
      if error != nil { break body }
      switch try la(1) {
      case CELToken.identifier:
        localctx = ParserRuleContext(copying: localctx, label: .simpleIdentifier)
        enterOuterAlt(localctx)
        state = 233
        localctx.idToken = try match(CELToken.identifier)
        if error != nil { break body }
      case CELToken.escIdentifier:
        localctx = ParserRuleContext(copying: localctx, label: .escapedIdentifier)
        enterOuterAlt(localctx)
        state = 234
        localctx.idToken = try match(CELToken.escIdentifier)
        if error != nil { break body }
      default:
        error = try noViableAltHere()
        break body
      }
    }
    try handleErrorExit(localctx)
    try exitRule()
    return localctx
  }

  // optExpr : (opt='?')? e=expr ;
  func optExpr() throws -> ParserRuleContext {
    let localctx = newContext(CELRule.optExpr, .optExpr)
    try enterRule(localctx, 30)
    enterOuterAlt(localctx)
    body: do {
      state = 238
      try sync()
      if error != nil { break body }
      if try la(1) == CELToken.questionMark {
        state = 237
        localctx.opt = try match(CELToken.questionMark)
        if error != nil { break body }
      }
      state = 240
      localctx.e = try expr()
    }
    try handleErrorExit(localctx)
    try exitRule()
    return localctx
  }

  // literal : sign=MINUS? tok=NUM_INT # Int | tok=NUM_UINT # Uint | sign=MINUS? tok=NUM_FLOAT # Double
  //         | tok=STRING # String | tok=BYTES # Bytes | tok=CEL_TRUE # BoolTrue
  //         | tok=CEL_FALSE # BoolFalse | tok=NUL # Null ;
  @discardableResult
  func literal() throws -> ParserRuleContext {
    var localctx = newContext(CELRule.literal, .literal)
    try enterRule(localctx, 32)
    body: do {
      state = 256
      try sync()
      if error != nil { break body }
      switch try adaptivePredict(35) {
      case 1:
        localctx = ParserRuleContext(copying: localctx, label: .int)
        enterOuterAlt(localctx)
        state = 243
        try sync()
        if error != nil { break body }
        if try la(1) == CELToken.minus {
          state = 242
          localctx.sign = try match(CELToken.minus)
          if error != nil { break body }
        }
        state = 245
        localctx.tok = try match(CELToken.numInt)
        if error != nil { break body }
      case 2:
        localctx = ParserRuleContext(copying: localctx, label: .uint)
        enterOuterAlt(localctx)
        state = 246
        localctx.tok = try match(CELToken.numUint)
        if error != nil { break body }
      case 3:
        localctx = ParserRuleContext(copying: localctx, label: .double)
        enterOuterAlt(localctx)
        state = 248
        try sync()
        if error != nil { break body }
        if try la(1) == CELToken.minus {
          state = 247
          localctx.sign = try match(CELToken.minus)
          if error != nil { break body }
        }
        state = 250
        localctx.tok = try match(CELToken.numFloat)
        if error != nil { break body }
      case 4:
        localctx = ParserRuleContext(copying: localctx, label: .string)
        enterOuterAlt(localctx)
        state = 251
        localctx.tok = try match(CELToken.string)
        if error != nil { break body }
      case 5:
        localctx = ParserRuleContext(copying: localctx, label: .bytes)
        enterOuterAlt(localctx)
        state = 252
        localctx.tok = try match(CELToken.bytes)
        if error != nil { break body }
      case 6:
        localctx = ParserRuleContext(copying: localctx, label: .boolTrue)
        enterOuterAlt(localctx)
        state = 253
        localctx.tok = try match(CELToken.celTrue)
        if error != nil { break body }
      case 7:
        localctx = ParserRuleContext(copying: localctx, label: .boolFalse)
        enterOuterAlt(localctx)
        state = 254
        localctx.tok = try match(CELToken.celFalse)
        if error != nil { break body }
      case 8:
        localctx = ParserRuleContext(copying: localctx, label: .null)
        enterOuterAlt(localctx)
        state = 255
        localctx.tok = try match(CELToken.null)
        if error != nil { break body }
      case 0:
        break body
      default:
        break
      }
    }
    try handleErrorExit(localctx)
    try exitRule()
    return localctx
  }
}
