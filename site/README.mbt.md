# precss 范例展示站（`site/`）

用 **rabbita（SSR）** + **自研 tailwind-like（我们的库写）** + **`@css.generate_types`（类型化 wrapper）** 搭建的演示站。展示：
- 用 `precss` 编译 SCSS（自研 tailwind-like）
- 用 `@css.generate_types` 从**你自己的样式源**生成**类型化 API**（编辑器智能提示 + 编译校验）
- 用 rabbita 做 SSR 渲染成静态 HTML（GitHub Pages 免后端）

## 目录

```
site/
├── styles/tailwind.scss   # 自研 minimal tailwind-like（@each 生成 utility）
├── tw/tw.mbt              # ★ 由 gen-types 生成的类型化 wrapper（每个 class 一个 pub fn）
├── cmd/ssg/               # SSG：编译 tailwind → out/tailwind.css；rabbit 渲染 out/index.html
│   └── main.mbt           #   组件里用 @tw.flex() / @tw.mt_4() …
└── out/                   # 构建产物（gitignore）
```

## 核心：`@css.generate_types`（库函数）

让"用户写了什么 class，就提示什么"的关键。

```mbt
///| 从样式源生成类型化 wrapper（每个 class 一个 pub fn）
///| 自动识别格式 → 编译成 css（展开 @each/插值成字面 .m-0 等）→ 提取全部 class
///| → 生成 `pub fn xxx() -> String { "xxx" }`
pub fn generate_types(source : String) -> String
```

### 第三方用法（在 build / SSG 里调用，写盘成 `.mbt`）

```mbt
let types = @css.generate_types(read_text("styles/tailwind.scss"))
write_file("app/tw.mbt", types)
```

### 或命令行（site 里这么生成的）

```bash
cat styles/tailwind.scss | moon run cmd/cli -- gen-types > tw/tw.mbt
```

生成结果是**链式 builder**（`site/tw/tw.mbt`，94 个方法 + `TW` struct）：

```moonbit
pub struct TW { classes : Array[String] }
pub fn tw() -> TW { { classes: [] } }              // 工厂
pub fn add(self : TW, c : String) -> TW { ... }    // 追加
pub fn class(self : TW) -> String { self.classes.join(" ") }  // 拼空格
pub fn m_4(self : TW) -> TW { self.add("m-4") }
pub fn text_red(self : TW) -> TW { self.add("text-red") }
```

## 智能提示 + 编译校验（链式，自动拼空格）

```moonbit
@html.node("h1",
  @html.Attrs::build().class(@tw.tw().mt_4().text_red().class()),
  [@html.text("hi")])
```

- **编辑器 LSP**（VS Code MoonBit 插件）：`@tw.tw().` 后自动列出可用的 utility（`mt_4`/`text_red`/…）——智能提示。
- **编译校验**：`@tw.wrong` / 拼错 class → 编译失败。
- **链式自动拼空格**：`@tw.tw().flex_row().gap_4().class()` → `"flex-row gap-4"`，不用手动 `+ " " +`。

## 构建

生产静态构建由 SSG 完成。CodeMirror 不入库，是构建期从 npm 取的，先装依赖并取一次：

```bash
pnpm install                 # 仓库根
pnpm run vendor:codemirror   # node_modules/codemirror -> site/static/codemirror
cd site && moon run cmd/ssg
# 产出 out/index.html（rabbit SSR 完整 HTML）+ out/tailwind.css（本库编译）+ out/codemirror/
```

> 少了 `vendor:codemirror` 这一步，SSG 会**直接报错退出**——不会静默产出一个
> 没有编辑器的页面。`site/static/codemirror/` 已 gitignore。

本地开发使用 Warren 提供 HTTP、文件监听和浏览器自动刷新。首次使用前安装 Warren：

```bash
moon install moonbit-community/warren
pnpm run site:dev
# 打开 http://127.0.0.1:8111
```

开发命令会将 SSG 产物写入被忽略的 `site/public/`，由 `cmd/server` 通过 Rabbita server 提供；生产仍写入 `site/out/`，两条链路互不覆盖。

> `tw/tw.mbt` 是生成产物；改 `styles/tailwind.scss` 后用 `gen-types` 重新生成即可。

## 依赖

- `moonbit-community/rabbita`（Web UI / SSR）
- `moonbitlang/async`（async / fs）
- `conglinyizhi/precss`（库：编译 SCSS + `generate_types`，经 `moon.work` 本地挂载）
- `codemirror@5`（npm devDependency，仅静态资源：构建期拷进 `static/codemirror/`）
