///|
/// SCSS 求值：AST → CSS 字符串
///
/// 维护作用域链与 mixin 表，实现变量替换（含块级遮蔽）、规则嵌套、
/// mixin 调用、`@if/@for` 控制流、`!default`/`!global` 变量旗标与 `@media` 透传。
priv struct Mixin {
  params : Array[String]
  body : Array[Node]
}

///|
/// 作用域链：`scopes[0]` 为全局，越靠后越内层
priv struct Env {
  scopes : Array[Map[String, Array[String]]]
  mixins : Map[String, Mixin]
}

///|
/// 编译样式表为 CSS
pub fn to_css(nodes : Array[Node]) -> String {
  let env = Env::new()
  let sb = StringBuilder()
  gen(nodes, [], env, sb)
  sb.to_string()
}

///|
fn Env::new() -> Env {
  { scopes: [Map([])], mixins: Map([]), }
}

///|
fn Env::push_scope(self : Env) -> Unit {
  self.scopes.push(Map([]))
}

///|
fn Env::pop_scope(self : Env) -> Unit {
  if self.scopes.length() > 1 {
    ignore(self.scopes.pop())
  }
}

///|
/// 从内向外查找变量
fn Env::get_var(self : Env, name : String) -> Array[String]? {
  let mut i = self.scopes.length() - 1
  while i >= 0 {
    let found = self.scopes[i].get(name)
    if found is Some(_) {
      return found
    }
    i -= 1
  }
  None
}

///|
/// 写入变量到作用域（默认当前层，`is_global` 则全局层）
fn Env::set_var(
  self : Env,
  name : String,
  value : Array[String],
  is_global : Bool,
) -> Unit {
  if is_global {
    self.scopes[0][name] = value
  } else {
    self.scopes[self.scopes.length() - 1][name] = value
  }
}

///|
/// 定义变量（`is_default` 时仅在未定义时设置）
fn Env::define_var(
  self : Env,
  name : String,
  value : Array[String],
  is_default : Bool,
  is_global : Bool,
) -> Unit {
  if is_default && self.get_var(name) is Some(_) {
    return
  }
  self.set_var(name, value, is_global)
}

///|
/// 在作用域内运行 `f`
fn with_scope(env : Env, f : () -> Unit) -> Unit {
  Env::push_scope(env)
  f()
  Env::pop_scope(env)
}

///|
/// 生成一次 mixin 调用（绑定实参）
fn gen_mixin_call(
  name : String,
  args : Array[String],
  content : Array[Node],
  parent : Array[String],
  env : Env,
  sb : StringBuilder,
) -> Unit {
  match env.mixins.get(name) {
    Some(m) =>
      with_scope(env, () => {
        bind_params(m, args, env)
        gen(replace_content(m.body, content), parent, env, sb)
      })
    None => ()
  }
}

///|
/// 把实参按形参顺序绑定到当前作用域
fn bind_params(m : Mixin, args : Array[String], env : Env) -> Unit {
  let mut i = 0
  for pstr in m.params {
    if pstr.contains("...") {
      let v = pstr.replace(old="...", new="").trim().to_owned()
      let rest = args[i:].to_owned()
      Env::set_var(env, v, [rest.join(", ")], false)
    } else if pstr.contains(":") {
      let colon = str_find_colon(pstr)
      let name = pstr[0:colon].trim().to_owned()
      let default = pstr[colon + 1:].trim().to_owned()
      if i < args.length() {
        Env::set_var(env, name, [args[i]], false)
        i += 1
      } else {
        Env::set_var(env, name, [default], false)
      }
    } else {
      let name = pstr.trim().to_owned()
      if i < args.length() {
        Env::set_var(env, name, [args[i]], false)
        i += 1
      }
    }
  }
}

///|
/// 找第一个分号下标（找不到返回长度）
fn str_find_colon(s : String) -> Int {
  let mut i = 0
  while i < s.length() {
    if s[i] == ':' {
      return i
    }
    i += 1
  }
  s.length()
}

///|
/// 从值 token 里解析 `!default` / `!global`，返回 (清洗后的值, default, global)
fn parse_flags(value : Array[String]) -> (Array[String], Bool, Bool) {
  let cleaned : Array[String] = []
  let mut is_default = false
  let mut is_global = false
  for t in value {
    if t == "!default" {
      is_default = true
    } else if t == "!global" {
      is_global = true
    } else {
      cleaned.push(t)
    }
  }
  (cleaned, is_default, is_global)
}

///|
/// 处理一个变量定义节点
fn apply_vardef(env : Env, name : String, value : Array[String]) -> Unit {
  let (cleaned, is_default, is_global) = parse_flags(value)
  let resolved = resolve(cleaned, env)
  Env::define_var(env, name, [resolved], is_default, is_global)
}

