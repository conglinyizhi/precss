///|
/// LESS 诊断：检测同一规则内"同名同值"的重复声明
///
/// 纯诊断函数，不改动编译结果。LESS 编译会对同名同值声明去重（保留最后一次），
/// 这里提示用户避免手误产生预期不符。
pub fn diagnose_less(source : String) -> Array[String] raise @core.CompileError {
  let warns : Array[String] = []
  let nodes = parse_less(@scss.tokenize(source))
  scan_less_block(nodes, "", warns)
  warns
}

///|
/// 扫描一块（prefix 为当前选择器前缀，"" 表示顶层）
fn scan_less_block(
  nodes : Array[LessNode],
  prefix : String,
  warns : Array[String],
) -> Unit {
  for node in nodes {
    match node {
      RuleSet(sel, body) =>
        scan_rule_less(body, join_prefix(prefix, sel), warns)
      AtRule(_, _, body) => scan_less_block(body, prefix, warns)
      _ => ()
    }
  }
}

///|
/// 扫描一个规则体，检测同名同值重复声明
fn scan_rule_less(
  body : Array[LessNode],
  pref : String,
  warns : Array[String],
) -> Unit {
  let seen : Array[(String, String)] = []
  for node in body {
    match node {
      Decl(prop, val) => {
        let v = val.join(" ").trim().to_owned()
        if has_seen(seen, prop, v) {
          warns.push("#\{pref}: duplicate property \"\{prop}: \{v}\"")
        } else {
          seen.push((prop, v))
        }
      }
      RuleSet(sel, child) =>
        scan_rule_less(child, join_prefix(pref, sel), warns)
      AtRule(_, _, child) => scan_rule_less(child, pref, warns)
      _ => ()
    }
  }
}

///|
fn join_prefix(parent : String, sel : Array[String]) -> String {
  let s = sel.join(" ")
  if parent.length() == 0 {
    s
  } else {
    parent + " " + s
  }
}

///|
fn has_seen(
  seen : Array[(String, String)],
  prop : String,
  val : String,
) -> Bool {
  for s in seen {
    if s.0 == prop && s.1 == val {
      return true
    }
  }
  false
}
