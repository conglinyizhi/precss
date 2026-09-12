///|
/// LESS 子集的黑盒测试
///
/// 与 SCSS 那份（`backend/scss/backend_scss_test.mbt`）对应：都走各自引擎的真实路径。
/// LESS 引擎是独立解析 + 求值（不复用 SCSS 引擎），所以这里直接调 `parse_less` +
/// `eval_less`，而不是 `less_to_scss`。
///
/// 期望值全部与 less.js 的实际渲染核对过：语义一致，空白按 precss 自己的排版。
/// 其中「无参 mixin」那几条在补测试之前是坏的——`.m { }` 只被当成普通类规则，
/// 没注册成可调用的 mixin，于是 `.a { .m; }` 会把整个 `.a` 块丢掉。
fn compile_less(src : String) -> String raise @core.CompileError {
  @less.eval_less(@less.parse_less(@scss.tokenize(src)), None)
}

///|
test "variable" {
  inspect(
    compile_less("@c: red; body { color: @c; }"),
    content=(
      #|body {
      #|  color: red;
      #|}
      #|
    ),
  )
}

///|
test "lazy scope" {
  inspect(
    compile_less("body { color: @c; } @c: red;"),
    content=(
      #|body {
      #|  color: red;
      #|}
      #|
    ),
  )
}

///|
test "last definition wins" {
  inspect(
    compile_less("@c: red; @c: blue; body { color: @c; }"),
    content=(
      #|body {
      #|  color: blue;
      #|}
      #|
    ),
  )
}

///|
test "nested rule" {
  inspect(
    compile_less(".a { color: red; .b { color: blue; } }"),
    content=(
      #|.a {
      #|  color: red;
      #|}
      #|.a .b {
      #|  color: blue;
      #|}
      #|
    ),
  )
}

///|
test "parent selector" {
  inspect(
    compile_less(".a { color: red; &:hover { color: blue; } }"),
    content=(
      #|.a {
      #|  color: red;
      #|}
      #|.a:hover {
      #|  color: blue;
      #|}
      #|
    ),
  )
}

///|
test "parent selector suffix" {
  inspect(
    compile_less(".a { color: red; &.on { color: blue; } }"),
    content=(
      #|.a {
      #|  color: red;
      #|}
      #|.a.on {
      #|  color: blue;
      #|}
      #|
    ),
  )
}

///|
test "paramless mixin call" {
  inspect(
    compile_less(".m { color: red; } .a { .m; }"),
    content=(
      #|.m {
      #|  color: red;
      #|}
      #|
      #|.a {
      #|  color: red;
      #|}
      #|
    ),
  )
}

///|
test "paramless mixin call with parens" {
  inspect(
    compile_less(".m { color: red; } .a { .m(); }"),
    content=(
      #|.m {
      #|  color: red;
      #|}
      #|
      #|.a {
      #|  color: red;
      #|}
      #|
    ),
  )
}

///|
test "paramless mixin call without semicolon" {
  inspect(
    compile_less(".m { color: red; } .a { .m }"),
    content=(
      #|.m {
      #|  color: red;
      #|}
      #|
      #|.a {
      #|  color: red;
      #|}
      #|
    ),
  )
}

///|
test "mixin call after declaration" {
  inspect(
    compile_less(".m { color: red; } .a { width: 1px; .m; }"),
    content=(
      #|.m {
      #|  color: red;
      #|}
      #|
      #|.a {
      #|  width: 1px;
      #|  color: red;
      #|}
      #|
    ),
  )
}

///|
test "mixin call before declaration" {
  inspect(
    compile_less(".m { color: red; } .a { .m; width: 1px; }"),
    content=(
      #|.m {
      #|  color: red;
      #|}
      #|
      #|.a {
      #|  color: red;
      #|  width: 1px;
      #|}
      #|
    ),
  )
}

///|
test "mixin with params" {
  inspect(
    compile_less(".m(@w) { width: @w; } .a { .m(10px); }"),
    content=(
      #|.a {
      #|  width: 10px;
      #|}
      #|
    ),
  )
}

///|
test "arithmetic" {
  inspect(
    compile_less("@gap: 8px; a { margin: @gap + 4px; padding: @gap - 2px; }"),
    content=(
      #|a {
      #|  margin: 12px;
      #|  padding: 6px;
      #|}
      #|
    ),
  )
}

///|
test "pseudo class selector" {
  inspect(
    compile_less(".a:hover { color: red; }"),
    content=(
      #|.a:hover {
      #|  color: red;
      #|}
      #|
    ),
  )
}

///|
test "selector list" {
  inspect(
    compile_less(".a, .b { color: red; }"),
    content=(
      #|.a, .b {
      #|  color: red;
      #|}
      #|
    ),
  )
}

///|
test "child combinator" {
  inspect(
    compile_less(".a > .b { color: red; }"),
    content=(
      #|.a > .b {
      #|  color: red;
      #|}
      #|
    ),
  )
}

