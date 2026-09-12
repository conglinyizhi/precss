///| SSG：把库编译的样式 + rabbit 渲染的 深色 landing landing 页写成静态 HTML（GitHub Pages 免后端）。
///
/// 流程：
///   styles/tailwind.scss → 本库 compile_scss → out/tailwind.css（自研 tailwind-like）
///   styles/site.scss      → 本库 compile_scss → out/site.css    （深色 landing landing 样式）
///   rabbit 渲染 home_page → out/index.html（深色 + 黄标题 + 双栏实时编译）
///
/// PRECSS_SITE_OUT=public 可供 Warren 开发服务器写入独立的临时静态目录。
///
#warnings("-alert_experimental")
async fn main {
  // 1) 编译 tailwind.scss -> out/tailwind.css
  let tw_scss = try read_text("styles/tailwind.scss") catch { _ => "" }
  let tw_css = try @css.compile_scss(tw_scss) catch { _ => "" }
  // 2) 编译 site.scss -> out/site.css（深色 landing）
  let site_scss = try read_text("styles/site.scss") catch { _ => "" }
  let site_css = try @css.compile_scss(site_scss) catch { _ => "" }
  let output_dir = @env.get_env_var("PRECSS_SITE_OUT").unwrap_or("out")
  let output = (name : String) => output_dir + "/" + name
  try @fs.mkdir(output_dir, recursive = true) catch { _ => () }
  try @fs.write_file(output("tailwind.css"), tw_css) catch { _ => () }
  try @fs.write_file(output("site.css"), site_css) catch { _ => () }

  // 复制前端逻辑（CodeMirror 初始化 + 实时编译）到 out/demo.js
  let demo = try read_text("static/demo.js") catch { _ => "" }
  try @fs.write_file(output("demo.js"), demo) catch { _ => () }

  // 本地打包 CodeMirror 5（不依赖运行时 CDN）——复制到 out/codemirror/
  //
  // 这份资源不入库（构建期由 scripts/vendor-codemirror.mjs 从 npm 取），
  // 而 copy_file 是容错的：缺了只会静默产出一个排版崩掉的页面。
  // 所以先显式校验四个必需文件，缺一个就直接失败。
  require_file("static/codemirror/lib/codemirror.js")
  require_file("static/codemirror/lib/codemirror.css")
  require_file("static/codemirror/mode/css/css.js")
  require_file("static/codemirror/theme/dracula.css")
  copy_file("static/codemirror/lib/codemirror.js", output("codemirror/lib/codemirror.js"))
  copy_file("static/codemirror/lib/codemirror.css", output("codemirror/lib/codemirror.css"))
  copy_file("static/codemirror/mode/css/css.js", output("codemirror/mode/css/css.js"))
  copy_file("static/codemirror/theme/dracula.css", output("codemirror/theme/dracula.css"))

  // 3) 复制性能页前端、首页性能摘要与 CI 生成的 JSON 数据
  copy_file("static/benchmark.js", output("benchmark/benchmark.js"))
  copy_file("static/home.js", output("home.js"))
  copy_file("static/data/benchmark.json", output("data/benchmark.json"))
  copy_file("static/data/benchmark-lite.json", output("data/benchmark-lite.json"))

  // 4) 渲染首页与性能页 -> out（rabbit SSR）
  let home = @rabbita.new(fn() { home_page() })
  let home_html = try home.render(url="http://127.0.0.1/", timeout=5000) catch {
    _ => "<!DOCTYPE html><html><body>render error</body></html>"
  }
  let benchmark = @rabbita.new(fn() { benchmark_page() })
  let benchmark_html = try benchmark.render(url="http://127.0.0.1/benchmark/", timeout=5000) catch {
    _ => "<!DOCTYPE html><html><body>render error</body></html>"
  }
  let getting_started = @rabbita.new(fn() { getting_started_page() })
  let getting_started_html = try getting_started.render(url="http://127.0.0.1/getting-started/", timeout=5000) catch {
    _ => "<!DOCTYPE html><html><body>render error</body></html>"
  }
  // rabbit SSR 的 <head> 默认不带 charset，补一个避免中文/特殊字符按默认编码乱码
  let home_with_cs = home_html.replace(old="<head>", new="<head><meta charset=\"utf-8\">")
  let benchmark_with_cs = benchmark_html.replace(old="<head>", new="<head><meta charset=\"utf-8\">")
  let getting_started_with_cs = getting_started_html.replace(old="<head>", new="<head><meta charset=\"utf-8\">")
  try @fs.write_file(output("index.html"), home_with_cs) catch { _ => () }
  try @fs.mkdir(output("benchmark"), recursive = true) catch { _ => () }
  try @fs.write_file(output("benchmark/index.html"), benchmark_with_cs) catch { _ => () }
  try @fs.mkdir(output("getting-started"), recursive = true) catch { _ => () }
  try @fs.write_file(output("getting-started/index.html"), getting_started_with_cs) catch { _ => () }
}

///| 读文件为 utf8 文本（SSG 容错：失败返回空串）
async fn read_text(path : String) -> String {
  let data = try @fs.read_file(path) catch {
    _ => raise @core.CompileError::EngineFailed(engine="ssg", message="read fail: " + path)
  }
  try { data.text() } catch { _ => "" }
}

///| 复制文本文件到 out（自动建父目录，容错）
async fn copy_file(src : String, dst : String) -> Unit {
  let txt = try read_text(src) catch { _ => "" }
  if txt.length() > 0 {
    let dir = dir_of(dst)
    try @fs.mkdir(dir, recursive = true) catch { _ => () }
    try @fs.write_file(dst, txt) catch { _ => () }
  }
}

///| 必需静态资源的存在性校验：缺了就报错
///
/// `copy_file` 为容错设计（读不到就静默跳过），对「构建期生成、不入库」的
/// 资源就成了静默失败点，所以这类文件先过一道 `require_file`。
async fn require_file(path : String) -> Unit raise @core.CompileError {
  let txt = try read_text(path) catch {
    _ =>
      raise @core.CompileError::EngineFailed(
        engine="ssg",
        message="缺少静态资源 " + path + "；先跑 `pnpm run vendor:codemirror`",
      )
  }
  if txt.length() == 0 {
    raise @core.CompileError::EngineFailed(
      engine="ssg",
      message="静态资源为空 " + path,
    )
  }
}

///| 取路径的父目录（去最后一个 / 之后的部分）
fn dir_of(p : String) -> String {
  let n = p.length()
  let mut i = n - 1
  while i >= 0 && p[i] != '/' {
    i -= 1
  }
  if i < 0 {
    "."
  } else {
    p[0:i].to_owned()
  }
}
