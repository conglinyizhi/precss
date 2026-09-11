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