///|
/// 生成：按顶层节点顺序输出
fn gen(
  nodes : Array[Node],
  parent : Array[String],
  env : Env,
  sb : StringBuilder,
) -> Unit {
  for n in nodes {
    match n {
      RuleSet(sel, body) => gen_ruleset(sel, body, parent, env, sb)
      AtRule(name, prelude, body) => emit_atrule(name, prelude, body, env, sb)
      If(cond, tb, eb) => {
        let chosen = choose_branch(cond, tb, eb, env)
        gen(chosen, parent, env, sb)
      }
      For(v, from, to, body) =>
        gen(expand_for(v, from, to, body, env), parent, env, sb)
      Each(vars, list, body) =>
        gen(expand_each(vars, list, body, env), parent, env, sb)
      While(cond, body) => gen_while(cond, body, parent, env, sb)
      MixinCall(name, args, content) =>
        gen_mixin_call(name, args, content, parent, env, sb)
      Content => ()
      VarDef(name, value) => apply_vardef(env, name, value)
      MixinDef(name, params, body) => env.mixins[name] = { params, body, }
      Decl(name, value) =>
        sb.write_string("  \{name}: \{resolve(value, env)};\n")
      Import(_) => ()
      Raw(s) => {
        sb.write_string(s)
        sb.write_string("\n")
      }
    }
  }
}

///|
/// 生成一条规则集（合并其声明，再递归嵌套）
fn gen_ruleset(
  sel : Array[String],
  body : Array[Node],
  parent : Array[String],
  env : Env,
  sb : StringBuilder,
) -> Unit {
  let full = combine(parent, sel)
  let decl_lines : Array[String] = []
  let struct_nodes : Array[Node] = []
  Env::push_scope(env)
  split_body(body, full, env, decl_lines, struct_nodes)
  if decl_lines.length() > 0 {
    sb.write_string("\{join_resolved(full, env)} {\n")
    for line in decl_lines {
      sb.write_string("  \{line}\n")
    }
    sb.write_string("}\n")
  }
  for s in struct_nodes {
    gen_struct(s, full, env, sb)
  }
  Env::pop_scope(env)
}

///|
/// 生成单个结构节点（嵌套规则 / at-rule / 控制流 / include）
fn gen_struct(
  node : Node,
  parent : Array[String],
  env : Env,
  sb : StringBuilder,
) -> Unit {
  match node {
    RuleSet(sel, body) => gen_ruleset(sel, body, parent, env, sb)
    AtRule(name, prelude, body) => emit_atrule(name, prelude, body, env, sb)
    If(cond, tb, eb) => {
      let chosen = choose_branch(cond, tb, eb, env)
      with_scope(env, () => gen(chosen, parent, env, sb))
    }
    For(v, from, to, body) =>
      with_scope(env, () => {
        gen(expand_for(v, from, to, body, env), parent, env, sb)
      })
    Each(vars, list, body) =>
      with_scope(env, () => {
        gen(expand_each(vars, list, body, env), parent, env, sb)
      })
    While(cond, body) => gen_while(cond, body, parent, env, sb)
    MixinCall(name, args, content) =>
      gen_mixin_call(name, args, content, parent, env, sb)
    Content => ()
    VarDef(name, value) => apply_vardef(env, name, value)
    MixinDef(name, params, body) => env.mixins[name] = { params, body, }
    Decl(name, value) => sb.write_string("  \{name}: \{resolve(value, env)};\n")
    Import(_) => ()
    Raw(s) => {
      sb.write_string(s)
      sb.write_string("\n")
    }
  }
}

///|
/// 输出一条 at-rule（如 @media）
fn emit_atrule(
  name : String,
  prelude : Array[String],
  body : Array[Node],
  env : Env,
  sb : StringBuilder,
) -> Unit {
  let at_name = if name.has_prefix("@") { name } else { "@" + name }
  sb.write_string("\{at_name} \{join_value(prelude, env)} {\n")
  with_scope(env, () => gen(body, [], env, sb))
  sb.write_string("}\n")
}

