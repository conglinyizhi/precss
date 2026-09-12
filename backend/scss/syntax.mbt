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
/// 便于上层 parser 直接用字符串字面匹配。注释被丢弃。
///
/// 连续空白归并成一个 `" "` token 保留在流里（前后紧跟结构符的除外，
/// 见 `ws_irrelevant_prev` / `ws_irrelevant_next`），而不是丢掉：选择器里
/// `.a.b`（复合）与 `.a .b`（后代）的差别只存在于空白，丢了之后只能靠
/// 字符启发式猜，猜错就是把复合选择器变成后代选择器——整条规则静默失效。
/// 语法结构不关心空白，parser 的 `peek` / `advance` 会自动跳过它；
/// 只有选择器拼接（`join_selector` / LESS 的 `join_selector_tokens`）用它。
pub fn tokenize(src : String) -> Array[String] {
  let toks : Array[String] = []
  let n = src.length()
  let mut i = 0
  while i < n {
    let c = src[i]
    if is_ws(c) {
      while i < n && is_ws(src[i]) {
        i += 1
      }
      // 空白 token 只在「两个选择器 token 之间」有语义（区分复合与后代）。
      // 这几个位置前后都不会影响选择器，不产出 token；排版好的源码里
      // 绝大多数空白都在这里，省掉它们 token 流才基本维持原大小。
      let prev_tok = if toks.length() > 0 {
        toks[toks.length() - 1]
      } else {
        ""
      }
      let next_ok = i < n && !ws_irrelevant_next(src[i])
      if !ws_irrelevant_prev(prev_tok) && next_ok {
        toks.push(" ")
      }
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
    //
    // 负号与数字紧贴、且前面有空隙时，整体并成一个「负值」token：
    // `0px 3px 1px -2px` 是四个空格分隔的值，不是 `1px - 2px` 减法。
    // 不合并的话 fold_arith 会把 `1px - 2px` 求值成 `-1px`，静默改掉语义。
    let neg_num = c == '-' &&
      i > 0 &&
      is_ws(src[i - 1]) &&
      i + 1 < n &&
      (
        is_digit(src[i + 1]) ||
        (src[i + 1] == '.' && i + 2 < n && is_digit(src[i + 2]))
      )
    if is_digit(c) || (c == '.' && i + 1 < n && is_digit(src[i + 1])) || neg_num {
      let mut j = if neg_num { i + 1 } else { i }
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
    //
    // 紧贴其后的标识符字符并入同一 token：`#{$name}__overlay` 若不并，
    // 后面 join 时会在 `}` 与 `__overlay` 之间插一个空格，选择器就废了。
    if c == '#' && i + 1 < n && src[i + 1] == '{' {
      let mut j = i + 2
      while j < n && src[j] != '}' {
        j += 1
      }
      if j < n {
        j += 1
      }
      while j < n && is_ident_char(src[j]) {
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
/// 紧跟在后面出现的空白是否没有语义（不需要产出空白 token）
///
/// 这些字符后面一定是新 token 的开头，而空白 token 唯一的作用是区分选择器里
/// 的「复合 / 后代」（`.a.b` 与 `.a .b`）：
///
/// - `{` `}` `;` 后面是语法结构的位置，parser 的 `peek` / `advance` 会跳过；
/// - `:` `,` 后面不可能是同一个复合选择器里的下一个简单选择器（`: hover`、
///   `, .b` 都不是合法写法），选择器拼接与声明值都在边界处修掉它。
///
/// 其余位置（token 之间）的空白必须留下。
fn ws_irrelevant_prev(prev : String) -> Bool {
  if prev.length() == 0 {
    return true
  }
  let p = prev[prev.length() - 1]
  p == '{' || p == '}' || p == ';' || p == ':' || p == ','
}

///|
/// 紧跟在空白后面的这些字符同样让空白失去意义
///
/// `{` `}` `;` `,` `)` 前不可能需要一个空白来区分复合/后代；
/// 注意 `.` `#` `:` 不在内——`.a .b`、`.a :hover` 里的空白是有语义的。
fn ws_irrelevant_next(c : UInt16) -> Bool {
  c == '{' || c == '}' || c == ';' || c == ',' || c == ')'
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
/// 当前 token，跳过空白（无则 None）
///
/// 跳过循环写在这里而不是折成函数：`peek` / `advance` 是解析阶段最热的两个
/// 调用，多一层函数调用会把热路径磨慢。
fn Parser::peek(self : Parser) -> String? {
  while self.pos < self.toks.length() && self.toks[self.pos] == " " {
    self.pos += 1
  }
  if self.pos < self.toks.length() {
    Some(self.toks[self.pos])
  } else {
    None
  }
}

///|
/// 取走当前 token，跳过空白
fn Parser::advance(self : Parser) -> String {
  while self.pos < self.toks.length() && self.toks[self.pos] == " " {
    self.pos += 1
  }
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
///
/// head 用原始 token 收集（含空白 token）：选择器需要它，声明不需要。
/// 到 `{` 才知道是规则集，所以先原样收着，落成声明时再 `strip_ws`。
fn Parser::parse_decl_or_rule(self : Parser) -> Node? raise @core.CompileError {
  while self.pos < self.toks.length() && self.toks[self.pos] == " " {
    self.pos += 1
  }
  let head : Array[String] = []
  while true {
    if self.pos >= self.toks.length() {
      break
    }
    let t = self.toks[self.pos]
    if t == "{" {
      self.pos += 1
      let selectors = split_selectors(head)
      let body = self.parse_block()
      self.expect("}")
      return Some(RuleSet(selectors, body))
    }
    if t == ";" {
      self.pos += 1
      return parse_decl(head)
    }
    if t == "}" {
      break
    }
    head.push(t)
    self.pos += 1
  }
  // 块结尾（} 或 EOF）：若形如 `name: value` 则按声明处理（SCSS 允许末尾声明省略分号）
  if has_colon(head) {
    return parse_decl(head)
  }
  Some(Raw(strip_ws(head).join(" ")))
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
///
/// 空白 token 是选择器语义的产物，声明不要它，但每次都 `strip_ws` 一下会
/// 给每条声明多两次分配。这里先扫一遍：整段没夹空白 token 就直接切片
/// （与加空白 token 之前的开销一致），夹了才走过滤。
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
    return Some(Raw(strip_ws(head).join(" ")))
  }
  let name = if has_ws(head, 0, colon) {
    strip_ws(head[0:colon].to_owned()).join("")
  } else {
    head[0:colon].join("")
  }
  let value = if has_ws(head, colon + 1, head.length()) {
    strip_ws(head[colon + 1:].to_owned())
  } else {
    head[colon + 1:].to_owned()
  }
  Some(Decl(name, value))
}

///|
/// `[from, to)` 区间内是否夹着空白 token
fn has_ws(toks : Array[String], from : Int, to : Int) -> Bool {
  let mut i = from
  while i < to {
    if toks[i] == " " {
      return true
    }
    i += 1
  }
  false
}

///|
/// 剔除 token 流里的空白 token
///
/// 值与声明名由上层统一用空格拼接（`resolve` / `decl_line`），空白 token
/// 混进去只会变成双空格。
fn strip_ws(toks : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for t in toks {
    if t != " " {
      out.push(t)
    }
  }
  out
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
/// 把选择器 token join 成字符串
///
/// 空白完全按 token 流原样还原：有空白 token 的地方才出空格。不再用
/// 「前一个 token 以 `.` `:` `(`…… 结尾就不加空格」那套字符启发式——
/// 启发式分不清 `.a:not(.b).c` 和 `.a:not(.b) .c`，见 issue #2。
fn join_selector(tokens : Array[String]) -> String {
  let sb = StringBuilder()
  // 上一个已写出的 token（"" 表示还没写任何东西）
  let mut prev = ""
  // 待写的空白：只有后面真的跟着 token 才落下来，尾随空白自然丢弃
  let mut pending_space = false
  for t in tokens {
    if t == " " {
      if prev != "" {
        pending_space = true
      }
      continue
    }
    // 括号内不留空白：`:not( .b )` → `:not(.b)`
    if pending_space && prev != "(" && t != ")" {
      sb.write_string(" ")
    }
    sb.write_string(t)
    prev = t
    pending_space = false
  }
  sb.to_string()
}
