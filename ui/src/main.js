// MindModel 前端入口。两种壳共用：
// - Tauri 壳：通过 @tauri-apps/api 的 invoke 调 Rust command（scan/engines）
// - 浏览器兜底：调本地 HTTP 服务（/api/scan 等），供无 GUI 平台使用
// 算法全部在 Rust 侧，这里只做展示与交互。

import "./style.css";

// 判断是否跑在 Tauri 里（window.__TAURI_INTERNALS__ 由 Tauri 注入）
const inTauri = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

// 动态加载 Tauri API，避免浏览器壳强制依赖 @tauri-apps/api
async function getInvoke() {
  if (!inTauri) return null;
  try {
    const api = await import("@tauri-apps/api/core");
    return api.invoke;
  } catch {
    return null;
  }
}

async function call(name, args = {}) {
  const invoke = await getInvoke();
  if (invoke) {
    return invoke(name, args);
  }
  // 浏览器兜底：POST 到本地服务
  const res = await fetch(`/api/${name}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  return res.json();
}

const app = document.getElementById("app");

function el(tag, cls, text) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}

function fmtGB(v) {
  return v == null ? "—" : v.toFixed(1) + " GB";
}

function fmtBW(v) {
  return v == null ? "—" : Math.round(v) + " GB/s";
}

async function renderScan() {
  const s = await call("scan");
  const sec = el("section", "card");
  sec.appendChild(el("h2", null, "这台机器能跑什么"));
  const grid = el("div", "grid");
  const cell = (k, v) => {
    const c = el("div", "cell");
    c.appendChild(el("div", "cell-k", k));
    c.appendChild(el("div", "cell-v", v));
    return c;
  };
  grid.appendChild(cell("芯片", s.chip));
  grid.appendChild(cell("机型", s.machine_model));
  grid.appendChild(cell("系统", s.os));
  grid.appendChild(cell("CPU 核心", `${s.total_cores}（性能 ${s.perf_cores} / 能效 ${s.eff_cores}）`));
  grid.appendChild(cell("GPU", `${s.gpu_name} · ${s.gpu_cores} 核`));
  grid.appendChild(cell("统一内存", fmtGB(s.ram_gb)));
  grid.appendChild(cell("工作集", fmtGB(s.working_set_gb)));
  grid.appendChild(cell("预算", fmtGB(s.budget_gb)));
  grid.appendChild(cell("实测带宽", fmtBW(s.bandwidth)));
  grid.appendChild(cell("磁盘", `可用 ${fmtGB(s.disk_free_gb)} / 共 ${fmtGB(s.disk_total_gb)}`));
  sec.appendChild(grid);

  const fit = el("div", "fit");
  fit.appendChild(el("strong", null, `${s.fit_count} / ${s.total_models}`));
  fit.appendChild(el("span", null, " 个内置候选装得下"));
  sec.appendChild(fit);

  const prov = el("div", "prov", s.provenance);
  sec.appendChild(prov);
  return sec;
}

async function renderEngines() {
  const list = await call("engines");
  const sec = el("section", "card");
  sec.appendChild(el("h2", null, "推理后端"));
  const rows = el("div", "rows");
  for (const b of list) {
    const r = el("div", "row");
    r.appendChild(el("div", "row-name", b.name));
    const badge = el("span", "badge " + (b.installed ? "ok" : "off"), b.installed ? "已安装" : "未安装");
    r.appendChild(badge);
    r.appendChild(el("span", "row-accel", b.accel));
    r.appendChild(el("span", "row-ver", b.version || "—"));
    r.appendChild(el("div", "row-role", b.role));
    rows.appendChild(r);
  }
  sec.appendChild(rows);
  return sec;
}

async function render() {
  app.replaceChildren();
  const head = el("header", null);
  head.appendChild(el("h1", null, "MindModel"));
  head.appendChild(el("div", "sub", "本机模型顾问 · 跨平台"));
  app.appendChild(head);

  try {
    app.appendChild(await renderScan());
    app.appendChild(await renderEngines());
  } catch (e) {
    const err = el("section", "card err");
    err.appendChild(el("p", null, "读取失败：" + e.message));
    err.appendChild(el("p", "hint", inTauri
      ? "请确认应用的 Rust 侧已编译并注入了 command。"
      : "浏览器兜底需要本地服务在运行（mindmodel serve），见 shells/browser/README.md。"));
    app.appendChild(err);
  }

  const foot = el("footer", null);
  foot.appendChild(el("span", null, "算法在本地跑，不联网。"));
  app.appendChild(foot);
}

render();
