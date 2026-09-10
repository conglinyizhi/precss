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
) -> String {
  let env = new_scope(nodes, None)
  let sb = StringBuilder()
  ignore(gen_block(nodes, "", env, read, sb))
  sb.to_string()
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
      _ => ()
    }
  }
  { vars, mixins, parent, }
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
) -> Bool {
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
) -> Bool {
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
) -> Bool {
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
) -> Array[(String, String)] {
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
) -> Unit {
  for node in nodes {
    match node {
      Decl(prop, val) => out.push((prop, eval_value(val, env)))
      MixinCall(name, args) =>
        match lookup_mixin(env, name) {
          Some((params, body)) =>
            collect_decls(body, bind_params(env, params, args), out)
          None => ()
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
) -> Bool {
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
          None => ()
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
) -> Bool {
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
) -> Bool {
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
  if parent.length() == 0 {
    return sel.join(" ")
  }
  let s = sel.join(" ")
  if s.contains("&") {
    let mut r = s.replace(old="&", new=parent)
    r = r.replace(old=" :", new=":")
    r = r.replace(old=" ", new="")
    return r
  }
  parent + " " + s
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
fn eval_value(toks : Array[String], env : Env) -> String {
  // 单 token 普通值无需变量解析或运算折叠。
  if toks.length() == 1 {
    let t = toks[0]
    if t.length() == 0 || t[0] != '@' {
      return t
    }
  }
  let resolved : Array[String] = toks.map(fn(t) { resolve_at(t, env) })
  merge_math(resolved)
}

///|
/// 把 `@name` token 替换为变量值
fn resolve_at(t : String, env : Env) -> String {
  if t.length() > 0 && t[0] == '@' {
    let name = strip_at(t)
    match lookup_var(env, name) {
      None => t
      Some(val) => eval_value(val, env) // lazy：使用时递归求值
    }
  } else {
    t
  }
}

///|
/// 合并 `num op num` 为计算结果（仅数字运算，单位取左侧）
fn merge_math(toks : Array[String]) -> String {
  let sb = StringBuilder()
  let mut i = 0
  while i < toks.length() {
    let t = toks[i]
    if is_number(t) &&
      i + 2 < toks.length() &&
      is_operator(toks[i + 1]) &&
      is_number(toks[i + 2]) {
      let r = num_arith(t, toks[i + 1], toks[i + 2])
      sb.write_string(r)
      i += 3
    } else {
      sb.write_string(t)
      i += 1
    }
    if i < toks.length() {
      sb.write_string(" ")
    }
  }
  sb.to_string()
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
