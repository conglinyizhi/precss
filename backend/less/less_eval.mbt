///|
/// LESS 独立引擎：求值
///
/// 实现 LESS 的变量 lazy 作用域（最后定义优先、可用后定义）、嵌套 `&`、
/// 类 mixin 混入、基础运算、@media、@import 内联。
/// 不复用 SCSS 引擎——语义按 LESS 自带规则。
priv struct Env {
  vars : Map[String, Array[String]]
  mixins : Map[String, (Array[String], Array[LessNode])]
  parent : Env?
}

///|
/// 顶层求值入口：返回 css 字符串
pub fn eval_less(
  nodes : Array[LessNode],
  read : ((String) -> String raise @core.CompileError)?,
) -> String raise @core.CompileError {
  let env = new_scope(nodes, None)
  let sb = StringBuilder()
  ignore(gen_block(nodes, "", env, read, sb))
  normalize_tail(sb.to_string())
}

///|
/// 统一尾换行：块之间保留空行，末尾只留一个 `\n`
///
/// `gen_block` 在每个写出的节点后补一个分隔 `\n`，顶层最后一个节点会多出
/// 一个尾换行：less 引擎吐 2 个、scss 引擎吐 1 个，于是 `compile_many`
/// 拼接时 scss 段和 less 段的段落间距参差。这里只修尾巴，不动块间空行。
fn normalize_tail(s : String) -> String {
  let mut end = s.length()
  while end > 0 && s[end - 1] == '\n' {
    end -= 1
  }
  if end == 0 {
    // 空串或只剩换行
    ""
  } else {
    s[0:end].to_owned() + "\n"
  }
}

///|
/// 收集一个块内浅层变量（最后定义覆盖）与 mixin 定义
fn new_scope(nodes : Array[LessNode], parent : Env?) -> Env {
  let vars : Map[String, Array[String]] = Map([])
  let mixins : Map[String, (Array[String], Array[LessNode])] = Map([])
  for node in nodes {
    match node {
      VarDef(name, val) =>
        // 同名后定义覆盖（LESS 最后定义优先）
        vars[name] = val
      MixinDef(name, params, body) => mixins[name] = (params, body)
      // 无括号的 `.name { }` 在 LESS 里同时是两样东西：一个普通类规则
      // （要输出），和一个可调用的无参 mixin（`.name;` / `.name();`）。
      // 之前只做了前者，于是调用会被 lookup_mixin 落空而静默丢弃。
      // 这里补上注册；发射路径不受影响，`.name { }` 本身照旧输出。
      RuleSet(sel, body) =>
        match single_class_name(sel) {
          Some(name) => mixins[name] = ([], body)
          None => ()
        }
      _ => ()
    }
  }
  { vars, mixins, parent, }
}

///|
/// 选择器若恰好是单个类名（`.name`，且 name 全是标识符字符），返回不带点的名字。
///
/// 只认这种形式：`.a .b`、`.a:hover`、`.a, .b` 都不是单个类名，不能当 mixin 注册。
fn single_class_name(sel : Array[String]) -> String? {
  match sel {
    [one] => {
      if one.length() < 2 || one[0] != '.' {
        return None
      }
      let mut i = 1
      while i < one.length() {
        if !is_ident_char(one[i]) {
          return None
        }
        i = i + 1
      }
      Some(one[1:].to_owned())
    }
    _ => None
  }
}

///|
/// 变量查找（最近作用域优先）
fn lookup_var(env : Env, name : String) -> Array[String]? {
  match env.vars.get(name) {
    Some(value) => Some(value)
    None =>
      match env.parent {
        None => None
        Some(p) => lookup_var(p, name)
      }
  }
}

///|
/// mixin 查找（最近作用域优先）
fn lookup_mixin(env : Env, name : String) -> (Array[String], Array[LessNode])? {
  match env.mixins.get(name) {
    Some(value) => Some(value)
    None =>
      match env.parent {
        None => None
        Some(p) => lookup_mixin(p, name)
      }
  }
}

///|
/// 生成一个块（parent 为当前选择器串，"" 表示顶层无选择器）
fn gen_block(
  nodes : Array[LessNode],
  parent : String,
  env : Env,
  read : ((String) -> String raise @core.CompileError)?,
  sb : StringBuilder,
) -> Bool raise @core.CompileError {
  let mut wrote = false
  for node in nodes {
    if gen_node(node, parent, env, read, sb) {
      sb.write_string("\n")
      wrote = true
    }
  }
  wrote
}

