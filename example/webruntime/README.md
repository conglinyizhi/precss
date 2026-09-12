# precss 浏览器运行时范例

把库编译到浏览器运行，扫描 `<style lang="scss|less|sass">` 标签，加载后用 MoonBit
把源码编译成 CSS，创建新 `<style>` 替换原标签。多个模块 / 混用 scss / less / sass 都行。

> 库核心是纯 `String→String`，所以「浏览器运行时」就是让它把字符串进出边界。本范例给两条路：
> **JS backend**（浏览器全覆盖）与 **wasm-gc**（真 `.wasm`，Chrome 直接可用）。

## 目录

```
example/webruntime/
  web/            # #export_name 导出 compile_scss / compile_less（String→String）
    main.mbt
  runtime.js      # JS 版运行时：scan style[lang] → 调 compile_* → 替换
  index.html      # JS 版演示（scss / less / sass 三个 style[lang]）
  wasm-gc/
    runtime.js    # wasm-gc 运行时：instantiate + _start + scan
    index.html    # wasm-gc 版演示
  README.md
```

> `web.js` / `wasm-gc/web.wasm` 是 **构建产物，不入库**，跑 demo 前先按下面对应
> 章节 build 一次。产物已在 `.gitignore` 里，避免入库后与引擎源码脱节。

## JS backend 版（推荐，浏览器全覆盖）

构建：

```bash
moon build --target js example/webruntime/web
# 产物: _build/js/debug/build/example/webruntime/web/web.js
cp _build/js/debug/build/example/webruntime/web/web.js example/webruntime/web.js
```

运行（ESM 在 `file://` 下受限，起静态服务）：

```bash
python3 -m http.server
# 打开 http://localhost:8000/example/webruntime/index.html
```

**浏览器兼容性：现代 Chrome / Firefox / Waterfox / Safari 全部无问题**（就是普通 JS 模块，
String 直接是 JS string，零 ABI 握手）。

## wasm-gc 版（真 .wasm 文件，Chrome 可用）

构建：

```bash
moon build --target wasm-gc example/webruntime/wasm
# 产物: _build/wasm-gc/debug/build/example/webruntime/wasm/wasm.wasm
cp _build/wasm-gc/debug/build/example/webruntime/wasm/wasm.wasm example/webruntime/wasm-gc/web.wasm
```

运行：

```bash
python3 -m http.server
# 打开 http://localhost:8000/example/webruntime/wasm-gc/index.html
```

**浏览器兼容性（经 MDN browser-compat-data 确证，`jsStringBuiltins`）：**

| 浏览器 | 支持版本 |
| --- | --- |
| Chrome | 130+ |
| Firefox | 134+（2025 年初的现代 Firefox） |
| Safari | 26.2+ |
| Edge / Opera | mirror Chrome |

即 **wasm-gc 版在现代 Firefox / Chrome / Safari 都能跑**（无 flag，`version_added` 无 flags 字段）。
Waterfox 按其基线 Firefox 版本判断（若 ≥134 则支持；较旧基线可能不支持）。

## 关于纯 wasm 与 MoonBit 的字符串跨边界

MoonBit wasm 的字符串跨边界主线用 **wasm-gc + `use-js-builtin-string`**（WebAssembly
JS String Builtins）。经 MDN browser-compat-data 确证，该特性在 **Chrome 130+ / Firefox 134+ /
Safari 26.2+** 均已**默认支持**，所以 **wasm-gc 版在现代浏览器（含 Firefox）是可用的**。

> 曾一度以为 Firefox 未实现该特性（保守/旧线索），经 BCD 确证后纠正：Firefox 134+ 支持。
> 因此“要纯 wasm + 现代 Firefox” → **直接用 wasm-gc 版即可**，无需普通 wasm 逆向。
> 普通 wasm（`export-memory-name` + 手写 UTF-16/header 胶水）只在**老浏览器 / Waterfox 旧基线**（< Firefox 134）
> 或不需要 JS String Builtins 的极端场景才有意义；属源码级专项，一般不做。

## 原理

## 原理

- `web/main.mbt`：`#export_name` 导出 `compile_scss` / `compile_less`（`String→String`，错误返回空串）。
- JS backend：`moon build --target js` 产出 ESM（named export，String 零 ABI）。
- wasm-gc：`moon build --target wasm-gc` 产出 `.wasm`（`instantiateStreaming` + `_start` + String externref）。
- `runtime.js`：`querySelectorAll('style[lang]')` → 按 `lang` 调 `compile_*` → `replaceWith`。

## 扩展

- 想保留原 `<style>` 作 fallback？把 `replaceWith` 改成 `insertBefore` + `remove()`。
- 想更早初始化？把脚本内联到 `</head>` 前，或 `readyState !== 'loading'` 分支已处理。
