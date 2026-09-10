///|
/// CSS 透传引擎
///
/// 不转换，直接把 CSS 原样返回。用于格式被识别为普通 CSS 的输入。
pub fn css_engine() -> @core.Engine {
  @core.Engine::new(
    name=() => "css",
    supports=fmt => fmt is @core.Css,
    compile=source => source,
    compile_imports=(source, _read) => source,
  )
}
