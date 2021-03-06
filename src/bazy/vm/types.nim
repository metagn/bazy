import "."/[primitives, values], std/[tables, sets]

proc hasTag*(properties: Properties, property: PropertyTag): bool {.inline.} =
  properties.table.hasKey(property)

proc getArguments*(properties: Properties, property: PropertyTag): seq[Value] {.inline.} =
  properties.table[property]

iterator items*(properties: Properties): Property =
  for p, args in properties.table:
    yield Property(tag: p, arguments: args)

proc property*(tag: PropertyTag, args: varargs[Value]): Property {.inline.} =
  assert tag.argumentTypes.len == args.len, "argument length has to match"
  Property(tag: tag, arguments: @args)

proc property*(prop: Property): Property {.inline.} = prop

proc properties*(ps: varargs[Property, property]): Properties =
  result.table = initTable[PropertyTag, seq[Value]](ps.len)
  for p in ps:
    result.table[p.tag] = p.arguments

proc withProperties*(ty: sink Type, ps: varargs[Property, property]): Type {.inline.} =
  ty.properties = properties(ps)
  ty

const
  allTypeKinds* = {low(TypeKind)..high(TypeKind)}
  concreteTypeKinds* = {tyNoneValue..tyType}
  typeclassTypeKinds* = {tyAny..tyWithProperty}
  matcherTypeKinds* = typeclassTypeKinds + {tyCustomMatcher}
  atomicTypes* = {tyNoneValue, tyInteger, tyUnsigned, tyFloat, tyBoolean,
    tyString, tyExpression, tyStatement, tyScope}
  highestNonMatching* = tmFalse
  lowestMatching* = tmTrue

proc tupleType*(s: varargs[Type]): Type =
  Type(kind: tyTuple, elements: @s)

proc funcType*(returnType: Type, arguments: varargs[Type]): Type {.inline.} =
  Type(kind: tyFunction, returnType: returnType.box, arguments: tupleType(arguments).box)

proc tupleTypeWithVarargs*(s: varargs[Type], varargs: Type): Type =
  Type(kind: tyTuple, elements: @s, varargs: varargs.box)

proc funcTypeWithVarargs*(returnType: Type, arguments: varargs[Type], varargs: Type): Type {.inline.} =
  Type(kind: tyFunction, returnType: returnType.box, arguments: tupleTypeWithVarargs(arguments, varargs).box)

proc union*(s: varargs[Type]): Type =
  Type(kind: tyUnion, operands: @s)

const definiteTypeLengths*: array[TypeKind, int] = [
  tyNone: 0,
  tyNoneValue: 0,
  tyInteger: 0,
  tyUnsigned: 0,
  tyFloat: 0,
  tyBoolean: 0,
  tyFunction: 2,
  tyTuple: -1,
  tyReference: 1,
  tyList: 1,
  tyString: 0,
  tySet: 1,
  tyTable: 2,
  tyExpression: 0,
  tyStatement: 0,
  tyScope: 0,
  tyComposite: -1,
  tyType: 1,
  tyAny: 0,
  tyUnion: -1,
  tyIntersection: -1,
  tyNot: 1,
  tyBaseType: -1,
  tyWithProperty: -1,
  tyCustomMatcher: 0,
  tyParameter: -1,
  #tyGeneric: -1
]

proc len*(t: Type): int =
  result = definiteTypeLengths[t.kind]
  if result < 0:
    case t.kind
    of tyTuple:
      if t.varargs.isNone:
        result = t.elements.len
    of tyUnion, tyIntersection:
      result = t.operands.len
    else: discard

proc hasNth*(t: Type, i: int): bool {.inline.} =
  i < t.len or (t.kind == tyTuple and not t.varargs.isNone)

