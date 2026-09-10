///|
/// 从 LESS 源码提取所有 class 选择器名（去 `.` 前缀）
///
/// 供 `cmd/cli gen-types` 用（与 scss 侧对称）。
pub fn extract_classes_less(source : String) -> Array[String] {
  let out : Array[String] = []
  collect_less(parse_less(@scss.tokenize(source)), out)
  dedup(out)
}

///|
fn collect_less(nodes : Array[LessNode], out : Array[String]) -> Unit {
  for n in nodes {
    match n {
      RuleSet(sel, body) => {
        for t in sel {
          if t.length() > 1 && t[0] == '.' {
            out.push(t[1:].to_owned())
          }
        }
        collect_less(body, out)
      }
      AtRule(_, _, body) => collect_less(body, out)
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

///|
fn contains_str(xs : Array[String], x : String) -> Bool {
  for y in xs {
    if y == x {
      return true
    }
  }
  false
}