///|
/// 把一个规则集内的节点拆成「声明行」和「结构节点」
fn split_body(
  body : Array[Node],
  _full : Array[String],
  env : Env,
  decl_lines : Array[String],
  struct_nodes : Array[Node],
) -> Unit {
  for n in body {
    match n {
      Decl(name, value) => decl_lines.push("\{name}: \{resolve(value, env)};")
      VarDef(name, value) => apply_vardef(env, name, value)
      MixinDef(name, params, body2) =>
        env.mixins[name] = { params, body: body2, }
      MixinCall(name, args, content) =>
        match env.mixins.get(name) {
          Some(m) =>
            with_scope(env, () => {
              bind_params(m, args, env)
              split_body(
                replace_content(m.body, content),
                _full,
                env,
                decl_lines,
                struct_nodes,
              )
            })
          None => ()
        }
      If(cond, tb, eb) => {
        let chosen = choose_branch(cond, tb, eb, env)
        with_scope(env, () => {
          split_body(chosen, _full, env, decl_lines, struct_nodes)
        })
      }
      For(v, from, to, body2) => {
        let expanded = expand_for(v, from, to, body2, env)
        with_scope(env, () => {
          split_body(expanded, _full, env, decl_lines, struct_nodes)
        })
      }
      Each(vars, list, body2) => {
        let expanded = expand_each(vars, list, body2, env)
        with_scope(env, () => {
          split_body(expanded, _full, env, decl_lines, struct_nodes)
        })
      }
      While(cond, body2) => {
        let mut iter = 0
        while eval_truthy(cond, env) && iter < 1000 {
          iter += 1
          split_body(body2, _full, env, decl_lines, struct_nodes)
        }
      }
      other => struct_nodes.push(other)
    }
  }
}

///|
/// 选择 @if/@else 分支
fn choose_branch(
  cond : Array[String],
  tb : Array[Node],
  eb : Array[Node],
  env : Env,
) -> Array[Node] {
  if eval_truthy(cond, env) {
    tb
  } else {
    eb
  }
}

///|
/// 展开 @for 循环：把 `$v` 替换为每个循环值，重复 body
fn expand_for(
  v : String,
  from : Array[String],
  to : Array[String],
  body : Array[Node],
  env : Env,
) -> Array[Node] {
  let a = to_int(resolve(from, env))
  let b = to_int(resolve(to, env))
  let out : Array[Node] = []
  let mut i = a
  let uses_var = nodes_contain_var(body, v)
  while i < b {
    let sub = if uses_var {
      substitute_var(body, v, i.to_string())
    } else {
      body
    }
    for s in sub {
      out.push(s)
    }
    i += 1
  }
  out
}

///|
/// 展开 @each：把列表按 `,` 拆成多个值，对每个值替换 `$v` 并重复 body
fn expand_each(
  vars : Array[String],
  list : Array[String],
  body : Array[Node],
  env : Env,
) -> Array[Node] {
  let out : Array[Node] = []
  let list_src = deref_each_list(list, env)
  if vars.length() == 1 {
    let uses_var = nodes_contain_var(body, vars[0])
    for group in split_on_commas(list_src) {
      let val = resolve(group, env)
      let sub = if uses_var { substitute_var(body, vars[0], val) } else { body }
      for s in sub {
        out.push(s)
      }
    }
  } else {
    for group in split_on_commas(list_src) {
      let mut b = body
      let mut k = 0
      while k < vars.length() && k < group.length() {
        let val = resolve([group[k]], env)
        if nodes_contain_var(b, vars[k]) {
          b = substitute_var(b, vars[k], val)
        }
        k += 1
      }
      for s in b {
        out.push(s)
      }
    }
  }
  out
}

///| 若 @each 的 list 是单个 `$var` 引用，解引用成其值 token 数组（含逗号），

///|
/// 否则原样。这样 `@each $k, $v in $spacing` 能遍历变量里的逗号分隔项。
fn deref_each_list(list : Array[String], env : Env) -> Array[String] {
  if list.length() == 1 && list[0].length() > 0 && list[0][0] == '$' {
    match Env::get_var(env, list[0]) {
      // 变量存的是 resolve 后的单字符串（可能含逗号分隔的 list），
      // 拆回逗号/空格分隔的 token 数组，供 split_on_commas 解构。
      Some(v) => if v.length() == 1 { spread_list_string(v[0]) } else { v }
      None => list
    }
  } else {
    list
  }
}

///|
/// 把 "0 0, 1 0.25rem" 这类字符串拆成 [0, 0, ",", 1, 0.25rem] token
fn spread_list_string(s : String) -> Array[String] {
  let out : Array[String] = []
  let mut cur = StringBuilder()
  for ch in s {
    if ch == ' ' || ch == '\t' {
      let item = cur.to_string()
      if item.length() > 0 {
        out.push(item)
        cur = StringBuilder()
      }
    } else if ch == ',' {
      let item = cur.to_string()
      if item.length() > 0 {
        out.push(item)
        cur = StringBuilder()
      }
      out.push(",")
    } else {
      cur.write_char(ch)
    }
  }
  let item = cur.to_string()
  if item.length() > 0 {
    out.push(item)
  }
  out
}

///| 按逗号拆分 token 数组

///|
/// 生成 @while 循环
fn gen_while(
  cond : Array[String],
  body : Array[Node],
  parent : Array[String],
  env : Env,
  sb : StringBuilder,
) -> Unit {
  let mut iter = 0
  while eval_truthy(cond, env) && iter < 1000 {
    iter += 1
    gen(body, parent, env, sb)
  }
}

