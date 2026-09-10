///|
#export_name("compile_scss")
pub fn compile_scss(src : String) -> String {
  @mb.compile_scss(src) catch {
    _ => ""
  }
}

///|
#export_name("compile_less")
pub fn compile_less(src : String) -> String {
  @mb.compile_less(src) catch {
    _ => ""
  }
}

///|
#export_name("minify_css")
pub fn minify_css(src : String) -> String {
  @mb.minify_css(src)
}
