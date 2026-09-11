///|
/// 统一 CLI：一个可执行 + 多个 subcommand（compile / compile-less / format / help）
///
/// 库（precss）保持纯，这里是独立交付的 CLI 产物。
/// `opts`: 子命令本身逻辑
async fn main {
  let args = @env.args()
  let sub = if args.length() > 1 { args[1] } else { "help" }
  match sub {
    "compile" => run_compile(args)
    "compile-less" => run_compile_less(args)
    "bench-library" => run_bench_library(args)
    "format" => run_format(args)
    "diagnose" => run_diagnose()
    "gen-types" => run_gen_types()
    "help" | "-h" | "--help" => print_help()
    _ => {
      println("unknown subcommand: \{sub}\n")
      print_help()
    }
  }
}

///|
fn print_help() -> Unit {
  println("precss CLI")
  println("")
  println("用法：moon run cmd/cli -- <subcommand>")
  println("")
  println("subcommands:")
  println(
    "  compile        批量编译 SCSS（stdin 以 NUL 分隔输入，NUL 分隔输出；差分 harness 协议）",
  )
  println("  compile-less   批量编译 LESS（同上）")
  println(
    "  bench-library  单进程测量纯库编译阶段（支持 --scss/--sass/--less）",
  )
  println(
    "  format         格式化源码（stdin 输入，输出规范排版的 scss）",
  )
  println(
    "  diagnose       检测重复属性（stdin 输入，打印警告；无则提示）",
  )
  println(
    "  gen-types      从样式源提取 class，生成类型化 .mbt wrapper",
  )
  println("  help           显示本帮助")
}

///|
/// 读全部 stdin
async fn read_stdin_all() -> String {
  let sb = StringBuilder()
  while true {
    match @stdio.stdin.read_until("\n") {
      Some(line) => {
        sb.write_string(line)
        sb.write_string("\n")
      }
      None => break
    }
  }
  sb.to_string()
}

///|
/// 读批量协议：stdin 以 NUL 分隔多份输入（compile / compile-less）
///
/// 按 NUL 分块读，而不是逐行 `read_until("\n")` 再拼回去。
/// `read_until` 每返回一段都要做一次 utf8 解码，逐行读一份 1 MiB 输入
/// 会产生上万次分配——批量编译的主要开销就在这里，与编译本身无关。
async fn read_stdin_cases() -> Array[String] {
  let parts : Array[String] = []
  while true {
    match @stdio.stdin.read_until("\u0000") {
      Some(chunk) => parts.push(chunk)
      None => break
    }
  }
  parts
}

///|
/// compile：stdin 以 NUL 分隔多个 SCSS，逐一编译，NUL 分隔输出，失败输出 MB_ERROR
async fn run_compile(args : Array[String]) -> Unit {
  let (vars, minify) = compile_flags(args)
  let cases = read_stdin_cases() catch {
    e => {
      println("MB_ERROR: read \{e}")
      return
    }
  }
  emit_batch(cases, fn(src : String) -> String {
    let css = @mb.compile_scss_with_vars(src, vars) catch {
      e => "MB_ERROR: \{e}"
    }
    if minify {
      @mb.minify_css(css)
    } else {
      css
    }
  })
}

///|
/// compile-less：同 compile，但走 LESS 引擎
async fn run_compile_less(args : Array[String]) -> Unit {
  let (vars, minify) = compile_flags(args)
  let prefix = less_prefix(vars)
  let cases = read_stdin_cases() catch {
    e => {
      println("MB_ERROR: read \{e}")
      return
    }
  }
  emit_batch(cases, fn(src : String) -> String {
    let css = @mb.compile_less(prefix + src) catch { e => "MB_ERROR: \{e}" }
    if minify {
      @mb.minify_css(css)
    } else {
      css
    }
  })
}

///|
/// 把 NUL 分隔的一批源喂给编译函数，NUL 分隔回写
fn emit_batch(cases : Array[String], compile : (String) -> String) -> Unit {
  let results : Array[String] = []
  for c in cases {
    if c.trim().length() == 0 {
      continue
    }
    results.push(compile(c))
  }
  println(results.join("\u0000"))
}

