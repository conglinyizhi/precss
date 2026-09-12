# conglinyizhi/precss

可插拔的 CSS 预处理器编译门面：把 **SCSS / SASS / LESS / CSS** 源码编译成 CSS。
核心只做「识别格式 → 路由到后端引擎 → 统一错误」，输入可单可多，文件读取由调用方注入（核心零 IO 耦合）。SCSS（含 SASS 缩进语法）、LESS 各有**独立引擎**，CSS 直接透传；随库附带**单一 CLI 可执行**（compile / format / diagnose 等 subcommand）。

入口按场景选：

| 场景 | 用哪个 |
| --- | --- |
| 一段源码，格式自动识别 | `compile` |
| 明确指定格式 | `compile_scss` / `compile_sass` / `compile_less` / `compile_css` |
| 读文件（含 `@import` 内联） | `compile_file` |
| 多段源码 / 文件混用 | `compile_many`（每段按自己的格式走） / `compile_sources` |
| 注入全局变量 | `compile_scss_with_vars` / `compile_sass_with_vars` / `compile_less_with_vars` |

> 自动识别是启发式：没有 `$`、没有 `@` 变量、也没有缩进的源码（比如裸 SCSS 嵌套的 `.a { .b { … } }`）会被当作普通 CSS 原样透传。这类输入请用显式入口（`compile_scss`）。
>
> **编译文件时按扩展名定格式**（`Format::from_path`）：`.scss` / `.sass` / `.less` / `.css`
> 各归各的引擎，认不出扩展名才回退到内容启发式。这条很重要：`.scss` 里的 `@import`
> 是编译期内联，而 `.css` 的 `@import` 要原样留给浏览器——两者都可能一个 `$` 都没有，
> 光看内容分不出来。

> 对外名 `precss`；**import 路径**用下划线 `conglinyizhi/precss`
> （MoonBit 包名含连字符会让 `_test.mbt`/`README` 的 auto-import alias 失效，故标识收成下划线）。

## 安装

```bash
moon add conglinyizhi/precss
```

## 快速开始

```mbt check
///|
test {
  // 自动识别格式编译
  inspect(
    @precss.compile("$c: red; body { color: $c; }"),
    content=(
      #|body {
      #|  color: red;
      #|}
      #|
    ),
  )
}
```

```mbt check
///|
test {
  // SCSS 变量 + 嵌套
  inspect(
    @precss.compile_scss("$gap: 8px; a { margin: $gap; b { padding: $gap; } }"),
    content=(
      #|a {
      #|  margin: 8px;
      #|}
      #|a b {
      #|  padding: 8px;
      #|}
      #|
    ),
  )
}
```

```mbt check
///|
test {
  // LESS：变量 + 类 mixin（含参数默认值）
  inspect(
    @precss.compile_less(".pad(@p: 8px) { padding: @p; }\n.x { .pad(); }"),
    content=(
      #|.x {
      #|  padding: 8px;
      #|}
      #|
    ),
  )
}
```

```mbt check
///|
test {
  // 显式指定为 CSS（透传）
  inspect(
    @precss.compile_css("body { color: red; }"),
    content="body { color: red; }",
  )
}
```

## 多文件 & 灵活输入（`compile_many`）

允许多个文件 / 多段源码 / **混用**，每段**按自己的格式**编译后再拼接，并支持 `@import "path"` 内联。
读取函数由调用方注入（`read : (path) -> String raise CompileError`），核心不耦合具体 IO。

每段的格式来源：`Input::SourceWithFormat` 用显式指定的格式，`Input::File` 按**文件扩展名**
（`Format::from_path`），`Input::Source` 用内容自动识别。要强制某段走哪个引擎，用
`@core.Input::SourceWithFormat(src, @core.Format::Scss)` 这种写法。

```mbt check
///|
test {
  let read = fn(p : String) -> String raise @core.CompileError {
    if p == "a.scss" {
      "$c: blue; .x { color: $c; }"
    } else {
      raise @core.CompileError::EngineFailed(
        engine="test",
        message="missing: " + p,
      )
    }
  }
  inspect(
    @precss.compile_many(
      [
        @core.Input::Source("body { color: red; }"),
        @core.Input::File("a.scss"), // read 读取，内容里的 @import 也会内联
        @core.Input::Source(".y { width: 1px; }"),
      ],
      read,
    ),
    // 每段按自己的格式编译：纯 CSS 段原样透传，含 $ 的段走 SCSS 引擎。
    // 想强制某段的解析方式，用 Input::SourceWithFormat(src, Format::Scss)。
    content=(
      #|body { color: red; }
      #|
      #|.x {
      #|  color: blue;
      #|}
      #|
      #|.y { width: 1px; }
      #|
    ),
  )
}
```

