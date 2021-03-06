import "."/[primitives, arrays, runtime, types, values], ../language/[expressions, number, shortstring], std/[tables, sets, strutils]

template defineMetaProperty(recurWith: untyped): PropertyTag =
  PropertyTag(name: "Meta",
    argumentTypes: @[Type(kind: tyBaseType, baseKind: tyFunction)],
    typeMatcher: proc (t: Type, args: seq[Value]): TypeMatch =
      if t.properties.hasTag(recurWith):
        match(args[0].typeValue.unbox, t.properties.table[recurWith][0].typeValue.unbox)
      else:
        tmFalse)

when defined(gcDestructors):
  var Meta*: PropertyTag
  Meta = defineMetaProperty(Meta)
else:
  proc metaProperty: PropertyTag =
    var prop {.global.}: PropertyTag
    if prop.isNil:
      prop = defineMetaProperty(prop)
    result = prop
  template Meta*: PropertyTag = metaProperty()

proc newContext*(imports: seq[Context]): Context =
  result = Context(stack: Stack(), imports: imports)
  result.top = Scope(context: result)

proc childContext*(context: Context): Context =
  result = newContext(@[context])

proc childScope*(scope: Scope): Scope =
  result = Scope(parent: scope, context: scope.context)

proc refreshStack*(context: Context) =
  ## grow static stack if new variables have been added
  ## recursively do the same for imports
  ## should be called after full compilation
  for im in context.imports:
    im.refreshStack()
  if context.imports.len != context.stack.imports.len:
    var newImports = newArray[Stack](context.imports.len)
    for i in 0 ..< context.stack.imports.len:
      newImports[i] = context.stack.imports[i]
    for i in context.stack.imports.len ..< context.imports.len:
      newImports[i] = context.imports[i].stack
    context.stack.imports = newImports
  if context.stackSize != context.stack.stack.len:
    var newStack = newArray[Value](context.stackSize)
    for i in 0 ..< context.stack.stack.len:
      newStack[i] = context.stack.stack[i]
    context.stack.stack = newStack

proc evaluateStatic*(context: Context, instr: Instruction): Value =
  context.refreshStack()
  instr.evaluate(context.stack)

proc define*(scope: Scope, variable: Variable, inMemory = true) =
  variable.scope = scope
  if inMemory:
    variable.stackIndex = scope.context.stackSize
    inc scope.context.stackSize
  scope.context.allVariables.add(variable)
  scope.variables.add(variable)