///|
/// 生成单个节点（当前选择器 parent）：RuleSet 提升为独立规则
fn gen_node(
  node : LessNode,
  parent : String,
  env : Env,
  read : ((String) -> String raise @core.CompileError)?,
  sb : StringBuilder,
) -> Bool raise @core.CompileError {
  match node {
    VarDef(_, _) | MixinDef(_, _, _) | MixinCall(_, _) => false
    Decl(prop, val) => {
      sb.write_string("  ")
      sb.write_string(prop)
      sb.write_string(": ")
      sb.write_string(eval_value(val, env))
      sb.write_string(";\n")
      true
    }
    RuleSet(sel, body) =>
      gen_rule(combine_selector(parent, sel), body, env, read, sb)
    AtRule(name, prelude, body) =>
      gen_at_rule(name, prelude, body, parent, env, read, sb)
    Import(path) => gen_import(path, parent, env, read, sb)
    Raw(text) => {
      sb.write_string(text)
      sb.write_string("\n")
      text.trim().length() > 0
    }
  }
}

///|
/// 生成一个规则块：本级声明放进块，子规则提升为独立选择器规则
fn gen_rule(
  full : String,
  body : Array[LessNode],
  env : Env,
  read : ((String) -> String raise @core.CompileError)?,
  sb : StringBuilder,
) -> Bool raise @core.CompileError {
  let child_env = new_scope(body, Some(env))
  let decls = gen_block_decls(body, child_env)
  if decls.length() > 0 {
    sb.write_string(full)
    sb.write_string(" {\n")
    for decl in decls {
      sb.write_string("  ")
      sb.write_string(decl.0)
      sb.write_string(": ")
      sb.write_string(decl.1)
      sb.write_string(";\n")
    }
    sb.write_string("}\n")
  }
  gen_block_lifted(body, full, child_env, read, sb) || decls.length() > 0
}

///|
/// 当前块的声明（含 mixin 混入）；同名同值去重，保留最后一次出现（对齐 less.js）
fn gen_block_decls(
  nodes : Array[LessNode],
  env : Env,
) -> Array[(String, String)] raise @core.CompileError {
  let out : Array[(String, String)] = []
  collect_decls(nodes, env, out)
  // 保留最后一次出现：从后往前收集，再逆序输出
  let seen : Map[String, Bool] = Map([])
  let rev : Array[(String, String)] = []
  let mut k = out.length() - 1
  while k >= 0 {
    let (p, v) = out[k]
    let key = p + "\u0000" + v
    if seen.get(key) is None {
      rev.push((p, v))
      seen[key] = true
    }
    k = k - 1
  }
  let result : Array[(String, String)] = []
  let mut m = rev.length() - 1
  while m >= 0 {
    result.push(rev[m])
    m = m - 1
  }
  result
}

///|
fn collect_decls(
  nodes : Array[LessNode],
  env : Env,
  out : Array[(String, String)],
) -> Unit raise @core.CompileError {
  for node in nodes {
    match node {
      Decl(prop, val) => out.push((prop, eval_value(val, env)))
      MixinCall(name, args) =>
        match lookup_mixin(env, name) {
          Some((params, body)) =>
            collect_decls(body, bind_params(env, params, args), out)
          None =>
            raise @core.CompileError::EngineFailed(
              engine="less",
              message=".\{name} is undefined",
            )
        }
      _ => ()
    }
  }
}

///|
/// 当前块的子规则/at-rule（提升为独立规则）
fn gen_block_lifted(
  nodes : Array[LessNode],
  full : String,
  env : Env,
  read : ((String) -> String raise @core.CompileError)?,
  sb : StringBuilder,
) -> Bool raise @core.CompileError {
  let mut wrote = false
  for node in nodes {
    match node {
      RuleSet(sel, body) =>
        if gen_rule(combine_selector(full, sel), body, env, read, sb) {
          wrote = true
        }
      MixinCall(name, args) =>
        match lookup_mixin(env, name) {
          Some((params, body)) => {
            let penv = bind_params(env, params, args)
            if gen_block_lifted(body, full, penv, read, sb) {
              wrote = true
            }
          }
          None =>
            raise @core.CompileError::EngineFailed(
              engine="less",
              message=".\{name} is undefined",
            )
        }
      AtRule(name, prelude, body) =>
        if gen_at_rule(name, prelude, body, full, env, read, sb) {
          wrote = true
        }
      Import(path) => if gen_import(path, full, env, read, sb) { wrote = true }
      _ => ()
    }
  }
  wrote
}

