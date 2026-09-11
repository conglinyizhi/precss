///|
/// 编译门面：持有若干可插拔引擎
///
/// 门面只负责「识别格式 → 路由到引擎 → 统一错误」，不绑定任何具体预处理引擎。
pub struct Compiler {
  engines : Array[Engine]
}

///|
/// 用一组引擎构造门面
pub fn Compiler::new(engines : Array[Engine]) -> Compiler {
  { engines, }
}

///|
/// 自动识别格式并编译
pub fn Compiler::compile(
  self : Compiler,
  source : String,
) -> String raise CompileError {
  let fmt = Format::detect(source)
  self.compile_with_format(source, fmt)
}

///|
/// 以显式格式编译
pub fn Compiler::compile_with_format(
  self : Compiler,
  source : String,
  fmt : Format,
) -> String raise CompileError {
  let engine = self.pick(fmt)
  engine.compile(source)
}

///|
/// 依据输入形态编译
pub fn Compiler::compile_input(
  self : Compiler,
  input : Input,
) -> String raise CompileError {
  match input {
    Source(source) => self.compile(source)
    SourceWithFormat(source, fmt) => self.compile_with_format(source, fmt)
    File(_) =>
      raise CompileError::EngineFailed(
        engine="compile_input",
        message="File input requires compile_many with a reader",
      )
  }
}

///|
/// 编译多个输入（文件/字符串可混用），逐个编译并拼接
///
/// 每个输入先归一化成源码（`File` 用 `read` 读取，`Source` 直接用），
/// 再交给 SCSS 引擎做 `@import` 内联编译。
pub fn Compiler::compile_many(
  self : Compiler,
  inputs : Array[Input],
  read : (String) -> String raise CompileError,
) -> String raise CompileError {
  let parts : Array[String] = []
  for input in inputs {
    // 每段输入按自己的格式选引擎：SourceWithFormat 用显式格式，
    // File 按扩展名，Source 走内容识别。不能统一挑一个引擎——LESS 源码
    // 交给 SCSS 引擎会产出无意义的结果且不报错。
    let (src, fmt) = match input {
      Source(s) => (s, Format::detect(s))
      SourceWithFormat(s, f) => (s, f)
      File(p) => {
        let s = read(p)
        let f = match Format::from_path(p) {
          Some(f) => f
          None => Format::detect(s)
        }
        (s, f)
      }
    }
    let piece = self.pick(fmt).compile_imports(src, read)
    // 透传的 CSS 段不带结尾换行，编译出来的段带；统一补齐后再拼接，
    // 否则拼接结果的段间空行时有时无。
    parts.push(
      if piece.length() > 0 && !piece.has_suffix("\n") {
        piece + "\n"
      } else {
        piece
      },
    )
  }
  parts.join("\n")
}

///|
/// 编译文件
///
/// 读取函数由调用方注入，核心不耦合具体 IO 后端，跨 target 可用。
pub fn Compiler::compile_file(
  self : Compiler,
  path : String,
  read : (String) -> String raise CompileError,
) -> String raise CompileError {
  let source = read(path)
  // 路径优先：按扩展名定格式，认不出来才回退到内容启发式。
  // 用内容判定会让无变量的 `.scss`（全是 @import 很常见）被当成 CSS 透传，
  // @import 就不内联了。
  // 也必须走 compile_imports 而不是 compile：后者不携带 reader。
  let fmt = match Format::from_path(path) {
    Some(f) => f
    None => Format::detect(source)
  }
  self.pick(fmt).compile_imports(source, read)
}

///|
/// 按格式挑选引擎
fn Compiler::pick(self : Compiler, fmt : Format) -> Engine raise CompileError {
  for e in self.engines {
    if e.supports(fmt) {
      return e
    }
  }
  raise CompileError::NoEngine(fmt)
}