## 门面 API（核心包）

- `compile(source)` — 自动识别格式并编译
- `compile_scss(source)` / `compile_sass(source)` / `compile_less(source)` / `compile_css(source)` — 显式格式
- `compile_scss_with_vars(source, vars)` / `compile_sass_with_vars(source, vars)` / `compile_less_with_vars(source, vars)` — 显式格式 + 预置变量
- `compile_sources(sources)` — 编译多个源码片段，不需要文件读取器
- `compile_input(input)` — 按 `Input` 形态（`Source` / `SourceWithFormat` / `File`）
- `compile_file(path, read)` — 编译单文件（read 注入），格式按**路径扩展名**判定
- `compile_many(inputs, read)` — 编译多个输入（`File`/`Source` 混用），**每段按自己的格式**分别带 `@import` 内联后拼接

统一错误 `@core.CompileError`（`NoEngine` / `EngineFailed` / `UnsupportedSyntax`），所有后端引擎错误都会映射到它。多文件 `@import` 内联在 AST 层递归展开（含嵌套规则/控制流体），调用方 `read` 负责路径解析；循环 import 会被去重。

一个可跑的完整例子（五个场景，输出可直接对照）见 [`example/minimal/`](example/minimal/)：

```bash
moon run example/minimal
```

## 引擎（各自独立，可插拔）

- **`backend/scss`** — SCSS / **SASS（缩进语法）** 引擎，两者共用同一条解析管线：变量+作用域（`!default/!global`）、嵌套、`&`、mixin（默认/变参/`@content`）、`@if/@else if/@while/@for/@each`(多变量)、比较/逻辑运算、`+` 字符串连接、裸括号吸收、选择器/值插值、`@import` 内联、`@media` 透传、`@warn/@debug/@error` 忽略。
  在 `Format` 里 Sass / Scss 是两个标签：`sass_engine` 先把缩进语法经 `sass_to_scss` 规范化成等价 SCSS，再进同一条管线；`scss_engine` 直接解析。这样调用方既可以让 `compile` 自动识别，也可以用 `compile_sass` 显式要求按缩进解析。
- **`backend/less`** — **独立 LESS 引擎**（不复用 SCSS 引擎）：变量 **lazy 作用域**（最后定义优先、可用后定义）、嵌套 `&`、类 mixin（`.name()` 定义 / 调用 / 分离 `.name;` / 参数默认值 / `;` 分隔参数 / **类混入**）、基础运算、`@media` 透传、`@import` 内联、**同名同值重复声明去重**（保留最后一次出现，对齐 less.js）。
- **`backend/css`** — CSS 透传。

> **「可插拔」的边界**：引擎契约就是 `core.Engine`（`supports : Format -> Bool` + `compile` / `compile_imports`），`core.Compiler::new([...])` 接受任意引擎数组——在 **core 层**可以自由替换或新增引擎。根包门面（`compile` 这一组）用的是内置引擎组成的固定组合；要接自己的引擎，直接用 `@core.Compiler::new` 自己拼装，而不是绕门面。

> less 曾用「转换级适配」（`less_to_scss` 转成 scss 再复用 SCSS 引擎），但 less 与 scss 语义独立（lazy 作用域 / 类 mixin / 去重），转换级存在 82% 天花板（深层嵌套/变量作用域必然失配），因此拆为独立引擎。

## 命令行工具（单一可执行 `cmd/cli`）

库独立交付一个 CLI，**stdin 管道友好**：