///|
/// @media 等 at-rule
fn gen_at_rule(
  name : String,
  prelude : Array[String],
  body : Array[LessNode],
  parent : String,
  env : Env,
  read : ((String) -> String raise @core.CompileError)?,
  sb : StringBuilder,
) -> Bool raise @core.CompileError {
  let pre = eval_value(prelude, env)
  let child_env = new_scope(body, Some(env))
  sb.write_string("@")
  sb.write_string(name)
  sb.write_string(" ")
  sb.write_string(pre)
  sb.write_string(" {\n")
  ignore(gen_block(body, parent, child_env, read, sb))
  sb.write_string("}\n")
  true
}

///|
/// @import 内联
fn gen_import(
  path : String,
  parent : String,
  env : Env,
  read : ((String) -> String raise @core.CompileError)?,
  sb : StringBuilder,
) -> Bool raise @core.CompileError {
  match read {
    None => false
    Some(f) => {
      let imported = f(path) catch { _ => "" }
      let nodes = parse_less(@scss.tokenize(imported))
      let child_env = new_scope(nodes, Some(env))
      gen_block(nodes, parent, child_env, read, sb)
    }
  }
}

///|
/// 组合父选择器与子选择器（token-aware：`&` 替换，`&:`/`&.` 等组合符不加空格）
fn combine_selector(parent : String, sel : Array[String]) -> String {
  let joined = join_selector_tokens(sel)
  if parent.length() == 0 {
    return joined
  }
  if joined.contains("&") {
    return joined.replace(old="&", new=parent)
  }
  parent + " " + joined
}

///|
/// 选择器 token 拼装。
///
/// 直接 `" "` 拼会把 `.a:hover` 变成 `.a : hover`、`.a, .b` 变成 `.a , .b`。
/// 规则：`:` 两侧都不留空格，`,` 前不留、后要留；其余（含 `>` `+` `~`
/// 这类组合器）保留空格。
fn join_selector_tokens(sel : Array[String]) -> String {
  let buf = StringBuilder()
  for i = 0; i < sel.length(); i = i + 1 {
    if i > 0 {
      let prev = sel[i - 1]
      let tok = sel[i]
      let tight = tok.has_prefix(":") ||
        tok.has_prefix(",") ||
        tok == "(" ||
        tok == ")" ||
        prev.has_suffix(":") ||
        prev.has_suffix("(")
      if !tight {
        buf.write_char(' ')
      }
    }
    buf.write_string(sel[i])
  }
  buf.to_string()
}

///|
/// 把实参绑定到形参（同名 @ 前缀），生成参数作用域
fn bind_params(env : Env, params : Array[String], args : Array[String]) -> Env {
  let vars : Map[String, Array[String]] = Map([])
  for i in 0..<params.length() {
    let p = params[i]
    let (pname, pdef) = split_param(p)
    if i < args.length() && args[i].length() > 0 {
      vars[pname] = split_args(args[i])
    } else if pdef.length() > 0 {
      vars[pname] = split_args(pdef)
    }
  }
  { vars, mixins: Map([]), parent: Some(env), }
}

///|
/// 拆分参数项：`@name` 或 `@name: default` → (name, default)
fn split_param(p : String) -> (String, String) {
  let idx = find_colon(p)
  if idx >= 0 {
    (
      strip_at(p[0:idx].to_owned()).trim().to_owned(),
      p[idx + 1:].to_owned().trim().to_owned(),
    )
  } else {
    (strip_at(p).trim().to_owned(), "")
  }
}

///|
fn find_colon(s : String) -> Int {
  let n = s.length()
  let mut i = 0
  while i < n {
    if s[i] == ':' {
      return i
    }
    i += 1
  }
  -1
}