///|
/// 依内容特征判断糖种：sass(缩进) > scss($) > less(@) > scss
fn detect_type(src : String) -> String {
  if @scss.is_sass_indent(src) {
    return "sass"
  }
  if src.contains("$") {
    return "scss"
  }
  if src.contains("@") {
    return "less"
  }
  "scss"
}

///|
/// 在同一个 native 进程内测量编译阶段，排除 CLI 启动与 stdin/stdout 往返
async fn run_bench_library(args : Array[String]) -> Unit {
  let whole = read_stdin_all() catch {
    e => {
      println("MB_ERROR: read \{e}")
      return
    }
  }
  let less = args.contains("--less")
  let sass = args.contains("--sass")
  let sources = whole
    .split("\u0000")
    .filter(fn(s) { s.trim().length() > 0 })
    .map(fn(s) { s.to_owned() })
    .to_array()
  let start = @bench.monotonic_clock_start()
  let outputs : Array[String] = []
  for source in sources {
    let css = try {
      if less {
        @mb.compile_less(source)
      } else if sass {
        @mb.compile_scss(@scss.sass_to_scss(source))
      } else {
        @mb.compile_scss(source)
      }
    } catch {
      e => "MB_ERROR: \{e}"
    }
    outputs.push(css)
  }
  let elapsed_us = @bench.monotonic_clock_end(start)
  let output_bytes = outputs.fold(init=0, fn(total, css) {
    total + css.length()
  })
  let syntax = if less { "less" } else if sass { "sass" } else { "scss" }
  println(
    "BENCH_LIBRARY_JSON:{\"syntax\":\"\{syntax}\",\"sources\":\{sources.length()},\"elapsed_us\":\{elapsed_us},\"output_bytes\":\{output_bytes}}",
  )
}

///|
/// format：stdin 输入源码，输出规范化排版；默认自动探测糖类型
///
/// flags（可选，偷懒时可全省略）：
///   --type <scss|sass|less>  显式指定类型
///   --scss / --sass / --less 快捷指定
///   --css                   输出编译后的 css（而非规范化源码）
async fn run_format(args : Array[String]) -> Unit {
  let mut out_css = false
  let mut forced_type : String? = None
  let mut i = 2
  while i < args.length() {
    match args[i] {
      "--css" => out_css = true
      "--type" =>
        if i + 1 < args.length() {
          forced_type = Some(args[i + 1])
          i += 1
        }
      "--scss" => forced_type = Some("scss")
      "--sass" => forced_type = Some("sass")
      "--less" => forced_type = Some("less")
      "-h" | "--help" => {
        print_format_help()
        return
      }
      _ => ()
    }
    i += 1
  }
  let src = read_stdin_all() catch {
    e => {
      println("ERR: read \{e}")
      return
    }
  }
  // 类型：显式指定 > 自动探测（偷懒默认）
  let kind = match forced_type {
    Some(t) => t
    None => detect_type(src)
  }
  if out_css {
    // 输出编译后的 css（所有糖都归一）
    let css : String = if kind == "less" {
      @mb.compile_less(src) catch {
        e => "/* 编译失败: \{repr(e)} */"
      }
    } else {
      @mb.compile_scss(src) catch {
        e => "/* 编译失败: \{repr(e)} */"
      }
    }
    println(css.trim())
  } else {
    // 输出规范化源码
    let formatted : String = if kind == "sass" {
      @scss.format_scss(@scss.sass_to_scss(src))
    } else if kind == "less" {
      let scss_src = @less.less_to_scss(src)
      @scss.format_scss(scss_src)
    } else {
      @scss.format_scss(src)
    }
    println(formatted.trim())
  }
}

///|
fn print_format_help() -> Unit {
  println("format [flags]")
  println(
    "  输入：stdin 源码；默认自动探测糖类型，输出规范化 scss",
  )
  println("  --type <scss|sass|less>  显式指定类型")
  println("  --scss / --sass / --less 快捷指定")
  println("  --css                   输出编译后的 css")
}