```bash
moon run cmd/cli -- help             # 用法
moon run cmd/cli -- compile          # 批量编译 SCSS（stdin 以 NUL 分隔输入/输出，差分 harness 协议）
moon run cmd/cli -- compile-less     # 批量编译 LESS（同上）
moon run cmd/cli -- format           # 源码格式化（自动探测糖类型；可 --type/--css）
moon run cmd/cli -- diagnose         # 重复属性检查（自动探测糖类型）
moon run cmd/cli -- bench-library    # 单进程测量纯库编译阶段（--scss/--sass/--less）
moon run cmd/cli -- gen-types        # 从样式源提取 class，生成类型化 .mbt wrapper

cat style.scss | moon run cmd/cli -- compile
echo 'a{color:red;font:bold}' | moon run cmd/cli -- format
```

- **format**：minified → 规范 2 空格缩进源码；`--type <scss|sass|less>` / `--scss/--sass/--less` 强制类型（测探歧义时用）；`--css` 输出编译后 css。less 因无独立源码级 AST，暂转等价 scss 输出。
- **diagnose**：检测同一规则内「同名同值」重复声明（`#.box: duplicate property "width: 16%"`）——LESS 会去重同类重复（保留最后一次），scss 保留但属无意义重复；用于提示用户手写可能预期不符。
- **gen-types**：对应库里的 `generate_types`，从编译后的 CSS 里收集 class，生成每个 class 一个函数的 `.mbt` wrapper，供 rabbita 之类的 TS 式调用场景。
- 管道**无扩展名**，`format`/`diagnose` 靠内容自动探测（缩进→sass、`$`→scss、`@`→less、都没有→scss）；含 `@media` 又无 `$` 的 scss 会被误判 less，用 `--type scss` 纠正。

> CLI 的探测默认落到 scss（它的输入就是待格式化的样式源码），
> 而库的 `Format::detect` 默认落到 CSS（透传）——两者对“既无变量也无缩进”
> 的输入取值不同，这是有意为之：CLI 拿它当糖种选解析器，库拿它当“不需要编译”。

## 性能基准（随机结构压测）