///|
/// 把选择器数组里的插值 `#{$var}` 求值后 join
fn join_resolved(selectors : Array[String], env : Env) -> String {
  // 常规选择器没有插值时直接复用数组 join，跳过逐项扫描和临时数组。
  let mut has_interp = false
  for s in selectors {
    if s.contains("#{") {
      has_interp = true
      break
    }
  }
  if !has_interp {
    return selectors.join(", ")
  }
  let parts : Array[String] = []
  for s in selectors {
    parts.push(resolve_sel_interp(s, env))
  }
  parts.join(", ")
}

///|
/// 对选择器字符串里的 `#{$var}` 插值求值
fn resolve_sel_interp(s : String, env : Env) -> String {
  if !s.contains("#{") {
    return s
  }
  let mut out = s
  let mut changed = true
  while changed {
    changed = false
    let n = out.length()
    let mut start = -1
    let mut i = 0
    while i + 1 < n {
      if out[i] == '#' && out[i + 1] == '{' {
        start = i
        break
      }
      i += 1
    }
    if start < 0 {
      break
    }
    let mut j = start + 2
    while j < n && out[j] != '}' {
      j += 1
    }
    if j >= n {
      break
    }
    let inner = out[start + 2:j].to_owned()
    if inner.length() > 0 && inner[0] == '$' {
      match Env::get_var(env, inner) {
        Some(v) => {
          let val = resolve(v, env)
          out = out.replace(old="#{" + inner + "}", new=val)
          changed = true
        }
        None => break
      }
    } else {
      break
    }
  }
  out
}

///|
fn replace_content(body : Array[Node], content : Array[Node]) -> Array[Node] {
  let out : Array[Node] = []
  for n in body {
    match n {
      Content =>
        for cn in content {
          out.push(cn)
        }
      other => out.push(replace_into(other, content))
    }
  }
  out
}

///|
/// 递归深入嵌套块替换 @content
fn replace_into(n : Node, content : Array[Node]) -> Node {
  match n {
    RuleSet(sel, body) => RuleSet(sel, replace_content(body, content))
    If(cond, tb, eb) =>
      If(cond, replace_content(tb, content), replace_content(eb, content))
    For(v, f, t, b) => For(v, f, t, replace_content(b, content))
    Each(v, l, b) => Each(v, l, replace_content(b, content))
    While(cond, b) => While(cond, replace_content(b, content))
    AtRule(name, prelude, b) =>
      AtRule(name, prelude, replace_content(b, content))
    MixinCall(nm, ar, cb) => MixinCall(nm, ar, replace_content(cb, content))
    other => other
  }
}

///|
fn split_on_commas(toks : Array[String]) -> Array[Array[String]] {
  let groups : Array[Array[String]] = []
  let mut cur : Array[String] = []
  for t in toks {
    if t == "," {
      groups.push(cur)
      let fresh : Array[String] = []
      cur = fresh
    } else {
      cur.push(t)
    }
  }
  groups.push(cur)
  groups
}

///|
fn nodes_contain_var(nodes : Array[Node], v : String) -> Bool {
  for n in nodes {
    if node_contains_var(n, v) {
      return true
    }
  }
  false
}

///|
fn node_contains_var(n : Node, v : String) -> Bool {
  match n {
    Decl(_, value) => toks_contain_var(value, v)
    RuleSet(sel, body) => toks_contain_var(sel, v) || nodes_contain_var(body, v)
    If(cond, tb, eb) =>
      toks_contain_var(cond, v) ||
      nodes_contain_var(tb, v) ||
      nodes_contain_var(eb, v)
    MixinCall(_, args, content) =>
      toks_contain_var(args, v) || nodes_contain_var(content, v)
    For(_, from, to, body) =>
      toks_contain_var(from, v) ||
      toks_contain_var(to, v) ||
      nodes_contain_var(body, v)
    Each(vars, list, body) =>
      toks_contain_var(vars, v) ||
      toks_contain_var(list, v) ||
      nodes_contain_var(body, v)
    While(cond, body) => toks_contain_var(cond, v) || nodes_contain_var(body, v)
    AtRule(_, prelude, body) =>
      toks_contain_var(prelude, v) || nodes_contain_var(body, v)
    _ => false
  }
}

///|
fn toks_contain_var(toks : Array[String], v : String) -> Bool {
  let interp = "#{" + v + "}"
  for t in toks {
    if t == v || t == interp || t.contains(interp) || t.contains(v) {
      return true
    }
  }
  false
}

///|
fn substitute_var(nodes : Array[Node], v : String, val : String) -> Array[Node] {
  let out : Array[Node] = []
  for n in nodes {
    out.push(subst_node(n, v, val))
  }
  out
}

