///|
/// SCSS 子集的中间表示
///
/// 一个自上而下、面向样式的 AST。声明与规则集共用 `Node`，
/// 变量、mixin、控制流都作为一等节点，便于求值阶段展开。
pub(all) enum Node {
  /// 规则集：选择器数组 + 规则体（内含声明或嵌套规则）
  RuleSet(Array[String], Array[Node])
  /// 声明：属性名 + 值 token 序列
  Decl(String, Array[String])
  /// 变量定义：`$name : value`
  VarDef(String, Array[String])
  /// mixin 定义
  MixinDef(String, Array[String], Array[Node])
  /// mixin 调用（含 @content 内容块，可空）
  MixinCall(String, Array[String], Array[Node])
  /// `@content` 占位（mixin 内，@include 时被内容块替换）
  Content
  /// `@if` 条件分支（else_body 可为空数组）
  If(Array[String], Array[Node], Array[Node])
  /// `@for $i from A to B` 循环
  For(String, Array[String], Array[String], Array[Node])
  /// `@each $x in list` 列表迭代
  Each(Array[String], Array[String], Array[Node])
  /// `@while cond` 循环
  While(Array[String], Array[Node])
  /// `@import "path"`（path 不含引号）
  Import(String)
  /// 透传的 at-rule（如 @media / @supports）
  AtRule(String, Array[String], Array[Node])
  /// 无法解析时原样透传的文本
  Raw(String)
} derive(Debug)

///|
pub extend Node with @debug.Debug::{to_repr}

///|

///|
/// SCSS 词法：把源码切成 token 序列
///
/// token 以裸字符串表示（`$var`、`@mixin`、`1px`、`red`、`{`、`:`……），
/// 便于上层 parser 直接用字符串字面匹配。注释与空白被丢弃。
pub fn tokenize(src : String) -> Array[String] {
  let toks : Array[String] = []
  let n = src.length()
  let mut i = 0
  while i < n {
    let c = src[i]
    if is_ws(c) {
      i += 1
      continue
    }
    // 注释
    if c == '/' && i + 1 < n {
      if src[i + 1] == '/' {
        while i < n && src[i] != '\n' {
          i += 1
        }
        continue
      }
      if src[i + 1] == '*' {
        i += 2
        while i + 1 < n && !(src[i] == '*' && src[i + 1] == '/') {
          i += 1
        }
        i += 2
        continue
      }
    }
    // 引号字符串（保留引号）
    if c == '"' || c == '\'' {
      let q = c
      let mut j = i + 1
      while j < n && src[j] != q {
        j += 1
      }
      if j < n {
        j += 1
      }
      toks.push(src[i:j].to_owned())
      i = j
      continue
    }
    // 数字（含 .5、-2 等）
    if is_digit(c) || (c == '.' && i + 1 < n && is_digit(src[i + 1])) {
      let mut j = i
      while j < n &&
            (
              is_digit(src[j]) ||
              src[j] == '.' ||
              src[j] == '%' ||
              src[j] == 'e' ||
              src[j] == 'E'
            ) {
        j += 1
      }
      // 紧跟的字母单位（px / em / rem / vh / deg 等）并入数字 token
      while j < n && is_alpha(src[j]) {
        j += 1
      }
      toks.push(src[i:j].to_owned())
      i = j
      continue
    }
    // 变量 `$name` 或 at-rule `@name`
    if c == '$' || c == '@' {
      let mut j = i + 1
      while j < n && is_ident_char(src[j]) {
        j += 1
      }
      toks.push(src[i:j].to_owned())
      i = j
      continue
    }
    // 多字符运算符 `==` `!=` `>=` `<=`
    if i + 1 < n &&
      (
        (c == '=' && (src[i + 1] == '=' || src[i + 1] == '>')) ||
        (c == '!' && src[i + 1] == '=') ||
        (c == '>' && src[i + 1] == '=') ||
        (c == '<' && src[i + 1] == '=')
      ) {
      toks.push(src[i:i + 2].to_owned())
      i += 2
      continue
    }
    // `!word`（!default / !global / !important 等）作为一个整体 token
    if c == '!' {
      let mut j = i + 1
      while j < n && is_ident_char(src[j]) {
        j += 1
      }
      toks.push(src[i:j].to_owned())
      i = j
      continue
    }
    // 插值 `#{...}` 作为一个整体 token
    if c == '#' && i + 1 < n && src[i + 1] == '{' {
      let mut j = i + 2
      while j < n && src[j] != '}' {
        j += 1
      }
      if j < n {
        j += 1
      }
      toks.push(src[i:j].to_owned())
      i = j
      continue
    }
    // 标识符 / 选择器字符
    if is_ident_start(c) || c == '#' || c == '.' || c == '%' || c == '&' {
      let mut j = i
      while j < n &&
            (
              is_ident_char(src[j]) ||
              src[j] == '-' ||
              src[j] == '.' ||
              src[j] == '%' ||
              src[j] == '&' ||
              (src[j] == '#' && (j + 1 >= n || src[j + 1] != '{'))
            ) {
        j += 1
      }
      toks.push(src[i:j].to_owned())
      i = j
      continue
    }
    // 单字符符号：; : , { } ( ) + - * / 等
    toks.push(src[i:i + 1].to_owned())
    i += 1
  }
  toks
}