proc nth*(t: Type, i: int): Type =
  case t.kind
  of tyNoneValue, tyInteger, tyUnsigned, tyFloat, tyBoolean,
    tyString, tyExpression, tyStatement, tyScope,
    tyAny, tyNone:
    discard # inapplicable
  of tyFunction:
    if i == 0:
      result = t.arguments.unbox
    else:
      result = t.returnType.unbox
  of tyTuple:
    if i < t.elements.len or t.varargs.isNone:
      result = t.elements[i]
    else:
      result = t.varargs.unbox
  of tyReference, tyList, tySet:
    result = t.elementType.unbox
  of tyTable:
    if i == 0:
      result = t.keyType.unbox
    else:
      result = t.valueType.unbox
  of tyComposite:
    discard # inapplicable
  of tyType:
    result = t.typeValue.unbox
  of tyUnion, tyIntersection:
    # this is actually not supposed to happen
    result = t.operands[i]
  of tyNot:
    result = t.notType.unbox
  of tyBaseType:
    discard # inapplicable
  of tyWithProperty:
    discard # inapplicable
  of tyCustomMatcher:
    discard # inapplicable
  of tyParameter:#, tyGeneric:
    discard # what

proc param*(t: Type, i: int): Type {.inline.} =
  assert t.kind == tyFunction
  t.arguments.unbox.nth(i)

proc matches*(tm: TypeMatch): bool {.inline.} =
  tm >= lowestMatching

proc boolMatch*(b: bool): TypeMatch {.inline.} =
  if b: tmTrue else: tmFalse

template min*(a, b: TypeMatch): TypeMatch =
  let am = a
  (if am == tmNone: am
  else: system.min(am, b))

proc `+`*(t: Type): TypeBound {.inline.} = TypeBound(boundType: t, variance: Covariant)
proc `-`*(t: Type): TypeBound {.inline.} = TypeBound(boundType: t, variance: Contravariant)
proc `~`*(t: Type): TypeBound {.inline.} = TypeBound(boundType: t, variance: Invariant)
proc `*`*(t: Type): TypeBound {.inline.} = TypeBound(boundType: t, variance: Ultravariant)
proc `*`*(t: Type, variance: Variance): TypeBound {.inline.} = TypeBound(boundType: t, variance: variance)

proc converse*(tm: TypeMatch): TypeMatch =
  case tm
  of tmEqual, tmNone, tmAlmostEqual, tmUnknown: tm
  of tmTrue: tmFalse
  of tmFalse: tmTrue
  of tmFiniteTrue, tmGeneric: tmFiniteFalse
  of tmFiniteFalse: tmFiniteTrue

proc match*(matcher, t: Type): TypeMatch

proc match*(b: TypeBound, t: Type): TypeMatch =
  case b.variance
  of Covariant:
    result = b.boundType.match(t)
    if result == tmUnknown:
      result = converse t.match(b.boundType)
  of Contravariant:
    result = t.match(b.boundType)
    if result == tmUnknown:
      result = converse b.boundType.match(t)
  of Invariant:
    result = min(b.boundType.match(t), converse t.match(b.boundType))
  of Ultravariant:
    result = b.boundType.match(t)
    if result != tmNone:
      result = max(result, converse t.match(b.boundType))

proc matchBound*(b: TypeBound, t: Type): bool {.inline.} =
  b.match(t).matches