///|
fn subst_node(n : Node, v : String, val : String) -> Node {
  match n {
    Decl(name, value) => Decl(name, subst_toks(value, v, val))
    RuleSet(sel, body) =>
      RuleSet(subst_toks(sel, v, val), substitute_var(body, v, val))
    If(cond, tb, eb) =>
      If(
        subst_toks(cond, v, val),
        substitute_var(tb, v, val),
        substitute_var(eb, v, val),
      )
    MixinCall(name, args, content) =>
      MixinCall(name, subst_toks(args, v, val), substitute_var(content, v, val))
    For(v2, from, to, body) =>
      For(
        v2,
        subst_toks(from, v, val),
        subst_toks(to, v, val),
        substitute_var(body, v, val),
      )
    Each(v2, list, body) =>
      Each(
        subst_toks(v2, v, val),
        subst_toks(list, v, val),
        substitute_var(body, v, val),
      )
    While(cond, body) =>
      While(subst_toks(cond, v, val), substitute_var(body, v, val))
    AtRule(name, prelude, body) =>
      AtRule(name, subst_toks(prelude, v, val), substitute_var(body, v, val))
    other => other
  }
}

///|
fn subst_toks(toks : Array[String], v : String, val : String) -> Array[String] {
  let out : Array[String] = []
  let interp = "#{" + v + "}"
  for t in toks {
    if t == v || t == interp {
      out.push(val)
    } else if t.contains(interp) || t.contains(v) {
      let s = t.replace(old=interp, new=val)
      out.push(s.replace(old=v, new=val))
    } else {
      out.push(t)
    }
  }
  out
}

///|
/// 计算条件真假：非空、非 false
fn eval_truthy(cond : Array[String], env : Env) -> Bool {
  v_bool(e_expr(cond, env))
}

///|
/// 把字符串解析为整数（去掉单位）
fn to_int(s : String) -> Int {
  let mut t = s.trim()
  if t.has_suffix("px") {
    t = t[0:t.length() - 2].to_owned()
  }
  let mut result = 0
  let mut neg = false
  let mut i = 0
  if t.length() > 0 && t[0] == '-' {
    neg = true
    i = 1
  }
  while i < t.length() {
    let c = t[i]
    if c >= '0' && c <= '9' {
      result = result * 10 + (c - '0').to_int()
      i += 1
    } else {
      break
    }
  }
  if neg {
    -result
  } else {
    result
  }
}

///|
/// 变量替换 + 值拼接
fn resolve(toks : Array[String], env : Env) -> String {
  // 单 token 的普通值无需经过 StringBuilder，直接复用原 token。
  if toks.length() == 1 {
    let t = toks[0]
    if !t.contains("$") && !t.contains("#{") && !is_op(t) && !is_paren(t) {
      return t
    }
  }
  // 普通 CSS 值不需要变量、插值或表达式处理，跳过中间数组与算术折叠。
  if can_fast_resolve(toks) {
    return join_value_tokens(toks)
  }
  let parts : Array[String] = []
  for t in toks {
    if t.length() > 0 && t[0] == '$' {
      match Env::get_var(env, t) {
        Some(v) => parts.push(resolve(v, env))
        None => parts.push(t)
      }
    } else if t.length() > 2 && t.has_prefix("#{") && t.has_suffix("}") {
      let inner = t[2:t.length() - 1].to_owned()
      if inner.length() > 0 && inner[0] == '$' {
        match Env::get_var(env, inner) {
          Some(v) => parts.push(resolve(v, env))
          None => parts.push(t)
        }
      } else {
        parts.push(t)
      }
    } else {
      parts.push(t)
    }
  }
  join_value_tokens(fold_arith(strip_parens(parts)))
}

///|
fn can_fast_resolve(toks : Array[String]) -> Bool {
  for t in toks {
    if t.contains("$") || t.contains("#{") || is_op(t) || is_paren(t) {
      return false
    }
  }
  true
}

///|
/// 判断是否为运算符 token
fn is_op(t : String) -> Bool {
  t == "+" || t == "-" || t == "*" || t == "/" || t == "%"
}

///|
/// 吸收裸分组括号（非函数调用）：(x) -> x
fn strip_parens(parts : Array[String]) -> Array[String] {
  let out : Array[String] = []
  let mut i = 0
  while i < parts.length() {
    let t = parts[i]
    if t == "(" &&
      i + 2 < parts.length() &&
      parts[i + 2] == ")" &&
      !is_func_call(parts, i) {
      out.push(parts[i + 1])
      i += 3
    } else {
      out.push(t)
      i += 1
    }
  }
  out
}

///|
/// 判断括号前的 token 是否为函数调用（如 calc( / rgb( ）
fn is_func_call(parts : Array[String], i : Int) -> Bool {
  i > 0 && is_ident_ish(parts[i - 1])
}

