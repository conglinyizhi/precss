///| LESS 独立引擎：AST + 解析器
///
/// 词法复用 SCSS 的 `@scss.tokenize`（`@var`/`.name`/运算符/括号/字符串都覆盖），
/// 但解析按 LESS 语义：`@name:` 是变量（而非 at-rule）、`.name(...)` 是类 mixin。
/// 求值走 `less_eval.mbt`（lazy 变量作用域 / 类 mixin 混入 / 运算），不复用 SCSS 引擎。

///|
/// LESS AST（面向求值）
pub(all) enum LessNode {
  /// 规则集：选择器 token + 规则体
  RuleSet(Array[String], Array[LessNode])
  /// 声明：属性 + 值 token 序列
  Decl(String, Array[String])
  /// 变量定义：`@name : value`（name 不含 @）
  VarDef(String, Array[String])
  /// mixin 定义：`.name(@a, @b) {}`（params 含 @ 前缀，如 @w）
  MixinDef(String, Array[String], Array[LessNode])
  /// mixin 调用：`.name(args)` / `.name;`
  MixinCall(String, Array[String])
  /// 透传 at-rule：`@media (...) {}`
  AtRule(String, Array[String], Array[LessNode])
  /// `@import "path"`
  Import(String)
  /// 无法解析时原样透传
  Raw(String)
} derive(Debug)

///|
pub extend LessNode with @debug.Debug::{to_repr}

///|
/// LESS 解析入口：token 序列 → node 列表
pub fn parse_less(
  toks : Array[String],
) -> Array[LessNode] raise @core.CompileError {
  let p = LessParser::new(toks)
  p.parse_block()
}

///|
priv struct LessParser {
  toks : Array[String]
  mut pos : Int
}

///|
fn LessParser::new(toks : Array[String]) -> LessParser {
  { toks, pos: 0, }
}

