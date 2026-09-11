///|
/// SCSS 诊断：检测同一规则内"同名同值"的重复声明
///
/// 纯诊断函数，不改动编译结果。用于提示用户：重复的 `prop: val` 可能是手误
/// （LESS 会去重同名同值；scss 保留但输出与前一条相同，属无意义重复）。
/// 返回消息数组（空表示无问题）。
pub fn diagnose_scss(source : String) -> Array[String] raise @core.CompileError {
  let warns : Array[String] = []
  let nodes = parse_sheet(tokenize(source))
  scan_scss_block(nodes, "", warns)
  warns
}

///|
/// 扫描一块（prefix 为当前选择器前缀，"" 表示顶层）
fn scan_scss_block(
  nodes : Array[Node],
  prefix : String,
  warns : Array[String],
) -> Unit {
  for node in nodes {
    match node {
      RuleSet(sel, body) =>
        scan_rule_scss(body, join_prefix(prefix, sel), warns)
      AtRule(_, _, body) => scan_scss_block(body, prefix, warns)
      _ => ()
    }
  }
}

///|
/// 扫描一个规则体，检测同名同值重复声明
fn scan_rule_scss(
  body : Array[Node],
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
        scan_rule_scss(child, join_prefix(pref, sel), warns)
      AtRule(_, _, child) => scan_rule_scss(child, pref, warns)
      _ => ()
    }
  }
}

///|
/// 拼接选择器前缀（& 此时已不重要，仅作提示用）
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
