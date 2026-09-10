///|
/// 开箱即用的 CSS 编译门面
///
/// 注册全部内置后端引擎，提供一个无需手动拼装的 `compile` 入口。
///
/// # Example
/// ```mbt check
/// test {
///   inspect(compile("body { color: red; }"), content="body { color: red; }")
/// }
/// ```
pub fn compile(source : String) -> String raise @core.CompileError {
  default().compile(source)
}

///|
/// 以显式格式编译
pub fn compile_with_format(
  source : String,
  fmt : @core.Format,
) -> String raise @core.CompileError {
  default().compile_with_format(source, fmt)
}

///|
/// 依据输入形态编译
pub fn compile_input(input : @core.Input) -> String raise @core.CompileError {
  default().compile_input(input)
}

///|
/// 编译文件（读取函数由调用方注入）
pub fn compile_file(
  path : String,
  read : (String) -> String raise @core.CompileError,
) -> String raise @core.CompileError {
  default().compile_file(path, read)
}

///|
/// 以显式 SCSS 格式编译
pub fn compile_scss(source : String) -> String raise @core.CompileError {
  default().compile_with_format(source, @core.Scss)
}

///|
/// 以显式 SCSS 格式编译，并注入一组预置全局变量
///
/// 用法：源码里可能有未定义的 `$c`，这里传入 `{c: "10px"}`，
/// 等价于在源码前先写上 `$c: 10px;`（预置全局变量）。
/// 源码中若再次定义同名变量，会按 SCSS 的覆盖规则生效。
/// 例如 `compile_scss_with_vars("body { color: $c; }", {c:"red"})` → `body { color: red; }`
pub fn compile_scss_with_vars(
  source : String,
  vars : Map[String, String],
) -> String raise @core.CompileError {
  compile_prefixed_vars(source, vars, prefix="$", compile_scss)
}

///|
/// 以显式 LESS 格式编译，并注入一组预置全局变量
pub fn compile_less_with_vars(
  source : String,
  vars : Map[String, String],
) -> String raise @core.CompileError {
  compile_prefixed_vars(source, vars, prefix="@", compile_less)
}

///| 编译多个源码片段并拼接结果

///|

///|
/// 这是不需要文件读取器的轻量入口；涉及 `@import` 或文件路径时使用 `compile_many`。
pub fn compile_sources(
  sources : Array[String],
) -> String raise @core.CompileError {
  sources.map(source => compile(source)).join("\n")
}

///|
fn compile_prefixed_vars(
  source : String,
  vars : Map[String, String],
  prefix~ : String,
  compile : (String) -> String raise @core.CompileError,
) -> String raise @core.CompileError {
  let sb = StringBuilder()
  vars.each(fn(k, v) {
    sb.write_string(prefix)
    sb.write_string(k)
    sb.write_string(": ")
    sb.write_string(v)
    sb.write_string(";\n")
  })
  compile(sb.to_string() + source)
}

///|
/// 保守压缩 CSS：去块注释、多余空白与换行；**字符串值内的内容原样保留**
///
/// 用于生成 `.min.css`。只做安全替换（空白/换行/符号前空格/注释），
/// 不删可省略的末尾分号，也不做选择器合并等激进优化。
pub fn minify_css(css : String) -> String {
  let sb = StringBuilder()
  let n = css.length()
  let mut i = 0
  let mut need_space = false
  let mut has_written = false
  let mut last_was_punct = false
  while i < n {
    let c : UInt16 = css[i]
    // 空白折叠：只在“上一个是非符号 token”时补一个空格（符号两侧的空白都去）
    if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
      need_space = has_written && last_was_punct == false
      i += 1
      continue
    }
    // 跳过块注释 /* ... */（保留注释前的空白状态，避免 a /*x*/ b 压成 ab）
    if c == 0x2F && i + 1 < n && css[i + 1] == 0x2A {
      let mut j = i + 2
      while j + 1 < n && (css[j] != 0x2A || css[j + 1] != 0x2F) {
        j += 1
      }
      i = if j + 1 < n { j + 2 } else { n }
      continue
    }
    // 字符串原样复制（含内部空白），防止损坏值
    if c == 0x22 || c == 0x27 {
      let q = c
      write_cs(sb, q)
      i += 1
      while i < n {
        let ch = css[i]
        write_cs(sb, ch)
        i += 1
        if ch == 0x5C && i < n {
          write_cs(sb, css[i])
          i += 1
          continue
        }
        if ch == q {
          break
        }
      }
      need_space = false
      has_written = true
      last_was_punct = false
      continue
    }
    if is_css_punct(c) {
      write_cs(sb, c)
      last_was_punct = true
    } else {
      if need_space {
        sb.write_string(" ")
      }
      write_cs(sb, c)
      last_was_punct = false
    }
    need_space = false
    has_written = true
    i += 1
  }
  sb.to_string()
}

///|
/// CSS 里符号前（及相邻）可安全去空格的字符
fn is_css_punct(c : UInt16) -> Bool {
  c == 0x7B || c == 0x7D || c == 0x3B || c == 0x3A || c == 0x2C || c == 0x3E
}

///|
/// 把 UTF-16 code unit 写入 StringBuilder
fn write_cs(sb : StringBuilder, c : UInt16) -> Unit {
  sb.write_char(Int::unsafe_to_char(c.to_int()))
}

///|
/// 以显式 LESS 格式编译
pub fn compile_less(source : String) -> String raise @core.CompileError {
  default().compile_with_format(source, @core.Less)
}

///|
/// 以显式 CSS 格式编译
pub fn compile_css(source : String) -> String raise @core.CompileError {
  default().compile_with_format(source, @core.Css)
}

///|
/// 编译多个输入（文件/字符串混用），带 @import 内联
pub fn compile_many(
  inputs : Array[@core.Input],
  read : (String) -> String raise @core.CompileError,
) -> String raise @core.CompileError {
  default().compile_many(inputs, read)
}

///|
/// 内置引擎组成的默认门面
fn default() -> @core.Compiler {
  @core.Compiler::new([
    @css.css_engine(),
    @scss.scss_engine(),
    @less.less_engine(),
  ])
}
