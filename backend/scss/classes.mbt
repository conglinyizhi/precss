///|
/// 从 CSS / SCSS / SASS(缩进) 源码提取所有 class 选择器名（去 `.` 前缀）
///
/// 供 `cmd/cli gen-types` 用：把用户样式里的 utility class（如 `.text-red-500`）
/// 提取成 class 名（`text-red-500`），再生成类型化的 MoonBit wrapper。
pub fn extract_classes_scss(
  source : String,
) -> Array[String] raise @core.CompileError {
  let out : Array[String] = []
  collect_scss(parse_sheet(tokenize(source)), out)
  dedup(out)
}

///|
fn collect_scss(nodes : Array[Node], out : Array[String]) -> Unit {
  for n in nodes {
    match n {
      RuleSet(sel, body) => {
        for t in sel {
          if t.length() > 1 && t[0] == '.' {
            out.push(t[1:].to_owned())
          }
        }
        collect_scss(body, out)
      }
      AtRule(_, _, body) => collect_scss(body, out)
      _ => ()
    }
  }
}

///|
fn dedup(xs : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for x in xs {
    if contains_str(out, x) == false {
      out.push(x)
    }
  }
  out
}