proc toInstruction*(st: Statement): Instruction =
  template map[T](s: T): T =
    s
  template map(s: Statement): Instruction =
    s.toInstruction
  template map[T, U](s: (T, U)): untyped =
    (map s[0], map s[1])
  template map(s: seq): Array =
    var arr = newArray[typeof map s[0]](s.len)
    for i in 0 ..< arr.len:
      arr[i] = map s[i]
    arr
  result = case st.kind
  of skNone: Instruction(kind: NoOp)
  of skConstant: Instruction(kind: Constant, constantValue: st.constant)
  of skFunctionCall:
    Instruction(kind: FunctionCall, function: map st.callee,
      arguments: map st.arguments)
  of skDispatch:
    Instruction(kind: Dispatch,
      dispatchFunctions: map st.dispatchees,
      dispatchArguments: map st.dispatchArguments)
  of skSequence: Instruction(kind: Sequence, sequence: map st.sequence)
  of skVariableGet:
    Instruction(kind: VariableGet, variableGetIndex: st.variableGetIndex)
  of skVariableSet:
    Instruction(kind: VariableSet, variableSetIndex: st.variableSetIndex,
      variableSetValue: map st.variableSetValue)
  of skFromImportedStack:
    Instruction(kind: FromImportedStack,
      importedStackIndex: st.importedStackIndex,
      importedStackInstruction: map st.importedStackStatement)
  of skSetAddress:
    Instruction(kind: SetAddress,
      setAddress: map st.setAddress.indices,
      setAddressValue: map st.setAddressValue)
  of skArmStack:
    Instruction(kind: ArmStack, armStackFunction: map st.armStackFunction)
  of skIf:
    Instruction(kind: If, ifCondition: map st.ifCond,
      ifTrue: map st.ifTrue, ifFalse: map st.ifFalse)
  of skWhile:
    Instruction(kind: While, whileCondition: map st.whileCond,
      whileTrue: map st.whileBody)
  of skDoUntil:
    Instruction(kind: DoUntil, doUntilCondition: map st.doUntilCond,
      doUntilTrue: map st.doUntilBody)
  of skEmitEffect:
    Instruction(kind: EmitEffect, effect: map st.effect)
  of skHandleEffect:
    Instruction(kind: HandleEffect, effectHandler: map st.effectHandler,
      effectEmitter: map st.effectBody)
  of skTuple:
    Instruction(kind: BuildTuple, elements: map st.elements)
  of skList:
    Instruction(kind: BuildList, elements: map st.elements)
  of skSet:
    Instruction(kind: BuildSet, elements: map st.elements)
  of skTable:
    Instruction(kind: BuildTable, entries: map st.entries)
  of skComposite:
    Instruction(kind: BuildComposite, composite: toCompositeArray(map st.composite))
  of skGetComposite:
    Instruction(kind: GetComposite, getComposite: map st.getComposite,
      getCompositeId: st.getCompositeName.getCompositeNameId)
  of skSetComposite:
    Instruction(kind: SetComposite, setComposite: map st.setComposite,
      setCompositeId: st.setCompositeName.getCompositeNameId,
      setCompositeValue: map st.setCompositeValue)
  of skGetIndex:
    Instruction(kind: GetIndex, getIndexAddress: map st.getIndexAddress,
      getIndex: st.getIndex)
  of skSetIndex:
    Instruction(kind: SetIndex, setIndexAddress: map st.setIndexAddress,
      setIndex: st.setIndex,
      setIndexValue: map st.setCompositeValue)
  of skUnaryInstruction:
    Instruction(kind: st.unaryInstructionKind, unary: map st.unary)
  of skBinaryInstruction:
    Instruction(kind: st.binaryInstructionKind, binary1: map st.binary1, binary2: map st.binary2)

type
  CompileError* = object of CatchableError
    expression*: Expression

  TypeBoundMatchError* = object of CompileError
    bound*: TypeBound
    `type`*: Type
  
  NoOverloadFoundError* = object of CompileError
    bound*: TypeBound
    scope*: Scope
  
  CannotCallError* = object of NoOverloadFoundError
    `type`*: Type
    argumentTypes*: seq[Type]

proc compile*(scope: Scope, ex: Expression, bound: TypeBound): Statement

proc evaluateStatic*(scope: Scope, ex: Expression, bound: TypeBound = +Ty(Any)): Value =
  scope.context.evaluateStatic(scope.compile(ex, bound).toInstruction)

proc setStatic*(variable: Variable, expression: Expression) =
  variable.scope.context.refreshStack()
  let value = variable.scope.compile(expression, +variable.cachedType)
  variable.cachedType = value.cachedType
  variable.scope.context.stack.set(variable.stackIndex, value.toInstruction.evaluate(variable.scope.context.stack))
  variable.evaluated = true

proc getType*(variable: Variable): Type =
  if variable.cachedType.isNone and not variable.lazyExpression.isNil and not variable.evaluated:
    variable.setStatic(variable.lazyExpression)
  variable.cachedType

proc shallowReference*(v: Variable): VariableReference {.inline.} =
  VariableReference(variable: v, address: VariableAddress(indices: @[v.stackIndex]))