///|
/// 是否为空白字符
fn is_ws(u : UInt16) -> Bool {
  u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D || u == 0x0C
}

///|
/// 是否为十进制数字
fn is_digit(u : UInt16) -> Bool {
  u >= '0' && u <= '9'
}

///|
/// 标识符起始字符
fn is_ident_start(u : UInt16) -> Bool {
  (u >= 'A' && u <= 'Z') || (u >= 'a' && u <= 'z') || u == '_'
}

///|
/// 标识符字符
fn is_ident_char(u : UInt16) -> Bool {
  is_ident_start(u) || is_digit(u) || u == '-'
}

///|
/// 字母字符
fn is_alpha(u : UInt16) -> Bool {
  (u >= 'A' && u <= 'Z') || (u >= 'a' && u <= 'z')
}

///|

///|
/// SCSS 解析器：token 序列 → AST
///
/// 递归下降，自顶向下解析一个样式表。声明、规则集、变量、mixin、
/// 控制流都作为 `Node` 产出。
priv struct Parser {
  toks : Array[String]
  mut pos : Int
}

///|
/// 解析整个样式表
pub fn parse_sheet(
  toks : Array[String],
) -> Array[Node] raise @core.CompileError {
  let p = Parser::new(toks)
  p.parse_block()
}

///|
fn Parser::new(toks : Array[String]) -> Parser {
  { toks, pos: 0, }
}

///|
/// 当前 token（无则 None）
fn Parser::peek(self : Parser) -> String? {
  if self.pos < self.toks.length() {
    Some(self.toks[self.pos])
  } else {
    None
  }
}

///|
/// 取走当前 token
fn Parser::advance(self : Parser) -> String {
  let t = self.toks[self.pos]
  self.pos += 1
  t
}

///|
/// 解析到块尾（`}` 或 EOF，不消费 `}`）
fn Parser::parse_block(self : Parser) -> Array[Node] raise @core.CompileError {
  let nodes : Array[Node] = []
  while true {
    match self.peek() {
      None => break
      Some("}") => break
      Some(_) =>
        match self.parse_one() {
          Some(node) => nodes.push(node)
          None => break
        }
    }
  }
  nodes
}

///|
/// 解析一个节点
fn Parser::parse_one(self : Parser) -> Node? raise @core.CompileError {
  match self.peek() {
    None => None
    Some("}") => None
    Some(first) =>
      if first.length() > 0 && first[0] == '$' {
        Some(self.parse_var())
      } else if first.length() > 0 && first[0] == '@' {
        self.parse_at()
      } else {
        self.parse_decl_or_rule()
      }
  }
}

///|
/// 变量定义 `$name : value ;`
fn Parser::parse_var(self : Parser) -> Node {
  let name = self.advance()
  self.consume(":")
  let value = self.read_value()
  VarDef(name, value)
}

