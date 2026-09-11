///|
/// 预处理引擎句柄
///
/// 每个后端构造一个 `Engine`，用函数闭包承载其行为。这是「可插拔契约」的载体：
/// 门面 `Compiler` 只依赖 `Engine` 的 `supports` / `compile`，不关心是哪个后端。
pub struct Engine {
  name_fn : () -> String
  supports_fn : (Format) -> Bool
  compile_fn : (String) -> String raise CompileError
  compile_imports_fn : (String, (String) -> String raise CompileError) -> String raise CompileError
}

///|
/// 构造一个引擎
///
/// 三个回调分别返回引擎名、是否负责某格式、以及把源码编译为 CSS。
pub fn Engine::new(
  name~ : () -> String,
  supports~ : (Format) -> Bool,
  compile~ : (String) -> String raise CompileError,
  compile_imports~ : (String, (String) -> String raise CompileError) -> String raise CompileError,
) -> Engine {
  {
    name_fn: name,
    supports_fn: supports,
    compile_fn: compile,
    compile_imports_fn: compile_imports,
  }
}

///|
/// 引擎名
pub fn Engine::engine_name(self : Engine) -> String {
  (self.name_fn)()
}

///|
/// 是否负责某格式
pub fn Engine::supports(self : Engine, fmt : Format) -> Bool {
  (self.supports_fn)(fmt)
}

///|
/// 把源码编译为 CSS
pub fn Engine::compile(
  self : Engine,
  source : String,
) -> String raise CompileError {
  (self.compile_fn)(source)
}

///|
/// 带 @import 内联地编译
pub fn Engine::compile_imports(
  self : Engine,
  source : String,
  read : (String) -> String raise CompileError,
) -> String raise CompileError {
  (self.compile_imports_fn)(source, read)
}

///|

///|
/// 统一的编译错误
///
/// 把各个后端引擎的错误统一成一种 `CompileError`，让调用方只需处理它。
pub(all) suberror CompileError {
  /// 没有任何引擎负责该格式
  NoEngine(Format)
  /// 引擎在编译过程中失败
  EngineFailed(engine~ : String, message~ : String)
  /// 语法尚未支持（如 sass 缩进语法）
  UnsupportedSyntax(String)
} derive(Debug)

///|
pub extend CompileError with @debug.Debug::{to_repr}

///|
pub extend CompileError with Show::{to_string, output}

///|
pub impl Show for CompileError with fn to_string(self) {
  match self {
    NoEngine(fmt) => "no engine for format \{fmt}"
    EngineFailed(engine~, message~) => "\{engine} failed: \{message}"
    UnsupportedSyntax(feature) => "unsupported syntax: \{feature}"
  }
}

///|

///|
/// 支持的 CSS 预处理格式
///
/// 分发给后端引擎的格式标签。
pub(all) enum Format {
  /// SASS 缩进语法（无花括号，靠缩进表达嵌套）
  Sass
  Scss
  Less
  Css
} derive(Debug, Eq)

///|
pub extend Format with @debug.Debug::{to_repr}

///|
pub extend Format with Eq::{equal, not_equal}

///|
pub extend Format with Show::{to_string, output}

///|
/// 启发式自动识别源码格式
///
/// 优先判 SASS 缩进语法（有行首缩进且全文无 `{}`），其次判 SCSS
/// （含 `$` 变量或 Sass 控制指令），再判 LESS（`@name :` 变量定义），
/// 否则当作普通 CSS。
///
/// 缩进判定必须排在最前：`.box\n  color: red` 这类纯缩进源码既没有 `$`
/// 也没有花括号，若先判 SCSS/LESS 都会落到 CSS 而被当作普通 CSS 透传。
pub fn Format::detect(source : String) -> Format {
  if Format::looks_sass_indent(source) {
    return Sass
  }
  if Format::looks_scss(source) {
    return Scss
  }
  if Format::looks_less(source) {
    return Less
  }
  Css
}

///|
/// 是否像 SASS 缩进语法：全文不含 `{}`，且存在行首缩进
///
/// 这是唯一的一处缩进判定实现，`backend/scss` 的 `is_sass_indent` 委托到这里。
pub fn Format::looks_sass_indent(source : String) -> Bool {
  let mut line_start = true
  for c in source {
    if c == '{' || c == '}' {
      return false
    }
    if line_start && (c == ' ' || c == '\t') {
      return true
    }
    line_start = c == '\n'
  }
  false
}

///|
/// 按文件路径的扩展名判断格式；认不出来时返回 `None`
///
/// 编译**文件**时优先用它，而不是用内容启发式：`.scss` 里的 `@import`
/// 要在编译期内联，而 `.css` 的 `@import` 应该原样留给浏览器——
/// 只看内容的话，两者的区别（一个 `$` 变量都没有）是分不出来的。
pub fn Format::from_path(path : String) -> Format? {
  if path.has_suffix(".scss") {
    Some(Scss)
  } else if path.has_suffix(".sass") {
    Some(Sass)
  } else if path.has_suffix(".less") {
    Some(Less)
  } else if path.has_suffix(".css") {
    Some(Css)
  } else {
    None
  }
}

///|
fn Format::looks_scss(source : String) -> Bool {
  if source.contains("$") {
    return true
  }
  let controls = [
    "@mixin", "@include", "@each", "@for", "@extend", "@function", "@use", "@forward",
    "@while", "@at-root", "@if", "@else", "@return", "@debug", "@warn", "@error",
    "@content",
  ]
  for k in controls {
    if source.contains(k) {
      return true
    }
  }
  false
}

///|
/// 判断是否存在 LESS 变量定义（`@name : expr`）
fn Format::looks_less(source : String) -> Bool {
  let n = source.length()
  let mut i = 0
  while i < n {
    if source[i] == '@' {
      if is_less_variable_at(source, i) {
        return true
      }
    }
    i += 1
  }
  false
}

///|
/// 判断 `source[i]`（为 `@`）处是否为 LESS 变量定义
fn is_less_variable_at(source : String, i : Int) -> Bool {
  let n = source.length()
  let mut j = i + 1
  if j >= n || !is_ident_start(source[j]) {
    return false
  }
  while j < n && is_ident_char(source[j]) {
    j += 1
  }
  let mut k = j
  while k < n && source[k] == ' ' {
    k += 1
  }
  k < n && source[k] == ':'
}

///|
fn is_ident_start(u : UInt16) -> Bool {
  (u >= 'A' && u <= 'Z') || (u >= 'a' && u <= 'z') || u == '_' || u == '-'
}

///|
fn is_ident_char(u : UInt16) -> Bool {
  is_ident_start(u) || (u >= '0' && u <= '9')
}

///|
pub impl Show for Format with fn to_string(self) {
  match self {
    Sass => "sass"
    Scss => "scss"
    Less => "less"
    Css => "css"
  }
}

///|

///|
/// 编译入口的输入形态
///
/// 传给 `compile_input` 的输入，决定格式如何解析。
pub(all) enum Input {
  /// 源码正文，格式走自动识别
  Source(String)
  /// 源码正文 + 显式指定格式
  SourceWithFormat(String, Format)
  /// 文件路径（用注入 reader 读取）
  File(String)
} derive(Debug, Eq)

///|
pub extend Input with @debug.Debug::{to_repr}

///|
pub extend Input with Eq::{equal, not_equal}