proc symbols*(scope: Scope, name: string, bound: TypeBound, doImports = true): seq[VariableReference] =
  if scope.isNil: return
  if doImports:
    for i, im in scope.context.imports:
      let addrs = symbols(im.top, name, bound)
      for a in addrs:
        var b = a
        b.address.indices.add(i)
        result.add(b)
  if not scope.parent.isNil:
    result.add(symbols(scope.parent, name, bound, doImports = false))
  for i, v in scope.variables:
    if name == v.name and bound.matchBound(v.getType()):
      result.add(v.shallowReference)

import algorithm

proc overloads*(scope: Scope | Context, name: string, bound: TypeBound): seq[VariableReference] =
  result = symbols(scope, name, bound)
  # sort must be stable to preserve definition/import order
  result.sort(
    cmp = proc (a, b: VariableReference): int =
      compare(a.variable.cachedType, b.variable.cachedType),
    order = if bound.variance == Covariant: Ascending else: Descending)
  result.reverse()

proc variableGet*(r: VariableReference): Statement =
  let t = r.variable.cachedType
  result = Statement(kind: skVariableGet,
    variableGetIndex: r.address.indices[0],
    cachedType: t)
  for i in 1 ..< r.address.indices.len:
    result = Statement(kind: skFromImportedStack,
      importedStackIndex: r.address.indices[i],
      importedStackStatement: result,
      cachedType: t)

proc variableSet*(r: VariableReference, value: Statement): Statement =
  let t = r.variable.cachedType
  result = Statement(kind: skSetAddress,
    setAddress: r.address,
    setAddressValue: value,
    cachedType: t)

type
  GenericMatchError* = object of CompileError
    parameter*: TypeParameter
    presumed*: Type
    conflicting*: Type
  
  GenericUnmatchedError* = object of CompileError
    allParameters*: seq[TypeParameter]
    matchedParameters*: ParameterInstantiation

proc matchParameters*(pattern, t: Type, table: var ParameterInstantiation) =
  template match(a, b: Type) = matchParameters(a, b, table)
  template match(a, b: Box[Type]) = matchParameters(a.unbox, b.unbox, table)
  case pattern.kind
  of tyParameter:
    let param = pattern.parameter
    if param in table:
      let oldType = table[param]
      let newType = commonSuperType(oldType, t, doUnion = false)
      if newType.isNone:
        raise (ref GenericMatchError)(
          msg: "param " & $param & " had type " & $newType & " but got " & $t,
          parameter: param,
          presumed: oldType,
          conflicting: t)
      table[param] = newType
    else:
      table[param] = t
  of tyNoneValue, tyInteger, tyUnsigned, tyFloat, tyBoolean,
    tyString, tyExpression, tyStatement, tyScope,
    tyAny, tyNone:
    discard # atoms
  of tyFunction:
    if t.kind == tyFunction:
      match(pattern.arguments, t.arguments)
      match(pattern.returnType, t.returnType)
  of tyTuple:
    if t.kind == tyTuple:
      for i in 0 ..< t.elements.len:
        match(pattern.nth(i), t.elements[i])
      if pattern.elements.len > t.elements.len and not t.varargs.isNone:
        for i in t.elements.len ..< pattern.elements.len:
          match(pattern.elements[i], t.varargs.unbox)
        if not pattern.varargs.isNone:
          match(pattern.varargs, t.varargs)
  of tyReference, tyList, tySet:
    if t.kind == pattern.kind:
      match(pattern.elementType, t.elementType)
  of tyTable:
    if t.kind == pattern.kind:
      match(pattern.keyType, t.keyType)
      match(pattern.valueType, t.valueType)
  of tyComposite:
    discard # XXX todo
  of tyType:
    if t.kind == pattern.kind:
      match(pattern.typeValue, t.typeValue)
    else:
      # wonky
      match(pattern.typeValue.unbox, t)
  of tyUnion, tyIntersection, tyNot:
    discard # XXX what
  of tyWithProperty:
    if t.kind == pattern.kind:
      match(pattern.typeWithProperty, t.typeWithProperty)
    else:
      match(pattern.typeWithProperty.unbox, t)
  of tyBaseType, tyCustomMatcher:
    discard # no type to traverse