///|
/// 提取样式源里的 class 并生成类型化 wrapper（`pub fn xxx() -> String`）
///
/// 用法：cat tailwind.scss | moon run cmd/cli -- gen-types > tw.mbt
/// 也可把生成结果放入某个包，组件里 `@tw.text_red_500()` 即带编辑器补全+编译校验。
async fn run_gen_types() -> Unit {
  let src = read_stdin_all() catch {
    e => {
      println("ERR: read \{e}")
      return
    }
  }
  println(@mb.generate_types(src))
}

///|
/// 检测重复属性（同名同值），打印警告；sass 先转 scss
async fn run_diagnose() -> Unit {
  let src = read_stdin_all() catch {
    e => {
      println("ERR: read \{e}")
      return
    }
  }
  let kind = detect_type(src)
  let warns = if kind == "sass" {
    @scss.diagnose_scss(@scss.sass_to_scss(src))
  } else if kind == "less" {
    @less.diagnose_less(src)
  } else {
    @scss.diagnose_scss(src)
  }
  if warns.length() == 0 {
    println("(no duplicate property warnings)")
  } else {
    for w in warns {
      println(w)
    }
  }
}

///|
/// 解析 compile 的 --vars <file> 与 --minify 选项，返回 (变量表, 是否压缩)
async fn compile_flags(args : Array[String]) -> (Map[String, String], Bool) {
  let mut vars_file = ""
  let mut minify = false
  let mut i = 2
  while i < args.length() {
    match args[i] {
      "--vars" =>
        if i + 1 < args.length() {
          vars_file = args[i + 1]
          i += 1
        }
      "--minify" => minify = true
      _ => ()
    }
    i += 1
  }
  let vars : Map[String, String] = if vars_file.length() > 0 {
    read_vars(vars_file) catch {
      _ => Map([])
    }
  } else {
    Map([])
  }
  (vars, minify)
}

///|
/// less 变量前缀（@name: value;）
fn less_prefix(vars : Map[String, String]) -> String {
  let sb = StringBuilder()
  vars.each(fn(k, v) {
    sb.write_string("@")
    sb.write_string(k)
    sb.write_string(": ")
    sb.write_string(v)
    sb.write_string(";\n")
  })
  sb.to_string()
}

///|
/// 按扩展名读 json/toml 键值对为变量表（.toml 走 TOML，其余走 JSON）
async fn read_vars(file : String) -> Map[String, String] {
  let content = read_file_text(file) catch { _ => "" }
  if file.has_suffix(".toml") {
    toml_to_vars(content)
  } else {
    json_to_vars(content)
  }
}

///|
async fn read_file_text(path : String) -> String {
  let data = @fs.read_file(path) catch { _ => "" }
  data.text() catch {
    _ => ""
  }
}

///|
/// json {"c":"10px"} → 变量表；只取 Object 顶层的字符串值
fn json_to_vars(content : String) -> Map[String, String] {
  let vars : Map[String, String] = Map([])
  try {
    let j = @json.parse(content)
    match j {
      Json::Object(obj) =>
        obj.each(fn(k, v) { if v is Json::String(s) { vars[k] = s } })
      _ => ()
    }
  } catch {
    _ => ()
  }
  vars
}

///|
/// toml 顶层 k = "v" 键值 → 变量表
fn toml_to_vars(content : String) -> Map[String, String] {
  let vars : Map[String, String] = Map([])
  try {
    match @toml.parse(content) {
      @toml.TomlValue::TomlTable(map) =>
        map.each(fn(k, v) {
          let sv = match v {
            @toml.TomlValue::TomlString(s) => s
            @toml.TomlValue::TomlInteger(i) => i.to_string()
            @toml.TomlValue::TomlFloat(f) => f.to_string()
            @toml.TomlValue::TomlBoolean(b) => b.to_string()
            _ => ""
          }
          vars[k] = sv
        })
      _ => ()
    }
  } catch {
    _ => ()
  }
  vars
}
