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
    // 每段按自己的格式编译：纯粹的 CSS 段（无 $、无 @）走 css 引擎原样透传，
    // 含 $ 的段走 SCSS 引擎。需要强制某段走哪个引擎时用 SourceWithFormat。
    content=(
      #|body { color: red; }
      #|
      #|.x {
      #|  color: red;
      #|}
      #|
      #|.y { width: 1px; }
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

///|
/// SASS 缩进语法（无 `$`、无花括号）必须被自动识别，而不是当作 CSS 原样透传
test "compile 自动识别 SASS 缩进语法" {
  inspect(
    @precss.compile(".box\n  color: red\n  margin: 8px\n"),
    content=(
      #|.box {
      #|  color: red;
      #|  margin: 8px;
      #|}
      #|
    ),
  )
}

///|
/// 显式 SASS 入口（缩进语法）
test "compile_sass 显式指定缩进语法" {
  inspect(
    @precss.compile_sass(".box\n  color: red\n"),
    content=(
      #|.box {
      #|  color: red;
      #|}
      #|
    ),
  )
}

///|
/// 缩进语法里的 `$` 变量照常生效
test "compile_sass 支持变量" {
  inspect(
    @precss.compile_sass("$c: red\n.box\n  color: $c\n"),
    content=(
      #|.box {
      #|  color: red;
      #|}
      #|
    ),
  )
}

///|
/// 缩进判定必须排在 SCSS/LESS 之前：纯缩进源码两个特征都没有，
/// 排在后面会落到 CSS
test "Format::detect 识别缩进语法" {
  inspect(@core.Format::detect(".box\n  color: red\n"), content="sass")
  inspect(@core.Format::detect("$c: red\n.box\n  color: $c\n"), content="sass")
  inspect(@core.Format::detect(".box { color: red; }"), content="css")
  inspect(@core.Format::detect("$c: red;\n.box { color: $c; }"), content="scss")
  inspect(@core.Format::detect("@c: red;\n.box { color: @c; }"), content="less")
}

///|
/// compile_many 必须尊重 SourceWithFormat；此前它固定用 SCSS 引擎，
/// 把 LESS 源码当 SCSS 编译，产出无意义结果且不报错
test "compile_many 尊重 SourceWithFormat" {
  // 这些用例不涉及文件输入，read 一旦被调用就是测试本身写错了
  let read = fn(p : String) -> String raise @core.CompileError {
    raise @core.CompileError::EngineFailed(
      engine="test",
      message="unexpected read: " + p,
    )
  }
  inspect(
    @precss.compile_many(
      [
        @core.Input::SourceWithFormat(
          "@p: 8px;\n.x { padding: @p; }",
          @core.Format::Less,
        ),
      ],
      read,
    ),
    content=(
      #|.x {
      #|  padding: 8px;
      #|}
      #|
      #|
    ),
  )
}

///|
/// 同一批输入混用格式时，各段按各自的引擎编译
test "compile_many 混用格式" {
  // 这些用例不涉及文件输入，read 一旦被调用就是测试本身写错了
  let read = fn(p : String) -> String raise @core.CompileError {
    raise @core.CompileError::EngineFailed(
      engine="test",
      message="unexpected read: " + p,
    )
  }
  inspect(
    @precss.compile_many(
      [
        @core.Input::SourceWithFormat(".a\n  color: red\n", @core.Format::Sass),
        @core.Input::SourceWithFormat(
          "@p: 4px;\n.b { padding: @p; }",
          @core.Format::Less,
        ),
      ],
      read,
    ),
    content=(
      #|.a {
      #|  color: red;
      #|}
      #|
      #|.b {
      #|  padding: 4px;
      #|}
      #|
      #|
    ),
  )
}

///|
/// compile_file 必须把 reader 透传给 @import；此前它走 compile（不携带 reader），
/// 源码里的 @import 被静默忽略——变量不生效、也不报错
test "compile_file 内联 @import" {
  let files : Map[String, String] = Map([
    ("theme.scss", "$gap: 8px;\n$fg: #333;"),
    ("main.scss", "@import \"theme.scss\";\nbody { margin: $gap; color: $fg; }"),
  ])
  let read = fn(path : String) -> String raise @core.CompileError {
    match files.get(path) {
      Some(s) => s
      None =>
        raise @core.CompileError::EngineFailed(
          engine="test",
          message="no such file: " + path,
        )
    }
  }
  inspect(
    @precss.compile_file("main.scss", read),
    content=(
      #|body {
      #|  margin: 8px;
      #|  color: #333;
      #|}
      #|
    ),
  )
}

///|
/// @import 的路径原样交给 reader，库不做扩展名补全
test "compile_file 的 @import 路径原样传给 reader" {
  let seen : Array[String] = []
  let read = fn(path : String) -> String raise @core.CompileError {
    seen.push(path)
    if path == "entry.scss" {
      "@import \"partials/base\";"
    } else if path == "partials/base" {
      "$gap: 4px;"
    } else {
      raise @core.CompileError::EngineFailed(
        engine="test",
        message="unexpected path: " + path,
      )
    }
  }
  ignore(@precss.compile_file("entry.scss", read))
  inspect(seen.join(","), content="entry.scss,partials/base")
}
