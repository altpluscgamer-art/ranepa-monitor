document.addEventListener("DOMContentLoaded", load);

async function load() {
  const listEl = document.getElementById("list");
  const metaEl = document.getElementById("meta");
  try {
    const resp = await fetch("http://localhost:8765/status", { cache: "no-store" });
    const data = await resp.json();
    const list = (Array.isArray(data.services) ? data.services : []).slice();
    const order = { NET_FAIL: 0, HTTP_5XX: 1, WARN_4XX: 2, AUTH: 3, OK: 4 };
    list.sort((a, b) => (order[a.verdict] !== undefined ? order[a.verdict] : 9) -
                        (order[b.verdict] !== undefined ? order[b.verdict] : 9));
    metaEl.textContent = "Проверено: " + (data.updated || "—") + " · Сервисов: " + list.length;
    listEl.innerHTML = "";
    for (const s of list) {
      const div = document.createElement("div");
      div.className = "row " + clsFor(s.verdict);

      const left = document.createElement("span");
      left.className = "name";
      left.textContent = s.service;

      const chk = document.createElement("button");
      chk.className = "chk";
      chk.title = "Проверить только этот сервис";
      chk.textContent = "\u21bb";
      chk.addEventListener("click", async () => {
        chk.disabled = true;
        chk.textContent = "...";
        try {
          await fetch("http://localhost:8765/check?svc=" + encodeURIComponent(s.service),
                      { cache: "no-store" });
        } catch (e) { /* сервер не отвечает — покажем это при перезагрузке */ }
        load();
      });

      const lat = document.createElement("span");
      lat.className = "lat";
      lat.textContent = (typeof s.latency_ms === "number" && s.latency_ms > 0)
                        ? Math.round(s.latency_ms) + " мс" : "";

      const right = document.createElement("span");
      right.className = "code";
      right.textContent = s.status || s.verdict;

      div.appendChild(left);
      div.appendChild(chk);
      div.appendChild(lat);
      div.appendChild(right);
      listEl.appendChild(div);
    }
    loadHist();
  } catch (e) {
    metaEl.textContent = "Сервер мониторинга не отвечает";
    listEl.innerHTML = '<div class="row fail"><span class="name">Запустите run_monitor.bat</span></div>';
  }
}

async function loadHist() {
  const histEl = document.getElementById("hist");
  if (!histEl) return;
  try {
    const resp = await fetch("http://localhost:8765/hist", { cache: "no-store" });
    const data = await resp.json();
    const services = Array.isArray(data.services) ? data.services : [];
    services.sort(function (a, b) { return String(a.service).localeCompare(String(b.service)); });
    const cw = 12, ch = 8;
    const w = 24 * cw, h = services.length * ch + 4;
    let svg = '<svg width="' + w + '" height="' + h + '" xmlns="http://www.w3.org/2000/svg">';
    services.forEach(function (s, ri) {
      const cells = Array.isArray(s.cells) ? s.cells : [];
      for (let ci = 0; ci < 24; ci++) {
        const v = (cells.length >= 24) ? cells[ci] : 0;
        const col = (v === 1) ? "#a5d6a7" : (v === 2) ? "#ffd54f" : (v === 3) ? "#e57373" : "#eceff1";
        svg += '<rect x="' + (ci * cw) + '" y="' + (2 + ri * ch) + '" width="' + (cw - 1) + '" height="' + (ch - 1) + '" rx="1.5" fill="' + col + '"><title>' + s.service + '</title></rect>';
      }
    });
    svg += '</svg>';
    histEl.innerHTML = '<div class="histcap">Доступность за 6 часов — клетка = 15 минут: зелёный = успех, жёлтый = 4xx, красный = сбой, серый = нет данных</div>' + svg;
  } catch (e) {
    histEl.innerHTML = "";
  }
}

function clsFor(v) {
  if (v === "HTTP_5XX" || v === "NET_FAIL") return "fail";
  if (v === "WARN_4XX") return "warn";
  return "ok";
}

document.getElementById("refbtn").addEventListener("click", load);
document.getElementById("openbtn").addEventListener("click", () => {
  chrome.tabs.create({ url: "http://localhost:8765/" });
});