///|
/// 当前 token，跳过空白（无则 None）
///
/// 跳过循环写在这里而不是折成函数：`peek` / `advance` 是解析阶段最热的两个
/// 调用，多一层函数调用会把热路径磨慢。需要原样保留空白的只有选择器头
/// （`read_head` 直接读 `toks`）。
fn LessParser::peek(self : LessParser) -> String? {
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
fn LessParser::advance(self : LessParser) -> String {
  while self.pos < self.toks.length() && self.toks[self.pos] == " " {
    self.pos += 1
  }
  let t = self.toks[self.pos]
  self.pos += 1
  t
}

///|
/// 解析到块尾（`}` 或 EOF，不消费 `}`）
fn LessParser::parse_block(
  self : LessParser,
) -> Array[LessNode] raise @core.CompileError {
  let nodes : Array[LessNode] = []
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
fn LessParser::parse_one(
  self : LessParser,
) -> LessNode? raise @core.CompileError {
  match self.peek() {
    None => None
    Some("}") => None
    Some(first) =>
      if first.length() > 0 && first[0] == '@' {
        let name = strip_at(first)
        if is_at_rule_keyword(name) {
          self.parse_at()
        } else {
          Some(self.parse_var())
        }
      } else if first.length() > 0 && first[0] == '.' {
        match self.peek_at(1) {
          Some("(") => self.parse_mixin()
          Some(";") => {
            // `.m;` 分离调用
            let name = strip_dot(self.advance())
            self.consume(";")
            Some(MixinCall(name, []))
          }
          _ => self.parse_decl_or_rule()
        }
      } else {
        self.parse_decl_or_rule()
      }
  }
}

///|
/// 变量定义 `@name : value ;`
fn LessParser::parse_var(self : LessParser) -> LessNode {
  let name = strip_at(self.advance())
  self.consume(":")
  let value = strip_ws(self.read_head())
  self.consume(";")
  VarDef(name, value)
}

///|
/// at-rule：@media / @import / 透传
fn LessParser::parse_at(
  self : LessParser,
) -> LessNode? raise @core.CompileError {
  let name = strip_at(self.advance())
  if name == "import" {
    let path_tok = self.advance()
    ignore(self.read_head())
    self.consume(";")
    return Some(Import(strip_quotes(path_tok)))
  }
  // 读 prelude 到 `{`
  let prelude = self.read_until_brace()
  match self.peek() {
    Some("{") => {
      self.pos += 1
      let body = self.parse_block()
      self.expect("}")
      Some(AtRule(name, prelude, body))
    }
    Some(";") => {
      self.pos += 1
      Some(AtRule(name, prelude, []))
    }
    _ => Some(AtRule(name, prelude, []))
  }
}

///|
/// 类 mixin：`.name(...)` 定义（后接 `{`）或调用
fn LessParser::parse_mixin(
  self : LessParser,
) -> LessNode? raise @core.CompileError {
  let name = strip_dot(self.advance()) // `.name`
  self.consume("(")
  let params = self.read_paren_list()
  match self.peek() {
    Some("{") => {
      self.pos += 1
      let body = self.parse_block()
      self.expect("}")
      Some(MixinDef(name, params, body))
    }
    Some(";") => {
      self.pos += 1
      Some(MixinCall(name, params))
    }
    _ => Some(MixinCall(name, params))
  }
}

///|
/// 声明或嵌套规则
///
/// head 用原始 token 收集（含空白 token）：选择器需要它，声明不需要。
/// 到 `{` 才知道是规则集，所以先原样收着，落成声明时再过滤。
fn LessParser::parse_decl_or_rule(
  self : LessParser,
) -> LessNode? raise @core.CompileError {
  let head = self.read_head()
  match self.peek() {
    Some("{") => {
      self.pos += 1
      let body = self.parse_block()
      self.expect("}")
      Some(RuleSet(head, body))
    }
    Some(";") => {
      self.pos += 1
      Some(self.make_decl_or_raw(head))
    }
    _ => Some(self.make_decl_or_raw(head))
  }
}

///|
/// 读到 `{` / `;` / `}` / EOF（`:` 不截断，避免把 `&:hover` 当声明）
///
/// 空白 token 原样保留：返回的 head 既可能是选择器也可能是声明，
/// 前者需要空白来区分复合/后代，后者由调用方按需过滤。
fn LessParser::read_head(self : LessParser) -> Array[String] {
  while self.pos < self.toks.length() && self.toks[self.pos] == " " {
    self.pos += 1
  }
  let out : Array[String] = []
  while true {
    if self.pos >= self.toks.length() {
      break
    }
    let t = self.toks[self.pos]
    if t == "}" || t == ";" || t == "{" {
      break
    }
    out.push(t)
    self.pos += 1
  }
  // 首尾空白对选择器与声明都无意义（`single_class_name([".m"])` 靠这个成立），
  // 内部空白要留着
  trim_ws(out)
}

///|
/// 去掉 token 流首尾的空白 token
///
/// 无空白可去时直接返回原数组（分词阶段已把结构符旁的空白省掉，这是常态）。
fn trim_ws(toks : Array[String]) -> Array[String] {
  let n = toks.length()
  if n == 0 || (toks[0] != " " && toks[n - 1] != " ") {
    return toks
  }
  let mut start = 0
  let mut end = n
  while start < end && toks[start] == " " {
    start += 1
  }
  while end > start && toks[end - 1] == " " {
    end -= 1
  }
  toks[start:end].to_owned()
}

///|
/// token 流里是否夹着空白 token
fn has_ws(toks : Array[String]) -> Bool {
  for t in toks {
    if t == " " {
      return true
    }
  }
  false
}

///|
/// 去掉 token 流里的空白 token（声明的属性名 / 值不需要空白信息）
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
/// head 含 `:` 则拆成声明（prop: val），否则 Raw
fn LessParser::make_decl_or_raw(
  self : LessParser,
  head : Array[String],
) -> LessNode {
  ignore(self)
  // 声明里通常没有空白 token（分词阶段已把结构符旁的空白省掉），
  // 这时直接用 head，不做拷贝
  let toks = if has_ws(head) { strip_ws(head) } else { head }
  let colon = find_colon_in_tokens(toks)
  if colon > 0 {
    let prop = toks[0:colon].join(" ")
    let val = toks[colon + 1:].to_owned()
    Decl(prop, val)
  } else {
    // 块内单独一个类名、又没有分号结尾（`.a { .m }`）：LESS 里这是无参
    // mixin 调用。之前落成 Raw，而求值侧对 Raw 直接丢弃，整个块就没了。
    match single_class_name(toks) {
      Some(name) => MixinCall(name, [])
      None => Raw(toks.join(" "))
    }
  }
}

///|
fn find_colon_in_tokens(toks : Array[String]) -> Int {
  for i in 0..<toks.length() {
    if toks[i] == ":" {
      return i
    }
  }
  -1
}

///|
/// 读到 `{` 或 `;` 或块尾（用于 at-rule prelude）
fn LessParser::read_until_brace(self : LessParser) -> Array[String] {
  let out : Array[String] = []
  while true {
    match self.peek() {
      None => break
      Some("}") => break
      Some("{") => break
      Some(";") => {
        self.pos += 1
        break
      }
      Some(t) => {
        out.push(t)
        self.pos += 1
      }
    }
  }
  out
}

///|
/// 读 mixin 参数/实参列表（括号内），返回各项（`@w`/`10px` 等）
fn LessParser::read_paren_list(self : LessParser) -> Array[String] {
  let items : Array[String] = []
  let mut cur = StringBuilder()
  let mut depth = 0
  while true {
    match self.peek() {
      None => break
      Some(")") => {
        self.pos += 1
        if depth == 0 {
          let item = cur.to_string().trim().to_owned()
          if item.length() > 0 {
            items.push(item)
          }
          break
        } else {
          cur.write_string(")")
          depth -= 1
        }
      }
      Some("(") => {
        self.pos += 1
        cur.write_string("(")
        depth += 1
      }
      Some(",") | Some(";") => {
        self.pos += 1
        if depth == 0 {
          items.push(cur.to_string().trim().to_owned())
          cur = StringBuilder()
        } else {
          cur.write_string(",")
        }
      }
      Some(t) => {
        cur.write_string(t)
        self.pos += 1
        // 项内给 token 之间补空格，保证原样可读
        if self.peek() is Some(_) && t != "(" {
          cur.write_string(" ")
        }
      }
    }
  }
  items
}

///|
/// 输出当前 pos 起第 off 个**非空白** token
fn LessParser::peek_at(self : LessParser, off : Int) -> String? {
  let mut k = self.pos
  let mut seen = 0
  while k < self.toks.length() {
    let t = self.toks[k]
    if t != " " {
      if seen == off {
        return Some(t)
      }
      seen += 1
    }
    k += 1
  }
  None
}

///|
/// 消费一个预期 token；不匹配则不动
fn LessParser::consume(self : LessParser, tok : String) -> Unit {
  if self.peek() is Some(t) && t == tok {
    self.pos += 1
  }
}

///|
/// 消费指定 token；当前位置不是它时报错
///
/// 与 SCSS 侧同理：`consume` 对缺失的 `}` 是静默跳过的，未闭合的块会一路
/// 解析成空块，最后输出空字符串而不是报错。
fn LessParser::expect(
  self : LessParser,
  tok : String,
) -> Unit raise @core.CompileError {
  match self.peek() {
    Some(t) if t == tok => self.pos += 1
    Some(t) =>
      raise @core.CompileError::EngineFailed(
        engine="less",
        message="expected \"" + tok + "\", found \"" + t + "\"",
      )
    None =>
      raise @core.CompileError::EngineFailed(
        engine="less",
        message="expected \"" + tok + "\"",
      )
  }
}

///|
/// 去掉 `@` 前缀
fn strip_at(s : String) -> String {
  if s.length() > 0 && s[0] == '@' {
    s[1:].to_owned()
  } else {
    s
  }
}

///|
/// 去掉 `.` 前缀
fn strip_dot(s : String) -> String {
  if s.length() > 0 && s[0] == '.' {
    s[1:].to_owned()
  } else {
    s
  }
}

///|
/// 去掉字符串引号
fn strip_quotes(s : String) -> String {
  let n = s.length()
  if n >= 2 && (s[0] == '"' || s[0] == '\'') && s[n - 1] == s[0] {
    s[1:n - 1].to_owned()
  } else {
    s
  }
}
