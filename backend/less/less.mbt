///| LESS 后端引擎
///
/// LESS 与 SCSS 在嵌套/运算/@import/@media 上高度重叠，差异是变量前缀
/// `@var` 与**类 mixin** `.name(@a){}` / `.name(v)`。这里通过 `less_to_scss`
/// 把 LESS 转成 scss（变量 @→$、mixin .name(→@mixin/@include），复用 SCSS
/// 引擎编译。

///|
/// 把 LESS 转成等价的 scss
pub fn less_to_scss(source : String) -> String {
  let sb = StringBuilder()
  let n = source.length()
  let mut i = 0
  while i < n {
    if source[i] == '@' {
      let mut j = i + 1
      while j < n && is_ident_char(source[j]) {
        j += 1
      }
      let name = source[i + 1:j].to_owned()
      if is_at_rule_keyword(name) {
        sb.write_string("@")
        sb.write_string(name)
      } else {
        sb.write_string("$")
        sb.write_string(name)
      }
      i = j
    } else if source[i] == '.' && i + 1 < n && is_ident_start(source[i + 1]) {
      // 类选择器或 mixin
      let mut j = i + 1
      while j < n && is_ident_char(source[j]) {
        j += 1
      }
      let name = source[i + 1:j].to_owned()
      if j < n && source[j] == '(' {
        // mixin：读参数（@var→$var）
        let (params, after) = read_paren(source, j, n)
        let mut k = after
        while k < n && is_ws(source[k]) {
          k += 1
        }
        if k < n && source[k] == '{' {
          // mixin 定义 → @mixin name($a, ...) {
          sb.write_string("@mixin ")
          sb.write_string(name)
          sb.write_string("(")
          sb.write_string(params)
          sb.write_string(") {")
          i = k + 1
        } else {
          // mixin 调用 → @include name(args)
          sb.write_string("@include ")
          sb.write_string(name)
          sb.write_string("(")
          sb.write_string(params)
          sb.write_string(")")
          i = after
        }
      } else if j < n && source[j] == ';' {
        // 分离调用 .mixin; → @include mixin;
        sb.write_string("@include ")
        sb.write_string(name)
        i = j
      } else {
        // 普通类选择器 .name
        sb.write_string(".")
        sb.write_string(name)
        i = j
      }
    } else {
      sb.write_string(source[i:i + 1].to_owned())
      i += 1
    }
  }
  sb.to_string()
}

///|
/// 读取括号参数到匹配 `)`，参数内 `@name` 转 `$name`；返回 (转后参数, `)` 后下标)
fn read_paren(source : String, open : Int, n : Int) -> (String, Int) {
  let p = StringBuilder()
  let mut depth = 1
  let mut k = open + 1
  while k < n && depth > 0 {
    if source[k] == '(' {
      depth += 1
      p.write_string("(")
      k += 1
    } else if source[k] == ')' {
      depth -= 1
      if depth == 0 {
        k += 1
        break
      }
      p.write_string(")")
      k += 1
    } else if source[k] == '@' {
      let mut m = k + 1
      while m < n && is_ident_char(source[m]) {
        m += 1
      }
      let name = source[k + 1:m].to_owned()
      if is_at_rule_keyword(name) {
        p.write_string("@")
        p.write_string(name)
      } else {
        p.write_string("$")
        p.write_string(name)
      }
      k = m
    } else if source[k] == ';' && depth == 1 {
      // 参数顶层的 `;` 是 less 的参数分隔符 → 转 `,`
      p.write_string(",")
      k += 1
    } else {
      p.write_string(source[k:k + 1].to_owned())
      k += 1
    }
  }
  (p.to_string(), k)
}

///|
/// LESS 引擎：独立解析 + 求值（不复用 SCSS 引擎）
pub fn less_engine() -> @core.Engine {
  @core.Engine::new(
    name=() => "less",
    supports=fmt => fmt is @core.Less,
    compile=source => eval_less(parse_less(@scss.tokenize(source)), None),
    compile_imports=(source, read) => {
      eval_less(parse_less(@scss.tokenize(source)), Some(read))
    },
  )
}

///|
/// 是否为 LESS 保留的 at-rule 关键词（不当作变量）
fn is_at_rule_keyword(name : String) -> Bool {
  match name {
    "media" => true
    "import" => true
    "if" => true
    "for" => true
    "each" => true
    "while" => true
    "font-face" => true
    "supports" => true
    "keyframes" => true
    "charset" => true
    "page" => true
    "namespace" => true
    "document" => true
    "layer" => true
    "container" => true
    "property" => true
    "scope" => true
    "else" => true
    "plugin" => true
    "arguments" => true
    _ => false
  }
}

///|
/// 空白字符
fn is_ws(u : UInt16) -> Bool {
  u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D
}

///|
/// 标识符起始字符
fn is_ident_start(u : UInt16) -> Bool {
  (u >= 'A' && u <= 'Z') || (u >= 'a' && u <= 'z') || u == '_' || u == '-'
}

///|
/// 标识符字符
fn is_ident_char(u : UInt16) -> Bool {
  is_ident_start(u) || (u >= '0' && u <= '9')
}