proc fillParameters*(pattern: var Type, table: ParameterInstantiation) =
  template fill(a: var Type) = fillParameters(a, table)
  template fill(a: var Box[Type]) =
    if not a.isNil:
      var newType: Type = a.unbox
      fillParameters(newType, table)
      a = newType.box
  case pattern.kind
  of tyParameter:
    pattern = table[pattern.parameter]
  of tyNoneValue, tyInteger, tyUnsigned, tyFloat, tyBoolean,
    tyString, tyExpression, tyStatement, tyScope,
    tyAny, tyNone, tyBaseType, tyCustomMatcher:
    discard
  of tyFunction:
    fill(pattern.arguments)
    fill(pattern.returnType)
  of tyTuple:
    for e in pattern.elements.mitems:
      fill(e)
    fill(pattern.varargs)
  of tyReference, tyList, tySet:
    fill(pattern.elementType)
  of tyTable:
    fill(pattern.keyType)
    fill(pattern.valueType)
  of tyComposite:
    for _, f in pattern.fields.mpairs:
      fill(f)
  of tyType:
    fill(pattern.typeValue)
  of tyUnion, tyIntersection:
    for o in pattern.operands.mitems:
      fill(o)
  of tyNot:
    fill(pattern.notType)
  of tyWithProperty:
    fill(pattern.typeWithProperty)

template constant*(value: Value, ty: Type): Statement =
  Statement(kind: skConstant, constant: value, cachedType: ty)
template constant*(value: untyped, ty: Type): Statement =
  constant(toValue(value), ty)
template constant*(value: untyped, ty: TypeKind): Statement =
  constant(value, Type(kind: ty))
template constant*(value: string): Statement = constant(value, tyString)
template constant*(value: int): Statement = constant(value, tyInteger)
template constant*(value: uint): Statement = constant(value, tyUnsigned)
template constant*(value: float): Statement = constant(value, tyFloat)

proc compileNumber*(ex: Expression, bound: TypeBound): Statement =
  let s = $ex.number
  result = Statement(kind: skConstant)
  case ex.number.kind
  of Integer:
    let val = parseInt(s)
    if bound.boundType.kind == tyFloat:
      result = constant(val.float)
    elif val >= 0 and bound.boundType.kind == tyUnsigned:
      result = constant(val.uint)
    else:
      result = constant(val)
  of Floating:
    result = constant(parseFloat(s))
  of Unsigned:
    result = constant(parseUInt(s))

template defaultBound: untyped = +Ty(Any)
template map(ex: Expression, bound = defaultBound): Statement =
  compile(scope, ex, bound)
template forward(ex: Expression): Statement =
  compile(scope, ex, bound)
proc isSingleColon(e: Expression): bool =
  e.kind == Symbol and e.symbol == short":"

proc resolve*(scope: Scope, ex: Expression, name: string, bound: TypeBound): VariableReference =
  let overloads = overloads(scope, name, bound)
  if overloads.len == 0:
    raise (ref NoOverloadFoundError)(
      expression: ex,
      bound: bound,
      scope: scope,
      msg: "no overloads with bound " & $bound & " for " & $ex)
  result = overloads[0]
  if result.variable.genericParams.len != 0:
    var matches: ParameterInstantiation = initTable[TypeParameter, Type](result.variable.genericParams.len)
    try:
      matchParameters(result.variable.cachedType, bound.boundType, matches)
    except GenericMatchError as e:
      e.expression = ex
      raise e
    var unmatchedParams = result.variable.genericParams
    # XXX continue
    # use single memory slot + fake variables with filled out types for erased
    # real variables for monomorphized
  if not bound.matchBound(result.variable.cachedType):
    raise (ref TypeBoundMatchError)(
      expression: ex,
      bound: bound,
      type: result.variable.cachedType,
      msg: "bound " & $bound & " does not match type " & $result.variable.cachedType &
       " in expression " & $ex)

