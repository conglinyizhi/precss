///| SCSS 源码格式化
///
/// 复用 tokenize → parse_sheet 得到的公开 `Node` AST，把它重新打印成
/// 规范化的 SCSS 源码（2 空格缩进）。这是「源码级 formatter」，与编译
/// （to_css）不同：保留变量/mixin/控制流等预处理语法，只做排版。
///
/// 输入可以是完整 *.scss / *.sass 源码，也可以是零散片段。
/// 无法解析的部分由 parser 归入 `Raw`，这里原样透传。

///|
/// 格式化 SCSS 源码，返回规范化排版
pub fn format_scss(source : String) -> String raise @core.CompileError {
  let nodes = parse_sheet(tokenize(source))
  let sb = StringBuilder()
  let mut first = true
  for node in nodes {
    if first == false {
      sb.write_string("\n")
    }
    sb.write_string(node_to_scss(node, 0))
    first = false
  }
  sb.to_string()
}

///|
/// 把单个 Node 递归重打为 scss 文本（indent 为当前缩进层级）
fn node_to_scss(node : Node, indent : Int) -> String {
  let sb = StringBuilder()
  match node {
    RuleSet(sels, body) => {
      sb.write_string(spaces(indent))
      sb.write_string(sels.join(", "))
      sb.write_string(" {\n")
      write_body(sb, body, indent + 1)
      sb.write_string(spaces(indent))
      sb.write_string("}\n")
    }
    Decl(prop, vals) => sb.write_string(decl_line(indent, prop, vals))
    VarDef(name, vals) => sb.write_string(decl_line(indent, name, vals))
    MixinDef(name, params, body) => {
      sb.write_string(spaces(indent))
      sb.write_string("@mixin ")
      sb.write_string(name)
      sb.write_string("(")
      sb.write_string(params.join(", "))
      sb.write_string(") {\n")
      write_body(sb, body, indent + 1)
      sb.write_string(spaces(indent))
      sb.write_string("}\n")
    }
    MixinCall(name, args, content) => {
      sb.write_string(spaces(indent))
      sb.write_string("@include ")
      sb.write_string(name)
      sb.write_string("(")
      sb.write_string(args.join(", "))
      sb.write_string(")")
      if content.length() > 0 {
        sb.write_string(" {\n")
        write_body(sb, content, indent + 1)
        sb.write_string(spaces(indent))
        sb.write_string("}\n")
      } else {
        sb.write_string(";\n")
      }
    }
    Content => sb.write_string(spaces(indent) + "@content;\n")
    If(cond, then, else_) => {
      sb.write_string(spaces(indent))
      sb.write_string("@if ")
      sb.write_string(cond.join(" "))
      sb.write_string(" {\n")
      write_body(sb, then, indent + 1)
      sb.write_string(spaces(indent))
      sb.write_string("}")
      if else_.length() > 0 {
        sb.write_string(" @else {\n")
        write_body(sb, else_, indent + 1)
        sb.write_string(spaces(indent))
        sb.write_string("}")
      }
      sb.write_string("\n")
    }
    For(v, from, to, body) => {
      sb.write_string(spaces(indent))
      sb.write_string("@for ")
      sb.write_string(v)
      sb.write_string(" from ")
      sb.write_string(from.join(" "))
      sb.write_string(" to ")
      sb.write_string(to.join(" "))
      sb.write_string(" {\n")
      write_body(sb, body, indent + 1)
      sb.write_string(spaces(indent))
      sb.write_string("}\n")
    }
    Each(vars, list, body) => {
      sb.write_string(spaces(indent))
      sb.write_string("@each ")
      sb.write_string(vars.join(", "))
      sb.write_string(" in ")
      sb.write_string(list.join(" "))
      sb.write_string(" {\n")
      write_body(sb, body, indent + 1)
      sb.write_string(spaces(indent))
      sb.write_string("}\n")
    }
    While(cond, body) => {
      sb.write_string(spaces(indent))
      sb.write_string("@while ")
      sb.write_string(cond.join(" "))
      sb.write_string(" {\n")
      write_body(sb, body, indent + 1)
      sb.write_string(spaces(indent))
      sb.write_string("}\n")
    }
    Import(path) => sb.write_string(spaces(indent) + "@import \"\{path}\";\n")
    AtRule(name, args, body) => {
      sb.write_string(spaces(indent))
      if name.length() > 0 && name[0] == '@' {
        sb.write_string(name)
      } else {
        sb.write_string("@")
        sb.write_string(name)
      }
      if args.length() > 0 {
        sb.write_string(" ")
        sb.write_string(args.join(" "))
      }
      sb.write_string(" {\n")
      write_body(sb, body, indent + 1)
      sb.write_string(spaces(indent))
      sb.write_string("}\n")
    }
    Raw(text) => sb.write_string(spaces(indent) + text + "\n")
  }
  sb.to_string()
}

///|
/// 打印规则体（body 里各 node 已带各自尾部换行，直接追加即可）
fn write_body(sb : StringBuilder, body : Array[Node], indent : Int) -> Unit {
  for n in body {
    sb.write_string(node_to_scss(n, indent))
  }
}

///|
/// 一条声明/变量定义的规范排版：`indent prop: value;`
fn decl_line(indent : Int, prop : String, vals : Array[String]) -> String {
  let sb = StringBuilder()
  sb.write_string(spaces(indent))
  sb.write_string(prop)
  sb.write_string(": ")
  sb.write_string(vals.join(" "))
  sb.write_string(";\n")
  sb.to_string()
}

///|
/// 生成 indent 层级对应的缩进（每层 2 空格）
fn spaces(n : Int) -> String {
  let mut out = ""
  for _ in 0..<n {
    out = out + "  "
  }
  out
}