///|
/// 把单个实参字符串切成值 token 序列
fn split_args(s : String) -> Array[String] {
  s
  .split(" ")
  .filter(fn(x) { x.length() > 0 })
  .map(fn(x) { x.to_owned() })
  .to_array()
}

///|
/// 求值一个值 token 序列：替换 @var + 合并数字运算
fn eval_value(
  toks : Array[String],
  env : Env,
) -> String raise @core.CompileError {
  // 单 token 普通值无需变量解析或运算折叠。
  if toks.length() == 1 {
    let t = toks[0]
    if t.length() == 0 || t[0] != '@' {
      return t
    }
  }
  // 用循环而不是 map：resolve_at 现在会 raise，匿名函数要跟着标 raise 类型，
  // 循环在函数体内直接调用更直接
  let resolved : Array[String] = []
  for t in toks {
    resolved.push(resolve_at(t, env))
  }
  merge_math(resolved)
}

///|
/// 把 `@name` token 替换为变量值
fn resolve_at(t : String, env : Env) -> String raise @core.CompileError {
  if t.length() > 0 && t[0] == '@' {
    let name = strip_at(t)
    match lookup_var(env, name) {
      None =>
        // 措辞对齐 less.js：variable @x is undefined
        raise @core.CompileError::EngineFailed(
          engine="less",
          message="variable " + t + " is undefined",
        )
      Some(val) => eval_value(val, env) // lazy：使用时递归求值
    }
  } else {
    t
  }
}

///|
/// 合并 `num op num` 为计算结果（仅数字运算，单位取左侧）
///
/// 其余 token 按 CSS 习惯拼接：函数名与 `(`、`,` `:` `)` 之间不插空格，
/// 否则 `rgba(0, 0, 0, .2)` 会变成 `rgba ( 0 , 0 , 0 , .2 )`——这是无效 CSS，
/// 浏览器会整条声明丢弃。
fn merge_math(toks : Array[String]) -> String {
  let folded = fold_math(toks)
  let mask = math_group_mask(folded)
  let sb = StringBuilder()
  for i, t in folded {
    let in_math = mask_at(mask, i) || mask_at(mask, i - 1)
    if i > 0 && value_needs_space(folded, i, in_math) {
      sb.write_string(" ")
    }
    sb.write_string(t)
  }
  sb.to_string()
}

///|
/// 折叠 `num op num`。数学函数组内（`calc()`/`min()`/`max()`/`clamp()`）
/// 一律不折叠：那是 CSS Calculation，`calc(100% - 10px)` 折成 `calc(90%)`
/// 会静默改语义
fn fold_math(toks : Array[String]) -> Array[String] {
  let mask = math_group_mask(toks)
  let out : Array[String] = []
  let mut i = 0
  while i < toks.length() {
    if !mask_at(mask, i) &&
      is_number(toks[i]) &&
      i + 2 < toks.length() &&
      is_operator(toks[i + 1]) &&
      is_number(toks[i + 2]) {
      out.push(num_arith(toks[i], toks[i + 1], toks[i + 2]))
      i += 3
    } else {
      out.push(toks[i])
      i += 1
    }
  }
  out
}

///|
/// 相邻两个值 token 之间是否需要空格（`i` 为当前 token 下标，i > 0）
///
/// 数学函数组内二元运算符两侧必须有空白，写成 `calc(100%-10px)` 浏览器会
/// 整条丢弃；一元符号（`-2px`）不空格。
fn value_needs_space(parts : Array[String], i : Int, in_math : Bool) -> Bool {
  let prev = parts[i - 1]
  let cur = parts[i]
  if in_math {
    if is_operator(cur) {
      return !is_unary_op_at(parts, i)
    }
    if is_operator(prev) {
      return !is_unary_op_at(parts, i - 1)
    }
  }
  if is_operator(cur) || cur == "(" || cur == ")" || cur == "," || cur == ":" {
    return false
  }
  if prev == "(" || is_operator(prev) {
    return false
  }
  true
}

///|
/// `parts[i]` 是否是一元运算符（前面是 `(` `,` 或另一个运算符）
fn is_unary_op_at(parts : Array[String], i : Int) -> Bool {
  if i <= 0 {
    return true
  }
  let p = parts[i - 1]
  p == "(" || p == "," || is_operator(p)
}