proc compileCall*(scope: Scope, ex: Expression, bound: TypeBound,
  argumentStatements: sink seq[Statement] = newSeq[Statement](ex.arguments.len)): Statement

proc compileProperty*(scope: Scope, ex: Expression, lhs: Statement, name: string, bound: TypeBound): Statement =
  result = nil
  if lhs.cachedType.kind == tyComposite and lhs.cachedType.fields.hasKey(name):
    result = Statement(kind: skGetComposite,
      cachedType: lhs.cachedType.fields[name],
      getComposite: lhs,
      getCompositeName: name)
  else:
    let ident = Expression(kind: Name, identifier: "." & name)
    try:
      result = forward(
        Expression(kind: PathCall,
          address: ident,
          arguments: @[ex.left]))
    except NoOverloadFoundError as e:
      if not same(ident, e.expression):
        raise

proc compileMetaCall*(scope: Scope, name: string, ex: Expression, bound: TypeBound, argumentStatements: var seq[Statement]): Statement =
  result = nil
  var argumentTypes = newSeq[Type](ex.arguments.len)
  for t in argumentTypes.mitems: t = Ty(Any)
  # XXX pass type bound as well as scope, to pass both to a compile proc
  var realArgumentTypes = newSeq[Type](ex.arguments.len + 1)
  realArgumentTypes[0] = Ty(Scope)
  for i in 1 ..< realArgumentTypes.len:
    realArgumentTypes[i] = union(Ty(Expression), Ty(Statement))
  # get all metas first and type statements accordingly
  var allMetas = overloads(scope, name,
    *funcType(Ty(Statement), realArgumentTypes).withProperties(
      property(Meta, @[toValue funcType(if bound.variance == Covariant: Ty(Any) else: bound.boundType, argumentTypes)])))
  if allMetas.len != 0:
    var makeStatement = newSeq[bool](ex.arguments.len)
    var metaTypes = newSeq[Type](allMetas.len)
    for i, v in allMetas:
      let ty = v.variable.cachedType
      let metaTy = v.variable.cachedType.properties.getArguments(Meta)[0].typeValue.unbox
      metaTypes[i] = metaTy
      for i in 0 ..< ex.arguments.len:
        if matchBound(+Ty(Statement), ty.param(i + 1)):
          makeStatement[i] = true
          argumentTypes[i] = commonSubType(argumentTypes[i], metaTy.param(i))
    for i, x in makeStatement:
      if x:
        try:
          argumentStatements[i] = map(ex.arguments[i], +argumentTypes[i])
        except NoOverloadFoundError as e:
          if same(e.expression, ex.arguments[i]):
            reset(allMetas)
            break
        except TypeBoundMatchError as e:
          if same(e.expression, ex.arguments[i]):
            reset(allMetas)
            break
        argumentTypes[i] = commonSubType(argumentTypes[i], argumentStatements[i].cachedType)
    var superMetas, subMetas: typeof(allMetas)
    for i, m in allMetas:
      let mt = metaTypes[i]
      if matchBound(+mt,
        funcType(if bound.variance == Covariant: Ty(Any) else: bound.boundType, argumentTypes)):
        superMetas.add(m)
      if matchBound(
        +funcType(if bound.variance == Covariant: union() else: bound.boundType, argumentTypes),
        mt):
        subMetas.add(m)
    superMetas.sort(
      cmp = proc (a, b: VariableReference): int =
        compare(a.variable.cachedType, b.variable.cachedType),
      order = Descending)
    subMetas.sort(
      cmp = proc (a, b: VariableReference): int =
        compare(a.variable.cachedType, b.variable.cachedType),
      order = Ascending)
    if superMetas.len != 0:
      let meta = superMetas[0]
      let ty = meta.variable.cachedType
      var arguments = newSeq[Statement](ex.arguments.len + 1)
      arguments[0] = constant(scope, Ty(Scope))
      for i in 0 ..< ex.arguments.len:
        if matchBound(+Ty(Statement), ty.param(i + 1)):
          arguments[i + 1] = constant(argumentStatements[i], Ty(Statement))
        else:
          arguments[i + 1] = constant(copy ex.arguments[i], Ty(Expression))
      let call = Statement(kind: skFunctionCall,
        callee: variableGet(meta),
        arguments: arguments).toInstruction
      result = scope.context.evaluateStatic(call).statementValue
    else:
      for d in subMetas:
        var arguments = newArray[Value](ex.arguments.len + 1)
        arguments[0] = toValue scope
        for i in 0 ..< ex.arguments.len:
          if matchBound(+Ty(Statement), d.variable.cachedType.param(i + 1)):
            arguments[i + 1] = toValue argumentStatements[i]
          else:
            arguments[i + 1] = toValue copy ex.arguments[i]
        if checkType(toValue arguments, d.variable.cachedType.arguments.unbox):
          var argumentStatement = newSeq[Statement](arguments.len)
          for i, a in arguments: argumentStatement[i] = constant(a, a.getType)
          let call = Statement(kind: skFunctionCall,
            callee: variableGet(d),
            arguments: argumentStatement).toInstruction
          result = scope.context.evaluateStatic(call).statementValue
          break

