///|
/// 从样式源生成类型化 wrapper（每个 class 一个 pub fn），供 rabbita 等前端做智能提示/校验
///
/// 流程：自动识别格式 → 编译成 css（展开 @each/插值成字面 .m-0 等）→ 提取全部 class
/// → 生成 `pub fn xxx() -> String { "xxx" }`。第三方在 build/SSG 里调用，写盘成 .mbt。
pub fn generate_types(source : String) -> String {
  let css = compile(source) catch { _ => "" }
  let classes = @scss.extract_classes_scss(css)
  gen_type_wrapper(classes)
}

///|
fn gen_type_wrapper(classes : Array[String]) -> String {
  let sb = StringBuilder()
  sb.write_string("pub struct TW { classes : Array[String] }\n\n")
  // 顶层工厂 @tw.tw()；其余函数使用 MoonBit 的类型方法语法
  sb.write_string("pub fn tw() -> TW { { classes: [] } }\n\n")
  sb.write_string(
    "pub fn TW::add(self : TW, c : String) -> TW {\n  self.classes.push(c)\n  self\n}\n\n",
  )
  sb.write_string(
    "pub fn TW::class(self : TW) -> String { self.classes.join(\" \") }\n\n",
  )
  let seen : Array[String] = []
  for c in classes {
    let f = class_to_fn(c)
    if contains_str(seen, f) == false {
      seen.push(f)
      sb.write_string("pub fn ")
      sb.write_string("TW::")
      sb.write_string(f)
      sb.write_string("(self : TW) -> TW { self.add(\"")
      sb.write_string(c)
      sb.write_string("\") }\n")
    }
  }
  sb.to_string()
}

///|
fn class_to_fn(s : String) -> String {
  let sb = StringBuilder()
  for ch in s {
    let is_id = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '_'
    if is_id {
      sb.write_string(ch.to_string())
    } else {
      sb.write_string("_")
    }
  }
  sb.to_string()
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
