# 差分测试缺口报告（dart-sass / less.js 作 oracle）

用 `scripts/diff.mjs` 对 moonbit 引擎产物与 dart-sass（`sass@1.103`）做差分（scss/sass）；
`scripts/less_diff.mjs` 与 less.js 做差分（less）：同一份源码两边编译，压缩空白后比较。

scss/sass 用例来自自写 `test/cases/` 与上游 `sass-spec`（`spec/variables`、`spec/operators`、
`spec/directives`、`spec/css`；`test/sass-spec/` 已 gitignore，需自行拉取）；less 用例来自
`test/less_cases/`。

```bash
node scripts/diff.mjs              # scss/sass，跑 test/cases
node scripts/diff.mjs test/sass-spec/spec/variables
node scripts/diff.mjs test/sass-spec/spec/operators
node scripts/diff.mjs test/sass-spec/spec/directives
node scripts/less_diff.mjs         # less，跑 test/less_cases
```

> 本文件里出现的路径均相对**仓库根**（不是 `docs/`）。
>
> 表里的数字是**实测快照**，不是长期承诺——改完引擎要重跑再更新。
> 上一版（2026-09-03）的 `spec/directives` 一行（79 / 118 / 0）早就和实际对不上，
> 这里换成 2026-09-12 的实测值。

## 当前通过率（2026-09-12）

| 用例集 | 用例数 | 一致 | 不一致 | moonbit 报错 | oracle 无法编译 |
| --- | --- | --- | --- | --- | --- |
| `test/cases`（scss 自写） | 24 | 24 | 0 | 0 | 0 |
| `spec/variables` | 14 | 14 | 0 | 0 | 0 |
| `spec/operators` | 30 | 20 | 9 | 0 | 1 |
| `spec/directives` | 776 | 73 | 67 | 57 | 579 |
| `test/less_cases`（less 自写） | 11 | 11 | 0 | 0 | 0 |

- **oracle 无法编译（`sass 无法编译` 一列）**：多为 sass-spec 的多文件 `@import` 用例，
  单文件 `compileString` 缺依赖，不代表 moonbit 问题，属跳过项。
- **`spec/directives` 的 57 个 moonbit 报错**：45 个 `expected "}"`（parser 还不认的指令
  形态，如 `after_target` 一类）、11 个 `Expected expression.`、1 个 `Undefined variable`。
  这些是「报错好过静默产出错」，不是回归。

## 缺口分类（后续 roadmap）

### 1. 运算 / 值系统（operators 20/30）

已完成：

- 值序列化按 CSS 习惯紧贴：`(` `)` `,` `:` 不再被插空格（`var(--o, rgba(0, 0, 0, .2))`、
  `:has()`、`@supports (display: grid)`）。
- `+` 字符串连接（`c + d` → `cd`）。
- 裸括号吸收（`(c)-(d)` → `c-d`；`c-(d)` 仍未吸收）。
- 负值 token：`0px 3px 1px -2px` 不再被当成 `1px - 2px` 求值成 `-1px`。
- `font: 12px/1.5`。
- **`calc()` / `min()` / `max()` / `clamp()` 采取保守策略**：组内一律不折叠，
  且二元运算符两侧保留空白（`calc(100%-10px)` 同样是无效 CSS）。

剩余属**完整 SCSS value / 运算模型**（值类型工程，子集不建议挤牙膏）：

- 单位运算 / `infinity` / `NaN` / Color 值类型。
- `c-(d)` 的运算吸收（需要真正的表达式求值）。

#### calc() 与 dart-sass 的差距（dart-sass 1.103.1 实测）

