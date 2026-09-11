# precss 最小集成范例

把 precss 接进一个构建流程需要知道的最小集合。源码只有 `main.mbt`，五个场景各一个函数。

```bash
moon run example/minimal
```

## 五个场景

| # | 场景 | 入口 |
| --- | --- | --- |
| 1 | 一段源码，格式自动识别 | `compile` |
| 2 | 明确指定走哪个引擎 | `compile_scss` / `compile_sass` / `compile_less` |
| 3 | 构建期注入全局变量（主题色、基准间距） | `compile_scss_with_vars` |
| 4 | 读文件，`@import` 递归内联 | `compile_file` + 注入 reader |
| 5 | 单份失败降级，不拖垮整轮构建 | `catch` |

## 输出

```
--- 1. compile：自动识别 ---
body {
  color: red;
}

--- 2. 显式格式入口 ---
.a .b {
  color: red;
}

.box {
  color: red;
}

.x {
  padding: 8px;
}


--- 3. 注入全局变量 ---
.btn {
  color: #0a7;
  border: 1px solid #0a7;
}

--- 4. 注入 reader 读文件 ---
body {
  margin: 8px;
  color: #333;
}

--- 5. 错误处理（单份降级）---
（这一份编译失败，已跳过：less failed: .no_such_mixin is undefined）
```

## 三个容易踩的点

**自动识别是启发式，拿不准就用显式入口。**
既没有 `$`、也没有 `@` 变量、又没有缩进的源码（例如裸的 SCSS 嵌套 `.a { .b { … } }`）会被当作普通 CSS **原样透传**——不报错，但也没编译。这类输入用 `compile_scss`。

**编译文件按扩展名定格式，不是按内容。**
`.scss` 的 `@import` 是编译期内联，`.css` 的 `@import` 要原样留给浏览器；两者都可能一个 `$` 都没有，只看内容分不出来。所以 `compile_file` 走 `Format::from_path`（路径优先），认不出扩展名才回退到内容启发式。

**两个引擎的严格度不一样，别指望编译器兜住所有错。**
LESS 对未定义 mixin 会报错；SCSS 引擎对未定义变量、未闭合块是宽容的（原样输出或输出为空，不报错），LESS 对未定义变量也不报。这类错误得靠差分测试或 linter，不是靠编译失败。

## 接进真实项目

第 4 个场景用的是内存表，真实项目换成 `@fs` / `@async/fs` 即可：

```moonbit
let read = fn(path : String) -> String raise @core.CompileError {
  @fs.read_file_to_string(path)   // 换成你的 IO
}
```

`@import` 的路径会**原样**交给这个 reader——`_partial.scss` 补全、扩展名补全之类的解析策略属于打包器，不属于核心（核心零 IO）。

浏览器里的用法见 [`example/webruntime/`](../webruntime/)（JS backend 与 wasm-gc 两条路）。
