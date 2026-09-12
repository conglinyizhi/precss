///|
/// SCSS 子集的黑盒测试
fn compile(src : String) -> String raise @core.CompileError {
  @scss.to_css(@scss.parse_sheet(@scss.tokenize(src)))
}

///|
test "variable" {
  inspect(
    compile("$c: red; body { color: $c; }"),
    content=(
      #|body {
      #|  color: red;
      #|}
      #|
    ),
  )
}

///|
test "nest" {
  inspect(
    compile("body { color: red; a { width: 10px; } }"),
    content=(
      #|body {
      #|  color: red;
      #|}
      #|body a {
      #|  width: 10px;
      #|}
      #|
    ),
  )
}

///|
test "mixin" {
  inspect(
    compile(
      "@mixin border { border: 1px solid black; } .box { @include border; }",
    ),
    content=(
      #|.box {
      #|  border: 1px solid black;
      #|}
      #|
      #|
    ),
  )
}

///|
test "if" {
  inspect(
    compile("$flag: true; a { @if $flag { color: red; } }"),
    content=(
      #|a {
      #|  color: red;
      #|}
      #|
    ),
  )
}

///|
test "for" {
  inspect(
    compile("@for $i from 1 to 3 { .col-#{$i} { width: 100px; } }"),
    content=(
      #|.col-1 {
      #|  width: 100px;
      #|}
      #|.col-2 {
      #|  width: 100px;
      #|}
      #|
    ),
  )
}

///|
test "media" {
  inspect(
    compile("@media screen { body { color: red; } }"),
    content=(
      #|@media screen {
      #|body {
      #|  color: red;
      #|}
      #|}
      #|
    ),
  )
}