proc match*(matcher, t: Type): TypeMatch =
  # commutativity rules:
  # must be commutative when equal
  # otherwise either order can give none, in which the non-none result matters
  # otherwise generally should be anticommutative, but this is not necessary
  # properties do not have effect on default types besides dropping equal to almost equal
  if matcher == t: return tmEqual
  result = case matcher.kind
  of concreteTypeKinds:
    if matcher.kind != t.kind:
      return case t.kind
      of concreteTypeKinds:
        tmNone
      else:
        tmUnknown
    case matcher.kind
    of atomicTypes * concreteTypeKinds:
      tmAlmostEqual
    of tyReference, tyList, tySet:
      match(+matcher.elementType.unbox, t.elementType.unbox)
    of tyTuple:
      if matcher.elements.len != t.elements.len and matcher.varargs.isNone and t.varargs.isNone:
        return tmNone
      var max = t.elements.len
      if matcher.elements.len > t.elements.len and (max = matcher.elements.len; t.varargs.isNone):
        return tmNone
      var res = tmAlmostEqual
      for i in 0 ..< max:
        let m = match(+matcher.nth(i), t.nth(i))
        if m < res: res = m
        if res <= tmNone: return res
      if not matcher.varargs.isNone and not t.varargs.isNone:
        let vm = match(+matcher.varargs.unbox, t.varargs.unbox)
        if vm < res: res = vm
      res
    of tyFunction:
      min(
        match(-matcher.returnType.unbox, t.returnType.unbox),
        match(+matcher.arguments.unbox, t.arguments.unbox))
    of tyTable:
      min(
        match(+matcher.keyType.unbox, t.keyType.unbox),
        match(+matcher.valueType.unbox, t.valueType.unbox))
    of tyComposite:
      proc tableMatch[T](t1, t2: Table[T, Type]): TypeMatch =
        result = tmEqual
        if t1.len != t2.len: return tmNone
        for k, v1 in t1:
          if k notin t2: return tmNone
          let m = match(+v1, t2[k])
          if m <= tmNone: return m
          elif m < result: result = m
      tableMatch(matcher.fields, t.fields)
    of tyType:
      match(+matcher.typeValue.unbox, t.typeValue.unbox)
    of allTypeKinds - concreteTypeKinds: tmUnknown # unreachable
  of tyAny: tmTrue
  of tyNone: tmUnknown
  of tyUnion:
    var max = tmFiniteFalse
    for a in matcher.operands:
      let m = match(+a, t)
      if m > max: max = m
      if max >= tmFiniteTrue:
        max = tmFiniteTrue
        break
    max
  of tyIntersection:
    var min = tmFiniteTrue
    for a in matcher.operands:
      let m = match(+a, t)
      if m < min: min = m
      if min <= tmFiniteFalse:
        min = tmFiniteFalse
        break
    min
  of tyNot:
    boolMatch not match(matcher.notType.unbox, t).matches
  of tyBaseType:
    boolMatch t.kind == matcher.baseKind
  of tyCustomMatcher:
    if matcher.typeMatcher.isNil:
      tmNone
    else:
      matcher.typeMatcher(t)
  of tyWithProperty:
    min(
      if not t.properties.hasTag(matcher.withProperty): tmFiniteFalse else: tmAlmostEqual,
      match(+matcher.typeWithProperty.unbox, t))
  of tyParameter:
    min(
      tmGeneric,
      match(matcher.parameter.bound, t))
  #of tyGeneric:
  #  min(
  #    tmGeneric,
  #    match(matcher.genericPattern[], t))
  result = min(result, tmAlmostEqual)
  if result.matches:
    for p, args in matcher.properties.table:
      if not p.typeMatcher.isNil:
        result = min(result, p.typeMatcher(t, args))
        if result <= tmNone: return result

proc compare*(m1, m2: TypeMatch): int {.inline.} =
  ord(m1) - ord(m2)

proc compare*(t1, t2: Type): int =
  ## t1 < t2 mirrors being a subtype
  let
    m1 = t1.match(t2)
    m2 = t2.match(t1)
  assert not (m1 == tmEqual and m1 != m2), "equal match must be commutative"
  compare(m1, m2)

proc `<`*(a, b: Type): bool {.inline.} = compare(a, b) < 0
proc `<=`*(a, b: Type): bool {.inline.} = compare(a, b) <= 0
proc `>`*(a, b: Type): bool {.inline.} = compare(a, b) > 0
proc `>=`*(a, b: Type): bool {.inline.} = compare(a, b) >= 0

