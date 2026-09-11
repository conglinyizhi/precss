///|
/// precss 最小集成范例
///
/// 运行：`moon run example/minimal`
///
/// 覆盖把一个 CSS 预处理器接进构建流程最常用的几件事：
/// 编译字符串、注入全局变量、读文件（注入 reader）、处理编译错误。
///
/// 所有编译入口都带 `raise @core.CompileError`——调用方必须显式处理，
/// 这里演示两种粒度：整体兜底（`main`）和单份降级（`demo_error`）。

///|
/// 1. 自动识别格式。SCSS 变量 + 嵌套是最常见的输入。
fn demo_auto_detect() -> Unit raise @core.CompileError {
  println("--- 1. compile：自动识别 ---")
  println(@precss.compile("$c: red;\nbody { color: $c; }"))
}

///|
/// 2. 拿不准格式时点名走哪个引擎。
///
/// 自动识别是启发式的：既没有 `$`、也没有缩进的输入（比如裸的 SCSS 嵌套）
/// 会被当作普通 CSS 原样透传。这时用显式入口。
fn demo_explicit() -> Unit raise @core.CompileError {
  println("--- 2. 显式格式入口 ---")
  println(@precss.compile_scss(".a { .b { color: red; } }"))
  println(@precss.compile_sass(".box\n  color: red\n"))
  println(
    @precss.compile_less(".pad(@p: 8px) { padding: @p; }\n.x { .pad(); }"),
  )
}

///|
/// 3. 构建期决定的值（主题色、基准间距）从外部注入，不必写死在样式源码里。
fn demo_inject_vars() -> Unit raise @core.CompileError {
  println("--- 3. 注入全局变量 ---")
  let vars : Map[String, String] = Map([("brand", "#0a7")])
  println(
    @precss.compile_scss_with_vars(
      ".btn { color: $brand; border: 1px solid $brand; }", vars,
    ),
  )
}

///|
/// 4. 核心零 IO：文件读取由调用方注入。
///
/// 这里用内存表模拟文件系统，真实项目换成 `@fs` / `@async/fs` 即可。
/// `@import` 的路径会**原样**交给这个 reader（库不做 `_partial.scss` /
/// 扩展名补全之类的解析，那是打包器的策略），同一个 reader 递归内联。
fn demo_files() -> Unit raise @core.CompileError {
  println("--- 4. 注入 reader 读文件 ---")
  let files : Map[String, String] = Map([
    ("theme.scss", "$gap: 8px;\n$fg: #333;"),
    ("main.scss", "@import \"theme.scss\";\nbody { margin: $gap; color: $fg; }"),
  ])
  let read = fn(path : String) -> String raise @core.CompileError {
    match files.get(path) {
      Some(s) => s
      None =>
        raise @core.CompileError::EngineFailed(
          engine="reader",
          message="no such file: " + path,
        )
    }
  }
  println(@precss.compile_file("main.scss", read))
}

///|
/// 5. 单份降级：一份样式编译失败，不该拖垮整轮构建。
///
/// 这类处理做在调用点上，所以这个函数自己 catch，不带 raise。
///
/// 两个引擎的严格度不一样：LESS 对**未定义 mixin** 会报错，而 SCSS 引擎
/// 对未定义变量 / 未闭合块是宽容的（原样输出或输出为空，不报错），LESS 对
/// 未定义变量也不报。别指望编译器把这类错都抬住。
fn demo_error() -> Unit {
  println("--- 5. 错误处理（单份降级）---")
  let css = @precss.compile_less(".a { .no_such_mixin(); }") catch {
    e => "（这一份编译失败，已跳过：" + e.to_string() + "）"
  }
  println(css)
}

///|
fn main {
  // 整体兜底：任何一份冒泡上来都会在这里被接住
  let run_all = fn() -> Unit raise @core.CompileError {
    demo_auto_detect()
    demo_explicit()
    demo_inject_vars()
    demo_files()
    demo_error()
  }
  run_all() catch {
    e => println("编译失败：" + e.to_string())
  }
}
