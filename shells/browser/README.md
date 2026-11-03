# browser 壳（未开始）

无 GUI 平台（麒麟/统信、龙芯、海光、服务器）的兜底路径：
`mindmodel serve` 起一个本地 HTTP 服务，`/api/scan` 返回 JSON，浏览器打开 `ui/` 渲染。

依赖 P3 的 `server` crate（core 起服务 + OpenAI 兼容代理），当前未实现。
见 shells/README.md 与 DESIGN.md。