///|
/// at-rule：mixins / 控制流 / 透传
fn Parser::parse_at(self : Parser) -> Node? raise @core.CompileError {
  let name = self.advance()
  if name == "@mixin" {
    let mixin_name = self.advance()
    let params = self.read_params()
    self.consume("{")
    let body = self.parse_block()
    self.expect("}")
    return Some(MixinDef(mixin_name, params, body))
  }
  if name == "@include" {
    let inc_name = self.advance()
    let args = self.read_invoke_args()
    let content = if self.peek() is Some("{") {
      self.pos += 1
      let b = self.parse_block()
      self.expect("}")
      b
    } else {
      []
    }
    return Some(MixinCall(inc_name, args, content))
  }
  if name == "@content" {
    return Some(Content)
  }
  if name == "@warn" || name == "@debug" || name == "@error" {
    ignore(self.read_value())
    return Some(Raw(""))
  }
  if name == "@import" {
    let path_tok = self.advance()
    ignore(self.read_value())
    return Some(Import(tri_quotes(path_tok)))
  }
  if name == "@if" {
    let cond = self.read_until_brace()
    let body = self.parse_block()
    self.expect("}")
    let else_body = self.parse_else_tail()
    return Some(If(cond, body, else_body))
  }
  if name == "@for" {
    let var_name = self.advance()
    self.consume("from")
    let from = [self.advance()]
    self.consume("to")
    let to = self.read_until_brace()
    let body = self.parse_block()
    self.expect("}")
    return Some(For(var_name, from, to, body))
  }
  if name == "@each" {
    let vars = self.read_each_vars()
    self.consume("in")
    let list = self.read_until_brace()
    let body = self.parse_block()
    self.expect("}")
    return Some(Each(vars, list, body))
  }
  if name == "@while" {
    let cond = self.read_until_brace()
    let body = self.parse_block()
    self.expect("}")
    return Some(While(cond, body))
  }
  if name == "@else" {
    // 独立 @else 通常紧随 @if，这里按空块处理以免死循环
    return None
  }
  // 其余 at-rule（@media / @supports 等）透传
  let prelude = self.read_until_brace()
  let body = self.parse_block()
  self.expect("}")
  return Some(AtRule(name, prelude, body))
}

///|
/// 解析 `@else` / `@else if` 链（返回后续节点）
fn Parser::parse_else_tail(
  self : Parser,
) -> Array[Node] raise @core.CompileError {
  match self.peek() {
    Some("@else") => {
      ignore(self.advance())
      let nx = self.peek()
      if nx is Some(v) && v == "if" {
        ignore(self.advance())
        let cond = self.read_until_brace()
        let body = self.parse_block()
        self.expect("}")
        let tail = self.parse_else_tail()
        return [If(cond, body, tail)]
      } else {
        self.consume("{")
        let eb = self.parse_block()
        self.expect("}")
        return eb
      }
    }
    _ => []
  }
}

///|
/// 读取 `@each` 的变量名列表（$a, $b，逗号分隔）
fn Parser::read_each_vars(self : Parser) -> Array[String] {
  let vars : Array[String] = []
  while true {
    match self.peek() {
      Some("in") => break
      Some(",") => self.pos += 1
      None => break
      Some(_) => vars.push(self.advance())
    }
  }
  vars
}

///|
/// 读取 `@include` 的实参：括号内逗号分隔，每项 join 成一个字符串
fn Parser::read_invoke_args(self : Parser) -> Array[String] {
  let out : Array[String] = []
  if self.peek() is Some("(") {
    self.pos += 1
    let mut cur : Array[String] = []
    while true {
      match self.peek() {
        Some(")") => {
          self.pos += 1
          break
        }
        Some(",") => {
          out.push(cur.join(" "))
          self.pos += 1
          let fresh : Array[String] = []
          cur = fresh
        }
        None => break
        Some(_) => cur.push(self.advance())
      }
    }
    let last = cur.join(" ")
    if last.length() > 0 {
      out.push(last)
    }
  }
  out
}

///|
/// mixin 参数：`(a, b)` 或空
fn Parser::read_params(self : Parser) -> Array[String] {
  if self.peek() is Some("(") {
    self.pos += 1
    let ps : Array[String] = []
    let mut cur : Array[String] = []
    while true {
      match self.peek() {
        Some(")") => {
          self.pos += 1
          ps.push(cur.join(" "))
          break
        }
        Some(",") => {
          self.pos += 1
          ps.push(cur.join(" "))
          let fresh : Array[String] = []
          cur = fresh
        }
        None => break
        Some(_) => cur.push(self.advance())
      }
    }
    return ps
  }
  []
}

///|
/// 声明或规则集
fn Parser::parse_decl_or_rule(self : Parser) -> Node? raise @core.CompileError {
  let head : Array[String] = []
  while true {
    match self.peek() {
      None => break
      Some("{") => {
        self.pos += 1
        let selectors = split_selectors(head)
        let body = self.parse_block()
        self.expect("}")
        return Some(RuleSet(selectors, body))
      }
      Some(";") => {
        self.pos += 1
        return parse_decl(head)
      }
      Some("}") => break
      Some(_) => head.push(self.advance())
    }
  }
  // 块结尾（} 或 EOF）：若形如 `name: value` 则按声明处理（SCSS 允许末尾声明省略分号）
  if has_colon(head) {
    return parse_decl(head)
  }
  Some(Raw(head.join(" ")))
}