///|
test "arith" {
  inspect(
    compile("$gap: 8px; a { margin: $gap + 4px; padding: $gap - 2px; }"),
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
test "import" {
  let read = fn(path : String) -> String raise @core.CompileError {
    if path == "a" {
      "$c: blue; .x { color: $c; }"
    } else {
      raise @core.CompileError::EngineFailed(
        engine="test",
        message="missing: " + path,
      )
    }
  }
  inspect(
    @scss.compile_with_imports("@import \"a\"; body { color: red; }", read),
    content=(
      #|.x {
      #|  color: blue;
      #|}
      #|body {
      #|  color: red;
      #|}
      #|
    ),
  )
}

///|
/// 回归：`@if $x == 字面量` 以前恒为 false（v_cmp 没有字符串分支），
/// 两个分支都不进 → 规则体为空 → 整条规则静默消失。产物里连 `.a` 都没有。
test "if compare string literal" {
  inspect(
    compile(
      "$density: compact;\n.a {\n  @if $density == compact { height: 32px; }\n  @if $density != compact { height: 40px; }\n}",
    ),
    content=(
      #|.a {
      #|  height: 32px;
      #|}
      #|
    ),
  )
}

///|
/// 回归：插值写在自定义属性名里时既不插值也不报错；
/// 且 `@each` 解构带引号的元组时不能把 `"24,103,192"` 按逗号拆开。
test "each tuple with quoted values and property name interpolation" {
  inspect(
    compile(
      "$items: (primary \"24,103,192\", secondary \"1,135,134\");\n@each $name, $rgb in $items {\n  .x { --v-theme-#{$name}: $rgb; }\n}",
    ),
    content=(
      #|.x {
      #|  --v-theme-primary: "24,103,192";
      #|}
      #|.x {
      #|  --v-theme-secondary: "1,135,134";
      #|}
      #|
    ),
  )
}

///|
/// 回归：`@each` 解构 `(a b c, d e f)` 这种带引号的元组列表。
/// 以前引号不参与分词，逗号与空格被当成同一层分隔符，产出 6 条碎片规则。
test "each tuple destructuring" {
  inspect(
    compile(
      "$items: (\"background\" \"255,255,255\" 1, \"primary\" \"24,103,192\" 2);\n@each $name, $rgb, $mult in $items { .#{$name} { opacity: $mult; } }",
    ),
    content=(
      #|.background {
      #|  opacity: 1;
      #|}
      #|.primary {
      #|  opacity: 2;
      #|}
      #|
    ),
  )
}

///|
/// 回归：mixin 的字符串实参经 `@include` 传参后再插值，不能把引号带进选择器。
/// 以前输出 `."v-btn":hover>."v-btn" __overlay`——引号进了选择器，`__overlay`
/// 前还多一个空格，整条失效。同一条路径在 `@each` 里是好的。
test "mixin string param interpolation into selector" {
  inspect(
    compile(
      "@mixin interactive($name) {\n  .#{$name}:hover > .#{$name}__overlay { opacity: .5; }\n}\n@include interactive(\"v-btn\");",
    ),
    content=(
      #|.v-btn:hover > .v-btn__overlay {
      #|  opacity: .5;
      #|}
      #|
      #|
    ),
  )
}

///|
/// 回归：函数式括号里不能被插空格。
/// 以前 `:has(input:checked)` → `:has ( input:checked )`，选择器失效；
/// `@supports (display: grid)` → `(display : grid)` 同样坏。
test "functional parens keep tight" {
  inspect(
    compile(
      ".a:has(input:checked) .b { display: inline-flex; }\n.v-btn:not(.v-btn--disabled):hover > .v-btn__overlay { opacity: .12; }\n@supports (display: grid) { .d { display: grid; } }",
    ),
    content=(
      #|.a:has(input:checked) .b {
      #|  display: inline-flex;
      #|}
      #|.v-btn:not(.v-btn--disabled):hover > .v-btn__overlay {
      #|  opacity: .12;
      #|}
      #|@supports (display: grid) {
      #|.d {
      #|  display: grid;
      #|}
      #|}
      #|
    ),
  )
}

///|
/// 回归：空格分隔的简写值里带负号 token，不能被当成算式求值。
/// 以前 `0px 3px 1px -2px` → `0px 3px -1px`：blur 变负、spread 消失，
/// 产物看着仍是合法 box-shadow，不报错。
test "negative token in space separated shorthand" {
  inspect(
    compile(
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
/// 回归：`calc()` 里是 CSS Calculation，不能被当普通算术折掉，
/// 运算符两侧也不能被压掉——`calc(100% - 10px)` 折成 `calc(90%)` 会静默改语义，
/// `calc(100%-10px)` 浏览器会整条丢弃。
test "calc keeps its own arithmetic" {
  inspect(
    compile(
      ".a { b: calc(100% - 10px); }\n.b { c: calc(var(--x) + 2px); }\n.c { d: calc(-2px + var(--x)); }\n.d { e: calc((var(--x) + 2px)/3); }\n.e { f: min(1px + 2px, var(--x)); }",
    ),
    content=(
      #|.a {
      #|  b: calc(100% - 10px);
      #|}
      #|.b {
      #|  c: calc(var(--x) + 2px);
      #|}
      #|.c {
      #|  d: calc(-2px + var(--x));
      #|}
      #|.d {
      #|  e: calc((var(--x) + 2px) / 3);
      #|}
      #|.e {
      #|  f: min(1px + 2px, var(--x));
      #|}
      #|
    ),
  )
}

///|
/// calc 组外仍照旧折叠，别被上面的保护误伤
test "arith outside calc still folds" {
  inspect(
    compile(".a { b: 8px + 4px; c: calc(1px + 2px); }"),
    content=(
      #|.a {
      #|  b: 12px;
      #|  c: calc(1px + 2px);
      #|}
      #|
    ),
  )
}

///|
/// 回归（issue #2）：函数式伪类后面紧跟另一个简单选择器时不能被插空格。
///
/// 以前 `:not(.b).c` → `:not(.b) .c`，同一个元素上的复合选择器变成了后代
/// 选择器，规则完全不匹配任何元素，而且全程无报错。同一类错位也见于 `:has()`。
test "K: functional pseudo keeps tight to following simple selector" {
  inspect(
    compile(
      ".a:not(.b).c input { position: absolute; }\n.a:not(.b):hover { opacity: 1; }\n.d:has(input:checked).e { color: red; }",
    ),
    content=(
      #|.a:not(.b).c input {
      #|  position: absolute;
      #|}
      #|.a:not(.b):hover {
      #|  opacity: 1;
      #|}
      #|.d:has(input:checked).e {
      #|  color: red;
      #|}
      #|
    ),
  )
}

///|
/// 回归（issue #2 的反例）：作者写的后代选择器不能被粘成复合选择器。
///
/// `.a:not(.b) .c` 与 `.a:not(.b).c` 只差一个空白。以前空白在分词阶段就丢了，
/// 只能靠字符启发式猜；给 `)` 打补丁会把这条真的后代选择器反过来粘死。
/// 现在空白进 token 流，两种写法各归各位。
test "K2: descendant after functional pseudo keeps space" {
  inspect(
    compile(
      ".x:not(.y) .z { a: 1; }\n.x:not(.y):hover { a: 2; }\n.x:not(.y)>b { a: 3; }\n.a:not(.b) .c input { b: 1; }",
    ),
    content=(
      #|.x:not(.y) .z {
      #|  a: 1;
      #|}
      #|.x:not(.y):hover {
      #|  a: 2;
      #|}
      #|.x:not(.y)>b {
      #|  a: 3;
      #|}
      #|.a:not(.b) .c input {
      #|  b: 1;
      #|}
      #|
    ),
  )
}

///|
/// 回归（issue #2）：空白在 token 流里还原，选择器其余形态不能被改动。
/// 多空格归并成一个、逗号前后收干净、标识符里的插值不开缝。
///
/// 顺带护住一个同类静默错误：属性选择器的运算符（`[lang|=en]`）以前会被
/// 插成 `[lang | = en]`——那是无效 CSS，整条丢弃。
test "selector whitespace normalization" {
  inspect(
    compile(
      ".a   .b , .c\t.d { a: 1; }\n.e:not( .f ) .g { b: 2; }\n.h[lang|=en].i { c: 3; }\n.j[data-x=\"a b\"] .k { d: 4; }",
    ),
    content=(
      #|.a .b, .c .d {
      #|  a: 1;
      #|}
      #|.e:not(.f) .g {
      #|  b: 2;
      #|}
      #|.h[lang|=en].i {
      #|  c: 3;
      #|}
      #|.j[data-x="a b"] .k {
      #|  d: 4;
      #|}
      #|
    ),
  )
}
