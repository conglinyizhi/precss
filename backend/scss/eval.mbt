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
pub fn to_css(nodes : Array[Node]) -> String raise @core.CompileError {
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
fn with_scope(
  env : Env,
  f : () -> Unit raise @core.CompileError,
) -> Unit raise @core.CompileError {
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
) -> Unit raise @core.CompileError {
  match env.mixins.get(name) {
    Some(m) =>
      with_scope(env, () => {
        bind_params(m, args, env)
        gen(replace_content(m.body, content), parent, env, sb)
      })
    None =>
      raise @core.CompileError::EngineFailed(
        engine="scss",
        message="Undefined mixin.",
      )
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
fn apply_vardef(
  env : Env,
  name : String,
  value : Array[String],
) -> Unit raise @core.CompileError {
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
) -> Unit raise @core.CompileError {
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
        sb.write_string(
          "  \{interp_token(name, env)}: \{resolve(value, env)};\n",
        )
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
) -> Unit raise @core.CompileError {
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
) -> Unit raise @core.CompileError {
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
    Decl(name, value) =>
      sb.write_string("  \{interp_token(name, env)}: \{resolve(value, env)};\n")
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
) -> Unit raise @core.CompileError {
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
) -> Unit raise @core.CompileError {
  for n in body {
    match n {
      Decl(name, value) =>
        decl_lines.push("\{interp_token(name, env)}: \{resolve(value, env)};")
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
          None =>
            raise @core.CompileError::EngineFailed(
              engine="scss",
              message="Undefined mixin: " + name,
            )
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
) -> Array[Node] raise @core.CompileError {
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
) -> Array[Node] raise @core.CompileError {
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
) -> Array[Node] raise @core.CompileError {
  let out : Array[Node] = []
  let list_src = strip_group_parens(deref_each_list(list, env))
  if vars.length() == 1 {
    let uses_var = nodes_contain_var(body, vars[0])
    for raw_group in split_on_commas(list_src) {
      let val = resolve(strip_group_parens(raw_group), env)
      let sub = if uses_var { substitute_var(body, vars[0], val) } else { body }
      for s in sub {
        out.push(s)
      }
    }
  } else {
    for raw_group in split_on_commas(list_src) {
      let group = strip_group_parens(raw_group)
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

///|
/// 去掉一组 token 最外层的配对括号：`( a b )` -> `a b`
///
/// 必须校验配对：`(1 2), (3 4)` 的首 `(` 与末尾 `)` 不是一对，不能剥。
fn strip_group_parens(toks : Array[String]) -> Array[String] {
  let n = toks.length()
  if n < 2 || toks[0] != "(" || toks[n - 1] != ")" {
    return toks
  }
  let mut depth = 0
  for i, t in toks {
    if t == "(" {
      depth += 1
    } else if t == ")" {
      depth -= 1
      // 首括号提前闭合 → 末尾的 `)` 属于下一个分组
      if depth == 0 && i != n - 1 {
        return toks
      }
    }
  }
  if depth == 0 {
    toks[1:n - 1].to_owned()
  } else {
    toks
  }
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
/// 把 "0 0, 1 0.25rem" 这类 list 字符串拆回 token
///
/// 变量存的是 resolve 后的单字符串，@each 要按逗号/空格重新切结构。
/// 引号内、括号内的分隔符不参与切分：`"24,103,192"` 是**一个**值，
/// 不能按逗号拆成三段（否则元组解构会错乱）。
fn spread_list_string(s : String) -> Array[String] {
  let out : Array[String] = []
  // 先去掉最外层括号，否则顶层逗号会被算成括号内层，分不开组。
  let body = strip_wrapping_parens(s)
  let mut cur = StringBuilder()
  let mut depth = 0
  let mut quote : Char = '\u{0}'
  for ch in body {
    if quote != '\u{0}' {
      cur.write_char(ch)
      if ch == quote {
        quote = '\u{0}'
      }
      continue
    }
    if ch == '"' || ch == '\'' {
      quote = ch
      cur.write_char(ch)
      continue
    }
    if ch == '(' || ch == '[' {
      let item = cur.to_string()
      if item.length() > 0 {
        out.push(item)
        cur = StringBuilder()
      }
      out.push(ch.to_string())
      depth += 1
      continue
    }
    if ch == ')' || ch == ']' {
      let item = cur.to_string()
      if item.length() > 0 {
        out.push(item)
        cur = StringBuilder()
      }
      out.push(ch.to_string())
      if depth > 0 {
        depth -= 1
      }
      continue
    }
    if ch == ',' && depth == 0 {
      let item = cur.to_string()
      if item.length() > 0 {
        out.push(item)
        cur = StringBuilder()
      }
      out.push(",")
      continue
    }
    if ch == ' ' || ch == '\t' {
      let item = cur.to_string()
      if item.length() > 0 {
        out.push(item)
        cur = StringBuilder()
      }
      continue
    }
    cur.write_char(ch)
  }
  let item = cur.to_string()
  if item.length() > 0 {
    out.push(item)
  }
  out
}

///|
/// 去掉最外层成对括号：`(a b, c d)` -> `a b, c d`
///
/// 只有首个 `(` 与末尾 `)` 正好配对时才去：`(1 2), (3 4)` 是并列的两个
/// 括号组，不能被当成一个整体剥掉外层。
fn strip_wrapping_parens(s : String) -> String {
  let t = s.trim().to_owned()
  if t.length() < 2 || t[0] != '(' || t[t.length() - 1] != ')' {
    return t
  }
  let mut depth = 0
  let mut quote : UInt16 = 0
  let mut i = 0
  while i < t.length() {
    let ch = t[i]
    if quote != 0 {
      if ch == quote {
        quote = 0
      }
    } else if ch == '"' || ch == '\'' {
      quote = ch
    } else if ch == '(' {
      depth += 1
    } else if ch == ')' {
      depth -= 1
      if depth == 0 && i != t.length() - 1 {
        return t
      }
    }
    i += 1
  }
  t[1:t.length() - 1].trim().to_owned()
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
) -> Unit raise @core.CompileError {
  let mut iter = 0
  while eval_truthy(cond, env) && iter < 1000 {
    iter += 1
    gen(body, parent, env, sb)
  }
}

///|
/// 把选择器数组里的插值 `#{$var}` 求值后 join
fn join_resolved(
  selectors : Array[String],
  env : Env,
) -> String raise @core.CompileError {
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
fn resolve_sel_interp(s : String, env : Env) -> String raise @core.CompileError {
  interp_token(s, env)
}

///|
/// 对单个 token / 字符串里的 `#{...}` 插值求值
///
/// 一个 token 里可能有多段插值（`#{$a}-#{$b}`），逐段替换。
/// 插值结果若是带引号的字符串会去掉引号——这是 SCSS 的 `#{}` 语义，
/// 也是 `@include mixin("v-btn")` 里 `.#{$name}` 出来带引号的根因。
fn interp_token(t : String, env : Env) -> String raise @core.CompileError {
  if !t.contains("#{") {
    return t
  }
  let sb = StringBuilder()
  let n = t.length()
  let mut i = 0
  while i < n {
    if i + 1 < n && t[i] == '#' && t[i + 1] == '{' {
      let mut j = i + 2
      while j < n && t[j] != '}' {
        j += 1
      }
      if j >= n {
        // 未闭合：原样保留剩余文本，交给上层报错
        sb.write_string(t[i:n].to_owned())
        break
      }
      let inner = t[i + 2:j].trim().to_owned()
      let val = if inner.length() == 0 {
        ""
      } else {
        resolve(tokenize_str(inner), env)
      }
      sb.write_string(tri_quotes(val))
      i = j + 1
    } else {
      sb.write_char(Int::unsafe_to_char(t[i].to_int()))
      i += 1
    }
  }
  sb.to_string()
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
    // 属性名也要查：`--v-theme-#{$name}` 的插值只在名字里
    Decl(name, value) =>
      toks_contain_var([name], v) || toks_contain_var(value, v)
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
    // 名字里也有插值时（`--v-#{$name}`）一并替换，否则名字上的 $name
    // 会在后面插值求值时暴露成「Undefined variable」
    Decl(name, value) =>
      Decl(subst_toks([name], v, val)[0], subst_toks(value, v, val))
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
  // 插值里引号字符串要去引号（`#{"v-btn"}` -> `v-btn`）；
  // 裸 `$v` 用在值位置时保留引号。
  let interp_val = tri_quotes(val)
  for t in toks {
    if t == v {
      out.push(val)
    } else if t == interp {
      out.push(interp_val)
    } else if t.contains(interp) {
      out.push(t.replace(old=interp, new=interp_val))
    } else if t.contains(v) {
      out.push(t.replace(old=v, new=val))
    } else {
      out.push(t)
    }
  }
  out
}

///|
/// 计算条件真假：非空、非 false
fn eval_truthy(
  cond : Array[String],
  env : Env,
) -> Bool raise @core.CompileError {
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
fn resolve(toks : Array[String], env : Env) -> String raise @core.CompileError {
  // 空的声明值（`width: ;`）是残缺表达式，dart-sass 也报 Expected expression.
  if toks.length() == 0 {
    raise @core.CompileError::EngineFailed(
      engine="scss",
      message="Expected expression.",
    )
  }
  // 单 token 的普通值无需经过 StringBuilder，直接复用原 token。
  if toks.length() == 1 {
    let t = toks[0]
    if !t.contains("$") && !t.contains("#{") && !is_op(t) && !is_paren(t) {
      return t
    }
  }
  // 普通 CSS 值不需要变量、插值或表达式处理，跳过中间数组与算术折叠。
  if can_fast_resolve(toks) {
    return join_value_tokens(toks, [])
  }
  let parts : Array[String] = []
  for t in toks {
    if t.length() > 0 && t[0] == '$' {
      match Env::get_var(env, t) {
        Some(v) => parts.push(resolve(v, env))
        None =>
          raise @core.CompileError::EngineFailed(
            engine="scss",
            message="Undefined variable: " + t,
          )
      }
    } else if t.contains("#{") {
      // 整段 `#{$v}` 或者嵌在标识符里的 `--x-#{$v}` 都走这里
      parts.push(interp_token(t, env))
    } else {
      parts.push(t)
    }
  }
  let stripped = strip_parens(parts)
  let folded = fold_arith(stripped)
  join_value_tokens(folded, math_group_mask(folded))
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
/// 值 token 序列化：运算符 / 括号 / 逗号 / 冒号按 CSS 习惯紧贴相邻 token
///
/// `mask` 标出每个 token 是否落在 `calc()`/`min()`/`max()`/`clamp()` 组内，
/// 组内是 CSS Calculation 语义，运算符两侧必须有空白。
fn join_value_tokens(
  parts : Array[String],
  mask : Array[Bool],
) -> String raise @core.CompileError {
  let sb = StringBuilder()
  for i, t in parts {
    let in_math = mask_at(mask, i) || mask_at(mask, i - 1)
    if t == "+" && !in_math {
      // 字符串连接：去除 +，且让前后 token 紧密（c + d -> cd）。
      // 但 `+` 必须有右操作数——`width: 1px + ;` 这种残缺表达式以前会把
      // `+` 静静丢掉，产出一个看起来正常的声明，没有任何报错。
      //
      // 数学函数组内不走这条路：calc(a + b) 里的 `+` 是加法，
      // 当连接符吃掉会变成 calc(ab)。
      if i + 1 >= parts.length() {
        raise @core.CompileError::EngineFailed(
          engine="scss",
          message="Expected expression.",
        )
      }
      continue
    }
    if i > 0 && value_needs_space(parts, i, in_math) {
      sb.write_string(" ")
    }
    sb.write_string(t)
  }
  sb.to_string()
}

///|
/// 相邻两个值 token 之间是否需要空格（`i` 为当前 token 下标，i > 0）
///
/// `,` `:` `)` 与运算符、左括号都紧贴前一个 token；
/// 左括号、运算符之后的 token 也紧贴——`var(--o, rgba(0, 0, 0, .2))`
/// 以前会被插成 `var(--o , rgba(0 , 0 , 0 , 0.2))`，`:has()` / `@supports`
/// 的 `:` 同理。
///
/// `calc()` 这类数学函数是例外：CSS 规定组内二元运算符两侧必须有空白，
/// 写成 `calc(100%-10px)` 浏览器会整条丢弃；一元符号（`-2px`）不空格。
fn value_needs_space(parts : Array[String], i : Int, in_math : Bool) -> Bool {
  let prev = parts[i - 1]
  let cur = parts[i]
  if in_math {
    if is_op(cur) {
      return !is_unary_op_at(parts, i)
    }
    if is_op(prev) {
      return !is_unary_op_at(parts, i - 1)
    }
  }
  if is_op(cur) || is_paren(cur) || cur == "," || cur == ":" {
    return false
  }
  if prev == "(" || is_op(prev) {
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
  p == "(" || p == "," || is_op(p)
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
/// 标出每个 token 是否落在数学函数组内（无括号时返回空数组，省一次分配）
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
/// 是否为括号 token
fn is_paren(t : String) -> Bool {
  t == "(" || t == ")"
}

///|
fn join_value(
  toks : Array[String],
  env : Env,
) -> String raise @core.CompileError {
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
///
/// 数学函数组内（`calc()`/`min()`/`max()`/`clamp()`）一律不折叠：
/// 那里是 CSS Calculation，`calc(100% - 10px)` 折叠成 `calc(90%)` 会改语义，
/// 而且是静默的。完整对齐 dart-sass 需要带单位 + 浮点的值模型，另议。
fn fold_arith(parts : Array[String]) -> Array[String] {
  let mask = math_group_mask(parts)
  let out : Array[String] = []
  let mut i = 0
  while i < parts.length() {
    if !mask_at(mask, i) &&
      i + 2 < parts.length() &&
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
}

///|
/// 求值整个表达式（条件用），返回 CondVal
fn e_expr(toks : Array[String], env : Env) -> CondVal raise @core.CompileError {
  let (v, _) = e_or(toks, 0, env)
  v
}

///|
fn e_or(
  toks : Array[String],
  pos : Int,
  env : Env,
) -> (CondVal, Int) raise @core.CompileError {
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
fn e_and(
  toks : Array[String],
  pos : Int,
  env : Env,
) -> (CondVal, Int) raise @core.CompileError {
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
fn e_cmp(
  toks : Array[String],
  pos : Int,
  env : Env,
) -> (CondVal, Int) raise @core.CompileError {
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
fn e_add(
  toks : Array[String],
  pos : Int,
  env : Env,
) -> (CondVal, Int) raise @core.CompileError {
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
fn e_mul(
  toks : Array[String],
  pos : Int,
  env : Env,
) -> (CondVal, Int) raise @core.CompileError {
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
fn e_unary(
  toks : Array[String],
  pos : Int,
  env : Env,
) -> (CondVal, Int) raise @core.CompileError {
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
fn e_primary(
  toks : Array[String],
  pos : Int,
  env : Env,
) -> (CondVal, Int) raise @core.CompileError {
  if pos >= toks.length() {
    raise @core.CompileError::EngineFailed(
      engine="scss",
      message="Expected expression.",
    )
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
      None =>
        raise @core.CompileError::EngineFailed(
          engine="scss",
          message="Undefined variable: " + t,
        )
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
fn e_expr_at(
  toks : Array[String],
  pos : Int,
  env : Env,
) -> (CondVal, Int) raise @core.CompileError {
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
    // 字符串相等：`@if $density == compact` 走这里。
    // 以前 StrV 落到 `_` 分支恒为 false，两个分支都不进，整条规则静默消失。
    (StrV(x), StrV(y)) =>
      BoolV(
        if op == "==" {
          x == y
        } else if op == "!=" {
          x != y
        } else {
          // 字符串没有大小比较（dart-sass 直接报错），不假装能比
          false
        },
      )
    // 类型不同：只有 != 为真
    _ => BoolV(op == "!=")
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