///|
/// 未定义的 mixin 要报错，不能静默把调用方的内容吞掉。
/// less.js 对 `.a { .nope; }` 报 ".nope is undefined"。
test "undefined mixin is reported" {
  let result = Ok(compile_less(".a { .nope; }")) catch { err => Err(err) }
  match result {
    Err(@core.CompileError::EngineFailed(engine~, message~)) => {
      assert_eq(engine, "less")
      assert_true(message.contains(".nope is undefined"))
    }
    _ => fail("expected an EngineFailed error")
  }
}

///|
/// 已定义的 mixin 不应被误报。
test "defined mixin does not raise" {
  inspect(
    compile_less(".m { color: red; } .a { .m; }"),
    content=(
      #|.m {
      #|  color: red;
      #|}
      #|
      #|.a {
      #|  color: red;
      #|}
      #|
    ),
  )
}

///|
/// `@media` 的语义与 less.js 一致，但 precss 这个分支多吐了几个空行。
/// 差分套件会归一化空白，所以那边看不出来；这里按当前实际输出锁定，
/// 属于排版差异而不是行为差异。
test "media" {
  inspect(
    compile_less("@media screen { body { color: red; } }"),
    content=(
      #|@media screen {
      #|body {
      #|  color: red;
      #|}
      #|
      #|}
      #|
    ),
  )
}

///|
/// 回归：函数式括号里不能被插空格（LESS 走独立的 `join_selector_tokens`）。
/// 以前 `:has(input:checked)` → `:has ( input:checked )`，浏览器整条丢弃。
test "functional parens keep tight" {
  inspect(
    compile_less(
      ".a:has(input:checked) .b { display: inline-flex; }\n.v-btn:not(.v-btn--disabled):hover > .v-btn__overlay { opacity: .12; }",
    ),
    content=(
      #|.a:has(input:checked) .b {
      #|  display: inline-flex;
      #|}
      #|
      #|.v-btn:not(.v-btn--disabled):hover > .v-btn__overlay {
      #|  opacity: .12;
      #|}
      #|
    ),
  )
}

///|
/// 回归：值里函数调用与逗号不能再插空格。
/// 以前 `rgba(0,0,0,.2)` → `rgba ( 0 , 0 , 0 , .2 )`，是无效 CSS。
test "function value keeps tight" {
  inspect(
    compile_less(
      ".x { box-shadow: 0px 3px 1px -2px var(--o, rgba(0,0,0,.2)), 0px 2px 2px 0px #000; }",
    ),
    content=(
      #|.x {
      #|  box-shadow: 0px 3px 1px -2px var(--o, rgba(0, 0, 0, .2)), 0px 2px 2px 0px #000;
      #|}
      #|
    ),
  )
}

///|
/// 回归（issue #2）：LESS 走另一条 `join_selector_tokens`，同样会在函数式伪类的
/// 右括号后面插空格：`.a:not(.b).c` → `.a:not(.b) .c`，复合选择器变后代选择器。
test "K: functional pseudo keeps tight to following simple selector" {
  inspect(
    compile_less(
      ".a:not(.b).c input { position: absolute; }\n.a:not(.b):hover { opacity: 1; }\n.d:has(input:checked).e { color: red; }",
    ),
    content=(
      #|.a:not(.b).c input {
      #|  position: absolute;
      #|}
      #|
      #|.a:not(.b):hover {
      #|  opacity: 1;
      #|}
      #|
      #|.d:has(input:checked).e {
      #|  color: red;
      #|}
      #|
    ),
  )
}

///|
/// 回归（issue #2 的反例）：作者写的后代选择器不能被粘成复合选择器。
/// 空白进 token 流后，`.x:not(.y) .z` 与 `.x:not(.y).z` 各归各位。
test "K2: descendant after functional pseudo keeps space" {
  inspect(
    compile_less(
      ".x:not(.y) .z { a: 1; }\n.x:not(.y):hover { a: 2; }\n.x:not(.y)>b { a: 3; }",
    ),
    content=(
      #|.x:not(.y) .z {
      #|  a: 1;
      #|}
      #|
      #|.x:not(.y):hover {
      #|  a: 2;
      #|}
      #|
      #|.x:not(.y)>b {
      #|  a: 3;
      #|}
      #|
    ),
  )
}

///|
/// 回归：LESS 的 `merge_math` 同样不能折 `calc()` 里的算术
test "calc keeps its own arithmetic" {
  inspect(
    compile_less(
      ".a { b: calc(100% - 10px); }\n.b { c: calc(var(--x) + 2px); }\n.c { d: calc(-2px + var(--x)); }\n.d { e: calc((var(--x) + 2px)/3); }",
    ),
    content=(
      #|.a {
      #|  b: calc(100% - 10px);
      #|}
      #|
      #|.b {
      #|  c: calc(var(--x) + 2px);
      #|}
      #|
      #|.c {
      #|  d: calc(-2px + var(--x));
      #|}
      #|
      #|.d {
      #|  e: calc((var(--x) + 2px) / 3);
      #|}
      #|
    ),
  )
}
