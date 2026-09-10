///|
/// Warren 开发服务器的 Rabbita 静态资源入口。
///
/// 生产环境仍使用 cmd/ssg 生成 GitHub Pages 静态文件；这里仅服务本地开发。
#warnings("-alert_experimental")
async fn main {
  let api = @moonback.Module(ctx => {
    ctx.get("/benchmark/", (_req, res) => serve_benchmark(res))
    ctx.get("/getting-started/", (_req, res) => serve_getting_started(res))
  })
  let port = @env.get_env_var("WARREN_PORT")
    .map(port => @string.parse_uint(port).to_uint16())
    .unwrap_or(8111)
  let server = @rabbita_server.Server::Server(api~, port~)
  server.run_forever()
}

///|
async fn serve_benchmark(res : @moonback.Responder) -> Unit {
  serve_page(res, "benchmark/index.html", "benchmark page not found")
}

///|
async fn serve_getting_started(res : @moonback.Responder) -> Unit {
  serve_page(res, "getting-started/index.html", "getting started page not found")
}

///|
async fn serve_page(res : @moonback.Responder, relative_path : String, missing_message : String) -> Unit {
  let root = @env.get_env_var("WARREN_DIST").unwrap_or("public")
  let path = root + "/" + relative_path
  guard @fs.exists(path) else {
    res.send_text(missing_message, status=404)
    return
  }
  let html = @fs.read_file(path).text()
  let html = match @env.get_env_var("WARREN_CLIENT") {
    Some(client) if client != "" && !html.contains(client) =>
      inject_reload_client(html, client)
    _ => html
  }
  res.send_html(@moonback.Html::raw(html))
}

///|
fn inject_reload_client(html : String, client : String) -> String {
  let patch = "<script src=\"" + client + "\" defer></script>"
  if html.rev_find("</head>") is Some(index) {
    html[:index].to_owned() + patch + html[index:].to_owned()
  } else {
    html + patch
  }
}
