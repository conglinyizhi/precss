///|
/// 根包公开 API 的黑盒测试
test "compile css 透传" {
  inspect(
    @precss.compile_css("body { color: red; }"),
    content="body { color: red; }",
  )
}

///|
test "compile scss 变量" {
  inspect(
    @precss.compile_scss("$c: red; body { color: $c; }"),
    content=(
      #|body {
      #|  color: red;
      #|}
      #|
    ),
  )
}

///|
test "compile 自动识别格式" {
  inspect(
    @precss.compile("$w: 10px; a { width: $w; }"),
    content=(
      #|a {
      #|  width: 10px;
      #|}
      #|
    ),
  )
}

///|
test "compile many" {
  let read = fn(p : String) -> String raise @core.CompileError {
    if p == "a" {
      "$c: red; .x { color: $c; }"
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
        @core.Input::File("a"),
        @core.Input::Source(".y { width: 1px; }"),
      ],
      read,
    ),
    content=(
      #|body {
      #|  color: red;
      #|}
      #|
      #|.x {
      #|  color: red;
      #|}
      #|
      #|.y {
      #|  width: 1px;
      #|}
      #|
    ),
  )
}

///|

///|
/// sass 缩进语法：应被转成 scss 并编译
test "sass indent compile" {
  let src = "$c: blue\n.box\n  color: $c\n  a\n    margin: 1px\n"
  inspect(
    @precss.compile_scss(src),
    content=(
      #|.box {
      #|  color: blue;
      #|}
      #|.box a {
      #|  margin: 1px;
      #|}
      #|
    ),
  ) catch {
    e => fail("compile sass failed: \{repr(e)}")
  }
}

///|
/// conflict: sass_to_scss 中间产物（供后端白盒参考）
test "sass to scss" {
  inspect(
    @scss.sass_to_scss("$c: blue\n.box\n  color: $c\n"),
    content=(
      #|$c: blue;
      #|.box {
      #|color: $c;
      #|}
      #|
    ),
  )
}

///|
test "less mixin" {
  inspect(
    @precss.compile_less(
      ".rounded(@r) { border-radius: @r; }\n.btn { .rounded(5px); }",
    ),
    content=(
      #|.btn {
      #|  border-radius: 5px;
      #|}
      #|
      #|
    ),
  )
}

///|
test "less mixin 默认值" {
  inspect(
    @precss.compile_less(
      ".pad(@p: 8px) { padding: @p; }\n.x { .pad(); }\n.y { .pad(12px); }",
    ),
    content=(
      #|.x {
      #|  padding: 8px;
      #|}
      #|
      #|.y {
      #|  padding: 12px;
      #|}
      #|
      #|
    ),
  )
}

///|
/// 变量注入：未定义的 $c 通过 vars 预置为 red
test "compile_scss_with_vars 注入预置变量" {
  let css = @precss.compile_scss_with_vars(
    "body { color: $c; }",
    Map([("c", "red")]),
  ) catch {
    _ => ""
  }
  inspect(css, content="body {\n  color: red;\n}\n")
}

///|
/// 注入多变量 + 单位
test "compile_scss_with_vars 注入多变量" {
  let css = @precss.compile_scss_with_vars(
    ".a { margin: $gap; color: $c; }",
    Map([("gap", "8px"), ("c", "blue")]),
  ) catch {
    _ => ""
  }
  inspect(css, content=".a {\n  margin: 8px;\n  color: blue;\n}\n")
}

///|
/// 对称的 LESS 变量注入入口
test "compile_less_with_vars 注入变量" {
  let css = @precss.compile_less_with_vars(
    ".a { color: @c; }",
    Map([("c", "red")]),
  ) catch {
    _ => ""
  }
  inspect(css, content=".a {\n  color: red;\n}\n\n")
}

///|
/// 多源码片段的轻量入口
test "compile_sources" {
  inspect(
    @precss.compile_sources(["a { color: red; }", "b { color: blue; }"]),
    content="a { color: red; }\nb { color: blue; }",
  )
}

///|
/// 保守压缩：去块注释/空白/换行，字符串值原样保留
test "minify_css 保守压缩" {
  inspect(
    @precss.minify_css("body { color: red; }\n/* c */ .a { width: 1px; }"),
    content="body{color:red;}.a{width:1px;}",
  )
}

///|
/// 字符串值里的空白不被压缩（content/url 等）
test "minify_css 保留字符串值" {
  inspect(
    @precss.minify_css("a { content: \"a  b \"; }"),
    content="a{content:\"a  b \";}",
  )
}