proc commonSubType*(a, b: Type, doUnion = true): Type =
  let
    m1 = a.match(b)
    m2 = b.match(a)
  let cmp = compare(m1, m2)
  if cmp > 0:
    b
  elif cmp < 0:
    a
  elif m1 in {tmEqual, tmAlmostEqual}:
    a
  elif doUnion: # union here meaning either
    union(a, b)
  else:
    Ty(None)

proc commonSuperType*(a, b: Type, doUnion = true): Type =
  let
    m1 = a.match(b)
    m2 = b.match(a)
  let cmp = compare(m1, m2)
  if cmp > 0:
    a
  elif cmp < 0:
    b
  elif m1 in {tmEqual, tmAlmostEqual}:
    a
  elif doUnion:
    union(a, b)
  else:
    Ty(None)

import arrays

proc checkType*(value: Value, t: Type): bool =
  template eachAre(iter; types: seq[Type]): untyped =
    let ts = types; var yes = true; var i = 0
    for it in iter:
      if (i >= ts.len) or (not checkType(it, ts[i])):
        yes = false; break
      inc i
    yes and i == types.len
  template eachAre(iter; typ: Type): untyped =
    let ty = typ; var yes = true
    for it in iter:
      if not checkType(it, ty):
        yes = false; break
    yes
  template eachAreTable(iter; kty, vty: Type): untyped =
    let kt = kty; let vt = vty; var yes = true
    for key, value in iter:
      if not checkType(key, kt) or not checkType(value, vt):
        yes = false; break
    yes
  result = case t.kind
  of tyNoneValue: value.kind == vkNone
  of tyInteger: value.kind == vkInteger
  of tyUnsigned: value.kind == vkUnsigned
  of tyFloat: value.kind == vkFloat
  of tyBoolean: value.kind == vkBoolean
  of tyFunction:
    # XXX (2) no information about signature
    value.kind in {vkFunction, vkNativeFunction}
  of tyTuple:
    value.kind == vkArray and value.tupleValue.unref.eachAre(t.elements)
  of tyReference:
    value.kind == vkReference and (value.referenceValue.isNil or
      value.referenceValue[].checkType(t.elementType.unbox))
  of tyList:
    value.kind == vkList and value.listValue.unref.eachAre(t.elementType.unbox)
  of tyString: value.kind == vkString
  of tySet:
    value.kind == vkSet and value.setValue.unbox.eachAre(t.elementType.unbox)
  of tyTable:
    value.kind == vkTable and value.tableValue.unbox.eachAreTable(t.keyType.unbox, t.valueType.unbox)
  of tyExpression: value.kind == vkExpression
  of tyStatement: value.kind == vkStatement
  of tyScope: value.kind == vkScope
  of tyComposite:
    value.kind == vkComposite and (block:
      var res = false
      var i = 0
      for key, value in value.compositeValue.unref:#.items:
        if (i >= value.compositeValue.unref.len) or (not checkType(value, t.fields[key.getCompositeName])):
          res = false; break
        inc i
      i == t.fields.len and res)
  of tyType: value.kind == vkType and t.typeValue.unbox.match(value.typeValue.unbox).matches
  of tyAny: true
  of tyNone: false
  of tyUnion:
    var res = false
    for ty in t.operands:
      if value.checkType(ty):
        res = true
        break
    res
  of tyIntersection:
    var res = true
    for ty in t.operands:
      if not value.checkType(ty):
        res = false
        break
    res
  of tyNot: not value.checkType(t.notType.unbox)
  of tyBaseType: value.getType.kind == t.baseKind # XXX unbox here is expensive
  of tyWithProperty:
    value.checkType(t.typeWithProperty.unbox) and value.getType.properties.hasTag(t.withProperty)
  of tyCustomMatcher: not t.valueMatcher.isNil and t.valueMatcher(value)
  of tyParameter: value.checkType(t.parameter.bound.boundType)
  #of tyGeneric: value.checkType(t.genericPattern[])
  if result:
    for p, args in t.properties.table:
      if not p.valueMatcher.isNil:
        result = result and p.valueMatcher(value, args)
        if not result: return result