///|
/// 粗略判断 token 是否为函数名
fn is_ident_ish(s : String) -> Bool {
  s.length() > 0 &&
  ((s[0] >= 'A' && s[0] <= 'Z') || (s[0] >= 'a' && s[0] <= 'z') || s[0] == '$')
}

///|
/// 值 token 序列化：运算符及其相邻 token 紧密拼接
fn join_value_tokens(parts : Array[String]) -> String {
  let sb = StringBuilder()
  let mut prev_is_op = false
  for i, t in parts {
    if t == "+" {
      // 字符串连接：去除 +，且让前后 token 紧密（c + d -> cd）
      prev_is_op = true
      continue
    }
    let joined = is_op(t) || is_paren(t)
    if i == 0 {
      prev_is_op = joined
    } else {
      if !joined && !prev_is_op {
        sb.write_string(" ")
      }
      prev_is_op = joined
    }
    sb.write_string(t)
  }
  sb.to_string()
}

///|
/// 是否为括号 token
fn is_paren(t : String) -> Bool {
  t == "(" || t == ")"
}

///|
fn join_value(toks : Array[String], env : Env) -> String {
  resolve(toks, env)
}

///|
fn combine(parent : Array[String], sel : Array[String]) -> Array[String] {
  if parent.length() == 0 {
    return sel
  }
  let out : Array[String] = []
  for ps in parent {
    for s in sel {
      out.push(join_nested(ps, s))
    }
  }
  out
}

///|
fn join_nested(parent : String, sel : String) -> String {
  if sel.contains("&") {
    sel.replace(old="&", new=parent)
  } else {
    parent + " " + sel
  }
}

///|
/// 对值 token 做简单的数字加减折叠（`8px + 4px` -> `12px`）
fn fold_arith(parts : Array[String]) -> Array[String] {
  let out : Array[String] = []
  let mut i = 0
  while i < parts.length() {
    if i + 2 < parts.length() &&
      is_num_str(parts[i]) &&
      (parts[i + 1] == "+" || parts[i + 1] == "-" || parts[i + 1] == "*") &&
      is_num_str(parts[i + 2]) {
      out.push(calc_num(parts[i], parts[i + 1], parts[i + 2]))
      i += 3
    } else {
      out.push(parts[i])
      i += 1
    }
  }
  out
}

///|
fn is_num_str(s : String) -> Bool {
  let t = s.trim()
  if t.length() == 0 {
    return false
  }
  let mut j = t.length()
  while j > 0 && is_unit_char(t[j - 1]) {
    j -= 1
  }
  if j <= 0 {
    return false
  }
  let mut k = 0
  while k < j {
    let c = t[k]
    if !(c >= '0' && c <= '9') {
      return false
    }
    k += 1
  }
  true
}

///|
fn calc_num(a : String, op : String, b : String) -> String {
  let (na, ua) = split_num(a)
  let (nb, _ub) = split_num(b)
  let r = if op == "+" {
    na + nb
  } else if op == "-" {
    na - nb
  } else {
    na * nb
  }
  r.to_string() + ua
}

///|
fn split_num(s : String) -> (Int, String) {
  let t = s.trim()
  let mut j = t.length()
  while j > 0 && is_unit_char(t[j - 1]) {
    j -= 1
  }
  let numpart = if j > 0 { t[0:j].to_owned() } else { t.to_owned() }
  let unit = if j < t.length() { t[j:].to_owned() } else { "" }
  (to_int(numpart), unit)
}

///|
fn is_unit_char(u : UInt16) -> Bool {
  (u >= 'A' && u <= 'Z') || (u >= 'a' && u <= 'z') || u == '%'
}

///|

///|
/// 条件/运算表达式求值（用于 @if/@else if/@while 条件）
///
/// 递归下降解析：or/and/not、比较（== != < > <= >=）、
/// 算术（+ - * / %）、括号、变量、数字、布尔、字符串。
/// 返回 `(值, 消费到下一 token 的下标)`。
priv enum CondVal {
  NumV(Int)
  BoolV(Bool)
  StrV(String)
  NilV
}

///|
/// 求值整个表达式（条件用），返回 CondVal
fn e_expr(toks : Array[String], env : Env) -> CondVal {
  let (v, _) = e_or(toks, 0, env)
  v
}

///|
fn e_or(toks : Array[String], pos : Int, env : Env) -> (CondVal, Int) {
  let (c0, i0) = e_and(toks, pos, env)
  let mut cur = c0
  let mut i = i0
  while i < toks.length() && toks[i] == "or" {
    let (rhs, np) = e_and(toks, i + 1, env)
    cur = v_or(cur, rhs)
    i = np
  }
  (cur, i)
}