在线结果页：[precss 性能比较](https://conglinyizhi.github.io/precss/benchmark/)

`example/perf/bench.mjs`：从**同一棵确定性随机规则树**发射 SCSS / SASS（缩进）/ LESS 三种等价源码，对比 `precss` native CLI 与 Dart Sass JS API / less.js 的批量编译吞吐量，并**逐份做正确性校验**。只有双方输出归一化后一致的格式才计入性能结论。

```bash
# 构建 native CLI、运行 release profile，并生成 JSON
pnpm run bench:release
```

JSON 会记录提交、profile、精确输入/输出 bytes、采样统计、版本、系统环境、正确性结果和独立资源测量。固定数据集由 `example/perf/datasets/manifest.json` 描述并确定性生成；`release` profile 使用约 1 MiB 总输入，`large`/`stress` profile 用于更大的手动或定时实验。注意：Dart Sass 对比项是 `sass` npm 包的 JavaScript API，不是 Dart Sass 原生 CLI；SASS 项走 `sass_to_scss` 规范化后复用 SCSS 管线，数字里含这段转换开销。性能数字不是对所有项目的固定保证，应该结合输入、版本和运行环境解读。

## 差分测试（质量背书）

- **MoonBit 单元测试**：`moon test --target native`，覆盖核心 API、SCSS 和 LESS 后端。
- **scss / sass**：dart-sass oracle（`scripts/diff.mjs`），用例来自 `test/cases` + 上游 `sass-spec`。
- **less**：less.js oracle（`scripts/less_diff.mjs`），用例来自 `test/less_cases`。

```bash
moon test --target native
node scripts/diff.mjs                            # scss/sass 自带 cases
node scripts/diff.mjs test/sass-spec/spec/variables
node scripts/less_diff.mjs                       # less 自带 cases
```

差分报告见 `docs/spec-gap.md`（通过率、已支持特性、归档的 deep-water）。

## Compiler 全栈嵌合指南

`moonbit-community/rabbita`（MoonBit 函数式 Web UI）+ `hackwaly/moonback`（Express 级后端）是 MoonBit 全栈 SSR 的生态。要在 rabbit 项目里用本库把 SCSS 编译成 CSS：

### 嵌合点

本库是**纯库**（String→String，无 IO）。嵌合发生在 rabbit 项目的**后端/构建期**：给它一个 `read` 从 scss 源码集合读取，`compile_many` 产出 CSS，再挂到静态资源或直接注入。

```mbt nocheck
// 在 rabbit 项目（后端 cmd/server 或独立构建工具）里
let read = fn(p : String) -> String raise @core.CompileError {
  // 从构建期 scss 源码 map 读，或从文件系统读（读文件用 @fs，见下方坑）
  scss_sources.get(p) or raise @core.CompileError::EngineFailed(engine="reader", message="missing: " + p)
}
let css = @precss.compile_many(
  [@core.Input::File("app.scss"),
   @core.Input::File("partials/_button.scss"),
   @core.Input::Source("$z: 10; .top { z-index: $z; }")],
  read,
)
```

静态资源：moonback 用 `@static.new(root="public")` 中间件服务 `public/` 下的 `site.css`；rabbit 页面里用 `<link rel="stylesheet" href="/site.css">`。集成示范见 `rabbit-css-integration`（三格式装载 + rabbit SSR 渲染注入 + moonback `@static` 后端闭环）。

### SSG 静态站点（`site/`，GitHub Pages 免后端）

`site/` 是**独立演示站项目**（rabbit SSG + 自研 tailwind-like，`site/out` 产物）：

```bash
cd site && moon run cmd/ssg   # 读 styles/tailwind.scss → 本库编译出 out/tailwind.css；rabbit 渲染 out/index.html
```

- 组件 `@rabbita.new(fn(){ home_page() })`（闭包捕获）+ `.render(url, timeout)` 产完整 HTML 字符串（含 `<!DOCTYPE>`），直接写盘（SSG = MPA 落地）。
- `site/cmd/ssg` 里 `@fs.read_file` 返回 `&@io.Data`（转 String 用 `data.text()`）；read_file 是 async，helper 用 `async fn`；`@fs.write_file(path, String)` 直接传 String 值；`@fs.mkdir(recursive=true)` 确保目录。
- `site/moon.work` 挂父库用 `..`（嵌套项目）；`moon add <module>@<ver>` 一次一个。

### 关键坑（来自 `clyzhi-moonwell-spring` skill 的一手经验）

- **`#internal(experimental)`**：rabbita 大量 API 标注 experimental，入口加 `#warnings(...)` 压制。
- **native target**：`moon new` 默认 `preferred_target="wasm"`；rabbit 后端/服务端要 `preferred_target="native"` + 依赖 `moonbitlang/async`。
- **core 无文件 IO**：读文件用 `moonbitlang/async/fs`（`@fs.read_file`），但 async trait impl 未稳定——同步 trait 体里调 `@fs` 会被静默丢弃。
- **`MOON_CC`**：native build 需 C 驱动，`MOON_CC=clang MOON_AR=ar MOON_LD=clang moon build --target native`。
- **代理坑**：本地代理会让 `moon`/请求超时——`--noproxy '*'`。
- **static 中间件路径**：`hackwaly/moonback/middlewares/unstable_static`（习惯别名 `@static`）。
- **SSR 无 on_mount**：首屏数据必须在服务端预取后经 input 注入（闭包捕获）；`@rabbita.new(component : () -> Val[Html])` 无参。

## 给 Agent / 开发者的提示（避免痛苦调查）

本项目与 rabbit 全栈都属于 **MoonBit 官方技能未覆盖** 的生态。动手前先读：

- **`~/.pi/agent/skills/external/clyzhi-moonwell-spring/references/rabbita-fullstack.md`** — rabbit + moonback 全栈 SSR 的 API 速查与八大失败经验。
- **同目录 `patches.md`** — 补丁 20（服务端 native/默认 wasm 陷阱）、21（`Show`→`@debug.to_string`/`repr`、`catch`/`<|` 优先级）、22（rabbit 全栈）、23（async trait impl 静默丢弃、core 无文件 IO、`MOON_CC`、`--noproxy`）、24（生态包）。
- 生态包速查在 `references/patches.min.md`。

## 已知限制

- **SCSS 为子集**：`@extend`、完整内置函数（颜色/数学）、`@use/@forward` 模块系统未实现。
- **LESS 持续对齐中**：mixin 守卫 `when`、`@arguments`、更深的 lazy 作用域未实现（现有用例 + 随机构建已对齐，见 diff）。
- 运算对齐到「运算符紧密/连接/裸括号吸收」；剩余 `calc()`/`infinity`/多单位运算属 value 系统深水区。