proc compileRuntimeCall*(scope: Scope, ex: Expression, bound: TypeBound,
  argumentStatements: var seq[Statement],
  argumentTypes: var seq[Type], 
  functionType: var Type): Statement =
  result = nil
  for i in 0 ..< ex.arguments.len:
    if argumentStatements[i].isNil:
      argumentStatements[i] = map(ex.arguments[i])
    argumentTypes[i] = argumentStatements[i].cachedType
  functionType = funcType(if bound.variance == Covariant: Ty(Any) else: bound.boundType, argumentTypes)
  # lowest supertype function:
  try:
    let callee = map(ex.address, -functionType)
    result = Statement(kind: skFunctionCall,
      cachedType: callee.cachedType.returnType.unbox,
      callee: callee,
      arguments: argumentStatements)
  except NoOverloadFoundError as e:
    # dispatch lowest subtype functions in order:
    if same(e.expression, ex.address) and ex.address.isIdentifier(name):
      functionType.returnType = box do:
        if bound.variance == Covariant:
          union()
        else:
          bound.boundType
      let subs = overloads(scope, name, +functionType)
      if subs.len != 0:
        var dispatchees = newSeq[(seq[Type], Statement)](subs.len)
        for i, d in dispatchees.mpairs:
          let t = subs[i].variable.cachedType
          d[0].newSeq(argumentStatements.len)
          for i in 0 ..< argumentStatements.len:
            let pt = t.param(i)
            if matchBound(-argumentTypes[i], pt):
              # optimize checking types we know match
              # XXX do this recursively?
              d[0][i] = Ty(Any)
            else:
              d[0][i] = pt
          d[1] = variableGet(subs[i])
        result = Statement(kind: skDispatch,
          cachedType: functionType.returnType.unbox, # we could calculate a union here but it's not worth dealing with a typeclass
          dispatchees: dispatchees,
          dispatchArguments: argumentStatements)

