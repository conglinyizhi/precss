///|
/// 从编译后的 CSS 生成类型化 class wrapper（每个 class 一个 `pub fn`）
///
/// 这是**代码生成**，与 `compile_*` 编译主线是两件事，所以单独一个包：
/// 根包只保留 `generate_types` 门面入口转到这里，CLI 的 `gen-types` 也走这条。
///
/// 编译由调用方负责（根包门面做自动识别格式 + 编译），本包只做
/// 「CSS → 提取全部 class → 生成 `pub fn xxx() -> String { "xxx" }`」。
pub fn type_wrapper_from_css(css : String) -> String raise @core.CompileError {
  gen_type_wrapper(@scss.extract_classes_scss(css))
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
