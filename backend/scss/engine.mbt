///| sass 缩进语法识别与转换
///
/// sass（缩进语法，`.sass`）用缩进代替花括号、换行代替分号。这里先识别它，
/// 并提供一个**常见子集**转换器：把缩进语法转成等价的 scss（`{ } ;`）。
///
/// 规则（子集）：
/// - 有子缩进行的行 → 选择器/指令 → 开块 `text { ... }`
/// - 无子缩进行的行    → 属性/变量（叶子）→ `text;`
///
/// 无法识别的边界（如 sass 简写属性 `:prop`、`//` 注释、`=` 混入）暂不处理，
/// 转换产物若不被 scss 解析则走正常报错路径。

///|
/// 判断源码是否为 sass 缩进语法（无花括号 + 有缩进行）
pub fn is_sass_indent(source : String) -> Bool {
  let mut line_start = true
  for c in source {
    if c == '{' || c == '}' {
      return false
    }
    if line_start && (c == ' ' || c == '\t') {
      return true
    }
    line_start = c == '\n'
  }
  false
}

///|
/// 把 sass 缩进语法转成 scss
pub fn sass_to_scss(source : String) -> String {
  let rows : Array[(Int, String)] = []
  for line in source.split("\n") {
    let t = line.trim()
    if t.length() == 0 {
      continue
    }
    rows.push((count_indent(line.to_owned()), t.to_owned()))
  }
  if rows.length() == 0 {
    return ""
  }
  let (out, _) = parse_sass(rows, 0, rows[0].0)
  out
}

///|
/// 数前导空白（tab 近似算 2 个空格）
fn count_indent(line : String) -> Int {
  let mut c = 0
  for ch in line {
    if ch == ' ' {
      c += 1
    } else if ch == '\t' {
      c += 2
    } else {
      break
    }
  }
  c
}

///|
/// 递归解析缩进块：返回 (scss 文本, 下一行下标)
fn parse_sass(
  rows : Array[(Int, String)],
  i : Int,
  indent : Int,
) -> (String, Int) {
  let sb = StringBuilder()
  let mut j = i
  while j < rows.length() && rows[j].0 == indent {
    let text = rows[j].1
    if j + 1 < rows.length() && rows[j + 1].0 > indent {
      // 选择器 / 指令：有子块 → 开块
      sb.write_string(text + " {\n")
      let (sub, ni) = parse_sass(rows, j + 1, rows[j + 1].0)
      sb.write_string(sub)
      sb.write_string("}\n")
      j = ni
    } else {
      // 属性 / 变量（叶子）→ 加分号
      sb.write_string(text + ";\n")
      j += 1
    }
  }
  (sb.to_string(), j)
}

///|

///|
/// SCSS 后端引擎
///
/// 把源码经 tokenize → parse → to_css 编译成 CSS，
/// 交给门面 `Compiler` 路由使用。
pub fn scss_engine() -> @core.Engine {
  @core.Engine::new(
    name=() => "scss",
    supports=fmt => fmt is @core.Scss,
    compile=source => {
      if is_sass_indent(source) {
        return to_css(parse_sheet(tokenize(sass_to_scss(source))))
      }
      to_css(parse_sheet(tokenize(source)))
    },
    compile_imports=(source, read) => compile_with_imports(source, read),
  )
}