proc compileCall*(scope: Scope, ex: Expression, bound: TypeBound,
  argumentStatements: sink seq[Statement] = newSeq[Statement](ex.arguments.len)): Statement =
  # XXX (1) named & default arguments with signature property (instead of composite?) meaning handle colon expressions
  if ex.address.isIdentifier(name):
    result = compileMetaCall(scope, name, ex, bound, argumentStatements)
  if result.isNil:
    var argumentTypes = newSeq[Type](ex.arguments.len)
    var functionType: Type
    result = compileRuntimeCall(scope, ex, bound, argumentStatements, argumentTypes, functionType)
    assert functionType.kind != tyNone
    # .call, should recurse but compiled arguments should be reused:
    if result.isNil:
      let callee = map ex.address
      argumentStatements.insert(callee, 0)
      argumentTypes.insert(callee.cachedType, 0)
      functionType = funcType(if bound.variance == Covariant: Ty(Any) else: bound.boundType, argumentTypes)
      let overs = overloads(scope, ".call", -functionType)
      if overs.len != 0:
        let dotCall = variableGet(overs[0])
        result = Statement(kind: skFunctionCall,
          cachedType: dotCall.cachedType.returnType.unbox,
          callee: callee,
          arguments: argumentStatements)
      else:
        raise (ref CannotCallError)(
          expression: ex.address,
          bound: bound,
          scope: scope,
          argumentTypes: argumentTypes,
          type: callee.cachedType,
          msg: "no way to call " & $ex.address & " of type " & $callee.cachedType &
            " found for argument types " & $argumentTypes)

proc compileTupleExpression*(scope: Scope, ex: Expression, bound: TypeBound): Statement =
  if ex.elements.len != 0 and (ex.elements[0].kind == Colon or
    ex.elements[0].isSingleColon):
    if bound.boundType.kind == tyComposite:
      assert bound.boundType.fields.len == ex.elements.len, "tuple bound type lengths do not match"
    result = Statement(kind: skComposite, cachedType:
      Type(kind: tyComposite, fields: initTable[string, Type](ex.elements.len)))
    for e in ex.elements:
      if e.isSingleColon: continue
      assert e.kind == Colon, "composite literal must only have colon expressions"
      assert e.left.kind == Name, "composite literal has non-name left hand side on colon expression"
      let k = e.left.identifier
      let bv = if bound.boundType.kind == tyComposite and k in bound.boundType.fields:
        bound.boundType.fields[k] * bound.variance
      else:
        defaultBound
      let v = map(e.right, bv)
      result.composite.add((key: k, value: v))
      result.cachedType.fields[k] = v.cachedType
  else:
    if bound.boundType.kind == tyTuple:
      assert bound.boundType.elements.len == ex.elements.len, "tuple bound type lengths do not match"
    result = Statement(kind: skTuple, cachedType:
      Type(kind: tyTuple, elements: newSeqOfCap[Type](ex.elements.len)))
    for i, e in ex.elements:
      let element = if bound.boundType.kind == tyTuple:
        map(e, bound.boundType.elements[i] * bound.variance)
      else:
        map e
      result.elements.add(element)
      result.cachedType.elements.add(element.cachedType)

proc compileArrayExpression*(scope: Scope, ex: Expression, bound: TypeBound): Statement =
  result = Statement(kind: skList, cachedType: Ty(List))
  var boundSet = bound.boundType.kind == tyList 
  var b =
    if boundSet:
      bound.boundType.elementType.unbox * bound.variance
    else:
      defaultBound
  for e in ex.elements:
    let element = map(e, b)
    result.elements.add(element)
    if result.cachedType.elementType.isNone or result.cachedType.elementType.unbox < element.cachedType:
      result.cachedType.elementType = box element.cachedType
    if not boundSet:
      b = +element.cachedType
      boundSet = true

