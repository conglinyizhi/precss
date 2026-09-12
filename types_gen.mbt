///|
/// 从样式源生成类型化 wrapper（每个 class 一个 pub fn），供 rabbita 等前端做智能提示/校验
///
/// 流程：自动识别格式 → 编译成 css（展开 @each/插值成字面 .m-0 等）→ 提取全部 class
/// → 生成 `pub fn xxx() -> String { "xxx" }`。第三方在 build/SSG 里调用，写盘成 .mbt。
///
/// 编译错误必须往上传：以前用 catch 吞成空串，结果样式写错时会静默生成
/// 一个没有任何 class 的 wrapper，调用方完全看不出是编译失败了。
///
/// 实现在 `conglinyizhi/precss/gen`（代码生成与编译主线分属两件事），
/// 这里保留门面入口，签名不变。
pub fn generate_types(source : String) -> String raise @core.CompileError {
  @gen.type_wrapper_from_css(compile(source))
}