///|
fn e_and(toks : Array[String], pos : Int, env : Env) -> (CondVal, Int) {
  let (c0, i0) = e_cmp(toks, pos, env)
  let mut cur = c0
  let mut i = i0
  while i < toks.length() && toks[i] == "and" {
    let (rhs, np) = e_cmp(toks, i + 1, env)
    cur = v_and(cur, rhs)
    i = np
  }
  (cur, i)
}

///|
fn e_cmp(toks : Array[String], pos : Int, env : Env) -> (CondVal, Int) {
  let (l0, i0) = e_add(toks, pos, env)
  let mut lhs = l0
  let mut i = i0
  while i < toks.length() && is_cmp(toks[i]) {
    let op = toks[i]
    let (rhs, np) = e_add(toks, i + 1, env)
    lhs = v_cmp(op, lhs, rhs)
    i = np
  }
  (lhs, i)
}

///|
fn e_add(toks : Array[String], pos : Int, env : Env) -> (CondVal, Int) {
  let (c0, i0) = e_mul(toks, pos, env)
  let mut cur = c0
  let mut i = i0
  while i < toks.length() && (toks[i] == "+" || toks[i] == "-") {
    let op = toks[i]
    let (rhs, np) = e_mul(toks, i + 1, env)
    cur = v_arith(op, cur, rhs)
    i = np
  }
  (cur, i)
}

///|
fn e_mul(toks : Array[String], pos : Int, env : Env) -> (CondVal, Int) {
  let (c0, i0) = e_unary(toks, pos, env)
  let mut cur = c0
  let mut i = i0
  while i < toks.length() &&
        (toks[i] == "*" || toks[i] == "/" || toks[i] == "%") {
    let op = toks[i]
    let (rhs, np) = e_unary(toks, i + 1, env)
    cur = v_arith(op, cur, rhs)
    i = np
  }
  (cur, i)
}

///|
/// 一元：not / 负号 / primary
fn e_unary(toks : Array[String], pos : Int, env : Env) -> (CondVal, Int) {
  if pos < toks.length() && toks[pos] == "not" {
    let (v, i) = e_unary(toks, pos + 1, env)
    return (v_not(v), i)
  }
  if pos < toks.length() && (toks[pos] == "-" || toks[pos] == "+") {
    let (v, i) = e_unary(toks, pos + 1, env)
    let neg = toks[pos] == "-"
    return (v_neg(v, neg), i)
  }
  e_primary(toks, pos, env)
}

///|
/// primary：数字 / 变量 / 布尔 / 字符串 / 括号
fn e_primary(toks : Array[String], pos : Int, env : Env) -> (CondVal, Int) {
  if pos >= toks.length() {
    return (StrV(""), pos)
  }
  let t = toks[pos]
  if t == "(" {
    let (v, i) = e_expr_at(toks, pos + 1, env)
    // 跳过配对的 `)`
    let mut j = i
    if j < toks.length() && toks[j] == ")" {
      j += 1
    }
    return (v, j)
  }
  if t == "true" {
    return (BoolV(true), pos + 1)
  }
  if t == "false" {
    return (BoolV(false), pos + 1)
  }
  // 变量：解析值递归求值
  if t.length() > 0 && t[0] == '$' {
    match Env::get_var(env, t) {
      Some(v) => {
        let inner = resolve(v, env)
        return e_expr_at(tokenize_str(inner), 0, env)
      }
      None => return (NilV, pos + 1)
    }
  }
  // 数字：去掉单位取整
  if is_num_literal(t) {
    return (NumV(to_int(t)), pos + 1)
  }
  // 字符串（含引号）
  (StrV(tri_quotes(t)), pos + 1)
}

///|
/// 在给定位置求值表达式（跳过已匹配的括号起始）
fn e_expr_at(toks : Array[String], pos : Int, env : Env) -> (CondVal, Int) {
  e_or(toks, pos, env)
}

///|
/// 字符串内容去引号
fn tri_quotes(s : String) -> String {
  let t = s.trim().to_owned()
  if t.length() >= 2 &&
    (
      (t[0] == '"' && t[t.length() - 1] == '"') ||
      (t[0] == '\'' && t[t.length() - 1] == '\'')
    ) {
    t[1:t.length() - 1].to_owned()
  } else {
    t
  }
}

///|
/// 是否为数字字面量
fn is_num_literal(s : String) -> Bool {
  let t = s.trim()
  if t.length() == 0 {
    return false
  }
  let mut i = 0
  if t[0] == '-' || t[0] == '+' {
    i = 1
  }
  if i >= t.length() {
    return false
  }
  while i < t.length() {
    let c = t[i]
    if !((c >= '0' && c <= '9') || c == '.') {
      break
    }
    i += 1
  }
  i > 0
}

// ---- 值运算 ----