proc compileSetExpression*(scope: Scope, ex: Expression, bound: TypeBound): Statement =
  if ex.elements.len != 0 and (ex.elements[0].kind == Colon or
    ex.elements[0].isSingleColon):
    result = Statement(kind: skTable, cachedType: Ty(Table))
    var boundSet = bound.boundType.kind == tyTable
    var (bk, bv) =
      if boundSet:
        (bound.boundType.keyType.unbox * bound.variance,
          bound.boundType.valueType.unbox * bound.variance)
      else:
        (defaultBound, defaultBound)
    for e in ex.elements:
      if e.isSingleColon: continue
      assert e.kind == Colon, "table literal must only have colon expressions"
      let k = map(e.left, bk)
      let v = map(e.right, bv)
      result.entries.add((key: k, value: v))
      if result.cachedType.keyType.isNone or result.cachedType.keyType.unbox < k.cachedType:
        result.cachedType.keyType = box k.cachedType
      if result.cachedType.valueType.isNone or result.cachedType.valueType.unbox < v.cachedType:
        result.cachedType.valueType = box v.cachedType
      if not boundSet:
        bk = +k.cachedType
        bv = +v.cachedType
        boundSet = true
  else:
    result = Statement(kind: skSet, cachedType: Ty(Set))
    var boundSet = bound.boundType.kind == tySet 
    var b =
      if boundSet:
        bound.boundType.elementType.unbox * bound.variance
      else:
        defaultBound
    for e in ex.elements:
      let element = map(e, b)
      result.elements.add(element)
      if result.cachedType.elementType.isNone or result.cachedType.elementType.unbox < element.cachedType:
        result.cachedType.elementType = box element.cachedType
      if not boundSet:
        b = +element.cachedType
        boundSet = true

proc compileBlock*(scope: Scope, ex: Expression, bound: TypeBound): Statement =
  result = Statement(kind: skSequence)
  for i, e in ex.statements:
    let b =
      if i == ex.statements.high:
        bound
      else:
        -union() # like void
    let element = map(e, bound = b)
    result.sequence.add(element)
    if i == ex.statements.high:
      result.cachedType = element.cachedType

proc compile*(scope: Scope, ex: Expression, bound: TypeBound): Statement =
  # move some things out to procs
  case ex.kind
  of None: result = Statement(kind: skNone, cachedType: Ty(None))
  of Number: result = compileNumber(ex, bound)
  of String: result = constant(ex.str)
  of Wrapped: result = forward(ex.wrapped)
  of Name, Symbol:
    # XXX warn on ambiguity, thankfully recency is accounted for
    let name = if ex.kind == Symbol: $ex.symbol else: ex.identifier
    result = variableGet(resolve(scope, ex, name, bound))
  of Dot:
    if ex.right.kind == Name:
      let lhs = map ex.left
      let name = ex.right.identifier
      result = compileProperty(scope, ex, lhs, name, bound)
    if result.isNil:
      result = forward(
        Expression(kind: PathCall,
          address: Expression(kind: Name, identifier: "."),
          arguments: @[ex.left, ex.right]))
  of CallKinds: result = compileCall(scope, ex, bound)
  of Subscript:
    # what specialization can go here
    result = forward(Expression(kind: PathCall,
      address: Expression(kind: Symbol, symbol: short".[]"),
      arguments: @[ex.address] & ex.arguments))
  of CurlySubscript:
    result = forward(Expression(kind: PathCall,
      address: Expression(kind: Symbol, symbol: short".{}"),
      arguments: @[ex.address] & ex.arguments))
  of Colon:
    assert false, "cannot compile lone colon expression"
  of Comma, Tuple:
    result = compileTupleExpression(scope, ex, bound)
  of ExpressionKind.Array:
    result = compileArrayExpression(scope, ex, bound)
  of Set:
    result = compileSetExpression(scope, ex, bound)
  of Block, SemicolonBlock:
    result = compileBlock(scope, ex, bound)
  if not bound.matchBound(result.cachedType):
    raise (ref TypeBoundMatchError)(
      expression: ex,
      bound: bound,
      type: result.cachedType,
      msg: "bound " & $bound & " does not match type " & $result.cachedType &
       " in expression " & $ex)

type Program* = Function #[object
  # this is just function
  stack*: Stack
  instruction*: Instruction]#

proc compile*(ex: Expression, imports: seq[Context], bound: TypeBound = +Ty(Any)): Program =
  new(result)
  var context = newContext(imports)
  result.instruction = compile(context.top, ex, bound).toInstruction
  context.refreshStack()
  result.stack = context.stack

proc run*(program: Program, effectHandler: EffectHandler = nil): Value =
  evaluate(program.instruction, program.stack, effectHandler)