///|
/// head 中是否含冒号
fn has_colon(head : Array[String]) -> Bool {
  for t in head {
    if t == ":" {
      return true
    }
  }
  false
}

///|
/// 从 `name : value` 头解析声明
fn parse_decl(head : Array[String]) -> Node? {
  let mut colon = -1
  let mut i = 0
  while i < head.length() {
    if head[i] == ":" {
      colon = i
      break
    }
    i += 1
  }
  if colon < 0 {
    // 没有冒号，无法当作声明；透传
    return Some(Raw(head.join(" ")))
  }
  let name = head[0:colon].join("")
  let value = head[colon + 1:].to_owned()
  Some(Decl(name, value))
}

///|
/// 读取值，遇到 `;` 或 `}` 停止（`;` 被消费）
fn Parser::read_value(self : Parser) -> Array[String] {
  let v : Array[String] = []
  while true {
    match self.peek() {
      None => break
      Some(";") => {
        self.pos += 1
        break
      }
      Some("}") => break
      Some(_) => v.push(self.advance())
    }
  }
  v
}

///|
/// 读取到 `{` 为止（`{` 被消费）
fn Parser::read_until_brace(self : Parser) -> Array[String] {
  let v : Array[String] = []
  while true {
    match self.peek() {
      Some("{") => {
        self.pos += 1
        break
      }
      None => break
      Some(_) => v.push(self.advance())
    }
  }
  v
}

///|
/// 消费一个期望 token（若匹配则跳过；不匹配也容错前进）
fn Parser::consume(self : Parser, tok : String) -> Unit {
  match self.peek() {
    Some(t) if t == tok => self.pos += 1
    _ => ()
  }
}

///|
/// 消费指定 token；当前位置不是它时报错
///
/// 用于「块必须闭合」这类场景——`consume` 对缺失的 `}` 是静默跳过的，
/// 未闭合的规则集会一路解析成空块，最后输出空字符串而不是报错。
fn Parser::expect(self : Parser, tok : String) -> Unit raise @core.CompileError {
  match self.peek() {
    Some(t) if t == tok => self.pos += 1
    Some(t) =>
      raise @core.CompileError::EngineFailed(
        engine="scss",
        message="expected \"" + tok + "\", found \"" + t + "\"",
      )
    None =>
      raise @core.CompileError::EngineFailed(
        engine="scss",
        message="expected \"" + tok + "\"",
      )
  }
}

///|
/// 把 token 数组按 `,` 拆成一组选择器
fn split_selectors(tokens : Array[String]) -> Array[String] {
  let groups : Array[Array[String]] = []
  let mut cur : Array[String] = []
  for t in tokens {
    if t == "," {
      groups.push(cur)
      let fresh : Array[String] = []
      cur = fresh
    } else {
      cur.push(t)
    }
  }
  groups.push(cur)
  let out : Array[String] = []
  for g in groups {
    let s = join_selector(g)
    if s.length() > 0 {
      out.push(s)
    }
  }
  out
}

///|
/// 把选择器 token join 成字符串，连接符前不加空格
fn join_selector(tokens : Array[String]) -> String {
  let sb = StringBuilder()
  let mut prev = ""
  let mut first = true
  for t in tokens {
    if !first {
      let prev_tail = if prev.length() > 0 {
        prev[prev.length() - 1]
      } else {
        0
      }
      let no_space = is_joiner(t) || is_joiner_char(prev_tail)
      if !no_space {
        sb.write_string(" ")
      }
    }
    sb.write_string(t)
    prev = t
    first = false
  }
  sb.to_string()
}

///|
/// 是否为会紧贴下一个 token 的选择器连接符字符
fn is_joiner_char(u : UInt16) -> Bool {
  u == '.' ||
  u == ':' ||
  u == '#' ||
  u == '>' ||
  u == '+' ||
  u == '~' ||
  u == '-' ||
  u == '&' ||
  u == '@' ||
  u == '%'
}

///|
/// 是否为选择器连接符（前不加空格）
fn is_joiner(t : String) -> Bool {
  t == ":" ||
  t == "." ||
  t == "#" ||
  t == "@" ||
  t == "%" ||
  t == "&" ||
  t == ">" ||
  t == "+" ||
  t == "~" ||
  t == "-" ||
  t == "[" ||
  t == "]" ||
  t.has_prefix("#{")
}
