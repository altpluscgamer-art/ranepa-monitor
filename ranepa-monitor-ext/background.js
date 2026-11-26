// Фоновая проверка: раз в 2 минуты читает локальный монитор и красит значок.
const STATUS_URL = "http://localhost:8765/status";

async function check() {
  try {
    const resp = await fetch(STATUS_URL, { cache: "no-store" });
    const data = await resp.json();
    const list = Array.isArray(data.services) ? data.services : [];
    const fails = list.filter(s => s.verdict === "HTTP_5XX" || s.verdict === "NET_FAIL").length;
    const warns = list.filter(s => s.verdict === "WARN_4XX").length;
    if (fails > 0) {
      chrome.action.setBadgeBackgroundColor({ color: "#c62828" });
      chrome.action.setBadgeText({ text: String(fails) });
    } else if (warns > 0) {
      chrome.action.setBadgeBackgroundColor({ color: "#e6a700" });
      chrome.action.setBadgeText({ text: String(warns) });
    } else {
      chrome.action.setBadgeBackgroundColor({ color: "#1a7f37" });
      chrome.action.setBadgeText({ text: "" });
    }
    chrome.storage.local.set({
      updated: data.updated || "",
      fails: fails,
      warns: warns,
      ok: list.length - fails - warns,
      services: list,
      serverOk: true
    });
  } catch (e) {
    chrome.action.setBadgeBackgroundColor({ color: "#8a8a8a" });
    chrome.action.setBadgeText({ text: "?" });
    chrome.storage.local.set({ serverOk: false });
  }
}

chrome.alarms.create("check", { delayInMinutes: 0.2, periodInMinutes: 2 });
chrome.alarms.onAlarm.addListener(a => { if (a.name === "check") check(); });
check();