| 输入 | dart-sass | precss（保守策略） |
| --- | --- | --- |
| `calc(100% - 10px)` | `calc(100% - 10px)` | 同 |
| `calc(var(--x) + 2px)` | `calc(var(--x) + 2px)` | 同 |
| `calc(-2px + var(--x))` | `calc(-2px + var(--x))` | 同 |
| `calc((var(--x) + 2px) / 3)` | 同 | 同 |
| `calc(1px + 2px)` | `3px` | `calc(1px + 2px)`（不化简） |
| `calc(100% - 10%)` | `90%` | `calc(100% - 10%)`（不化简） |
| `calc(100% / 3)` | `33.3333333333%` | `calc(100% / 3)`（不化简） |
| `min(1px, 2px)` | `1px` | `min(1px, 2px)`（不化简） |
| `calc(100% - 10px) * 2` | 报错 `Undefined operation` | 原样透传（未拦） |

保守策略保证**不再产出错值**，代价是不化简：值等价、浏览器语义不变，只是没折叠。
完整对齐需要值模型升级到「带单位的浮点数 + Calculation 节点」——现在的数字是 `Int` +
单位字符串，`calc(1px / 2)` → `0.5px` 这类根本表达不了。

### 2. 变量作用域与指令（已修，variables 14/14）

- 已实现块级作用域链（rule/mixin/@if/@for 各自独立、嵌套遮蔽）。
- 已支持 `!default` / `!global` 旗标（含重复旗标）。
- 已修复规则块结尾无分号声明的解析（`c { d: $a }`）。

### 3. 多文件 / 模块系统（API 已支持 @import，579 用例待 harness）

已实现：`@import "path"` 内联（注入 reader 递归解析、去循环依赖）、`compile_many(inputs, read)`
（File/Source 混用输入，逐个编译拼接）、根包 `compile_many` 便利入口、`Input::File`。

待办：sass-spec 那 579 个多文件用例需 harness 工程（materialize partial + 相对路径解析 +
dart-sass `loadPaths` + CLI 文件读取）才能真正跑差分；`@use` / `@forward` 尚未支持。

### 4. 控制流 / mixin（directives 73/776）

已支持：`@if` / `@else if` / `@else`（数字关系比较、`==`/`!=` 跨类型、`and`/`or`/`not`）、
`@while`、`@for`、`@each`（多变量解构 + 选择器/值插值）、`@content`、mixin 参数默认值与
`...` 可变参数、`@warn` / `@debug` / `@error`（忽略消息，旁随内容正常输出）。

不可比较的类型（字符串 / 布尔用 `<` `>`）现在按 dart-sass 显式报
`Undefined operation "a < b".`，不再静默返回 false。

仍缺：条件里的嵌套比较优先级完备、数学 / 颜色内置函数、`@return`。另有 579 个多文件
`@import` 用例无法单文件编译（见 #3）。

### 5. LESS 独立引擎（对齐 less.js）

LESS 走**独立引擎**（不复用 SCSS 求值，只共用 tokenizer）：变量 lazy 作用域
（最后定义优先、可用后定义）、嵌套 `&`、类 mixin（`.name()` 定义 / 调用 / 分离 /
参数默认值 / `;` 分隔 / 类混入）、基础运算、`@media` 透传、`@import` 内联、
**同名同值重复声明去重**（保留最后一次）。

- `test/less_cases` 11/11 全一致；随机构建基准（`example/perf/bench.mjs`）三格式均
  200/200 一致（less 与 less.js 对齐，含深嵌套 + 重复属性）。
- 与 SCSS 同步的行为：值里的括号 / 逗号 / 冒号紧贴、`calc()` 组内不折叠且保留运算符空格。
- 仍缺：mixin 守卫 `when`、`@arguments`、更深的 lazy 作用域（属 less 语义深水区）。

## 结论

子集在「变量（含作用域 / `!global` / `!default`）/ 嵌套 / 无参 mixin / 简单 `@if` /
数字加减 / 值的括号与逗号排版」上已与 dart-sass 对齐（自写 24/24，variables 14/14）；
LESS 在独立引擎下与 less.js 对齐（less_cases 11/11，随机基准三格式 200/200）。

完整 SCSS 语义（值类型与单位运算、模块系统、控制流细节）需要分阶段推进。按当前缺口，
优先级建议：**值类型（Number 带单位 / Color / Calculation）> `@use` / `@forward` >
directives parser 覆盖面**。