///|
fn v_or(a : CondVal, b : CondVal) -> CondVal {
  if v_bool(a) {
    BoolV(true)
  } else {
    BoolV(v_bool(b))
  }
}

///|
fn v_and(a : CondVal, b : CondVal) -> CondVal {
  if !v_bool(a) {
    BoolV(false)
  } else {
    BoolV(v_bool(b))
  }
}

///|
fn v_not(a : CondVal) -> CondVal {
  BoolV(if v_bool(a) { false } else { true })
}

///|
fn v_neg(a : CondVal, neg : Bool) -> CondVal {
  match a {
    NumV(n) => NumV(if neg { -n } else { n })
    other => other
  }
}

///|
fn v_cmp(op : String, a : CondVal, b : CondVal) -> CondVal {
  match (a, b) {
    (NumV(x), NumV(y)) => {
      let r = if op == "==" {
        x == y
      } else if op == "!=" {
        x != y
      } else if op == "<" {
        x < y
      } else if op == ">" {
        x > y
      } else if op == "<=" {
        x <= y
      } else {
        x >= y
      }
      BoolV(r)
    }
    (BoolV(x), BoolV(y)) =>
      BoolV(
        if op == "==" {
          x == y
        } else if op == "!=" {
          x != y
        } else {
          false
        },
      )
    _ => BoolV(false)
  }
}

///|
fn v_arith(op : String, a : CondVal, b : CondVal) -> CondVal {
  match (a, b) {
    (NumV(x), NumV(y)) => {
      let r = if op == "+" {
        x + y
      } else if op == "-" {
        x - y
      } else if op == "*" {
        x * y
      } else if op == "/" {
        if y == 0 {
          0
        } else {
          x / y
        }
        // %
      } else if y == 0 {
        0
      } else {
        x % y
      }
      NumV(r)
    }
    _ => BoolV(false)
  }
}

///|
/// 取布尔真值判断
fn v_bool(v : CondVal) -> Bool {
  match v {
    BoolV(b) => b
    NumV(n) => n != 0
    StrV(s) => s.length() > 0
    NilV => false
  }
}

///|
fn is_cmp(t : String) -> Bool {
  t == "==" || t == "!=" || t == "<" || t == ">" || t == "<=" || t == ">="
}

///|
/// 把字符串切成 token（用于变量值再求值）
fn tokenize_str(s : String) -> Array[String] {
  tokenize(s)
}

///|

///| @import 内联与多文件编译入口
///
/// `@import "path"` 节点在编译前用注入的 reader 递归展开，文件内容被
/// 解析后内联到当前位置（含嵌套规则/控制流内的 @import）。读取函数由
/// 调用方注入，核心不耦合具体 IO。

///|
/// 编译一段可能包含 `@import` 的源码
pub fn compile_with_imports(
  source : String,
  read : (String) -> String raise @core.CompileError,
) -> String raise @core.CompileError {
  let nodes = parse_sheet(tokenize(source))
  let resolved = walk_imports(nodes, read, [])
  to_css(resolved)
}

///|
/// 递归展开 import 节点（顶层）
fn walk_imports(
  nodes : Array[Node],
  read : (String) -> String raise @core.CompileError,
  visited : Array[String],
) -> Array[Node] raise @core.CompileError {
  let out : Array[Node] = []
  for n in nodes {
    match n {
      Import(path) =>
        if !contains_str(visited, path) {
          let content = read(path)
          let inner = parse_sheet(tokenize(content))
          let v : Array[String] = []
          for x in visited {
            v.push(x)
          }
          v.push(path)
          let resolved = walk_imports(inner, read, v)
          for r in resolved {
            out.push(r)
          }
        }
      other => out.push(walk_into(other, read, visited))
    }
  }
  out
}

///|
/// 递归深入嵌套块，处理其中的 @import
fn walk_into(
  n : Node,
  read : (String) -> String raise @core.CompileError,
  visited : Array[String],
) -> Node raise @core.CompileError {
  match n {
    RuleSet(sel, body) => RuleSet(sel, walk_imports(body, read, visited))
    If(cond, tb, eb) =>
      If(cond, walk_imports(tb, read, visited), walk_imports(eb, read, visited))
    For(v, f, t, b) => For(v, f, t, walk_imports(b, read, visited))
    Each(v, l, b) => Each(v, l, walk_imports(b, read, visited))
    While(cond, b) => While(cond, walk_imports(b, read, visited))
    AtRule(name, prelude, b) =>
      AtRule(name, prelude, walk_imports(b, read, visited))
    MixinCall(nm, ar, cb) => MixinCall(nm, ar, walk_imports(cb, read, visited))
    other => other
  }
}

///|
/// 数组中是否含某字符串
fn contains_str(arr : Array[String], s : String) -> Bool {
  for x in arr {
    if x == s {
      return true
    }
  }
  false
}