///|
/// 是否 CSS 数学函数：内部是 Calculation 语义，不能按普通值折叠
fn is_math_fn(s : String) -> Bool {
  s == "calc" ||
  s == "min" ||
  s == "max" ||
  s == "clamp" ||
  s.has_suffix("-calc")
}

///|
/// 标出每个 token 是否落在数学函数组内（无括号时返回空数组）
fn math_group_mask(parts : Array[String]) -> Array[Bool] {
  let mask : Array[Bool] = []
  let stack : Array[Bool] = []
  let mut has_paren = false
  for t in parts {
    if t == "(" {
      has_paren = true
      break
    }
  }
  if !has_paren {
    return mask
  }
  for i, t in parts {
    let in_group = stack_has_true(stack)
    if t == "(" {
      let is_math = i > 0 && is_math_fn(parts[i - 1])
      mask.push(in_group || is_math)
      stack.push(is_math)
    } else if t == ")" {
      mask.push(in_group)
      if stack.length() > 0 {
        ignore(stack.pop())
      }
    } else {
      mask.push(in_group)
    }
  }
  mask
}

///|
/// 栈上是否存在处于数学函数组内的层级
fn stack_has_true(stack : Array[Bool]) -> Bool {
  for b in stack {
    if b {
      return true
    }
  }
  false
}

///|
/// 越界的 mask 一律按 false（无括号时 mask 为空）
fn mask_at(mask : Array[Bool], i : Int) -> Bool {
  i >= 0 && i < mask.length() && mask[i]
}

///|
fn is_operator(t : String) -> Bool {
  t == "+" || t == "-" || t == "*" || t == "/"
}

///|
fn is_number(t : String) -> Bool {
  let n = t.length()
  if n == 0 {
    return false
  }
  let mut seen_digit = false
  for i in 0..<n {
    let c = t[i]
    if c == '.' {
      continue
    }
    if c >= '0' && c <= '9' {
      seen_digit = true
      continue
    }
    // 字母单位
    if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {
      continue
    }
    return false
  }
  seen_digit
}

///|
/// 数值运算：解析（数字, 单位）后计算，单位取左操作数
fn num_arith(a : String, op : String, b : String) -> String {
  let (anum, aunit) = parse_num(a)
  let (bnum, _) = parse_num(b)
  let res = match op {
    "+" => Some(anum + bnum)
    "-" => Some(anum - bnum)
    "*" => Some(anum * bnum)
    "/" => if bnum == 0.0 { None } else { Some(anum / bnum) }
    _ => None
  }
  match res {
    None => a + " " + op + " " + b
    Some(v) => fmt_num(v) + aunit
  }
}

///|
fn parse_num(t : String) -> (Double, String) {
  let sb = StringBuilder()
  let mut unit = ""
  for ch in t {
    if (ch >= '0' && ch <= '9') ||
      ch == '.' ||
      ch == '-' ||
      ch == '+' ||
      ch == 'e' ||
      ch == 'E' {
      sb.write_char(ch)
    } else {
      unit = unit + ch.to_string()
    }
  }
  let v = sb.to_string()
  let num = if v.length() > 0 { parse_double(v) } else { 0.0 }
  (num, unit)
}

///|
fn parse_double(s : String) -> Double {
  // 简单解析小数（无 e）
  let mut sign = 1.0
  let mut i = 0
  if i < s.length() && (s[i] == '-' || s[i] == '+') {
    if s[i] == '-' {
      sign = -1.0
    }
    i += 1
  }
  let mut int_part = 0.0
  while i < s.length() && s[i] >= '0' && s[i] <= '9' {
    int_part = int_part * 10.0 + to_digit(s[i])
    i += 1
  }
  let mut frac = 0.0
  let mut div = 1.0
  if i < s.length() && s[i] == '.' {
    i += 1
    while i < s.length() && s[i] >= '0' && s[i] <= '9' {
      frac = frac * 10.0 + to_digit(s[i])
      div *= 10.0
      i += 1
    }
  }
  sign * (int_part + frac / div)
}

///|
fn to_digit(c : UInt16) -> Double {
  (c.to_int() - 48).to_double()
}

///|
fn fmt_num(v : Double) -> String {
  // 整数不带小数点，非整数保留
  if v == v.floor() {
    v.floor().to_int().to_string()
  } else {
    let s = v.to_string()
    s
  }
}
