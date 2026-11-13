// The dashboard shell is reusable. Monitoring only regenerates status.json.
export function safeUrl(value) {
  try {
    const url = new URL(value);
    return ["http:", "https:"].includes(url.protocol) && !url.username && !url.password ? url.href : null;
  } catch {
    return null;
  }
}

export function validateReport(report) {
  if (!report || typeof report.title !== "string" ||
      !Number.isFinite(Date.parse(report.generated_at)) ||
      !Array.isArray(report.applications) || !report.applications.length ||
      report.applications.some(app => !app || typeof app.name !== "string" ||
        !safeUrl(app.url) || !["healthy", "unhealthy", "unknown"].includes(app.status))) {
    throw new Error("Invalid monitoring report");
  }
  return report;
}

function element(tag, className = "", text = "") {
  const node = document.createElement(tag);
  node.className = className;
  node.textContent = text;
  return node;
}

function card(app) {
  const article = element("article", `card ${app.status}`);
  const top = element("div", "card-top");
  const icon = element("span", "service-icon", "↗");
  icon.setAttribute("aria-hidden", "true");
  const badge = element("span", "badge");
  badge.append(element("i"), document.createTextNode(app.status[0].toUpperCase() + app.status.slice(1)));
  top.append(icon, badge);
  const link = element("a", "endpoint", app.url);
  link.href = safeUrl(app.url);
  const metrics = element("div", "metrics");
  for (const [label, value] of [
    ["RESPONSE TIME", Number.isFinite(app.response_ms) ? `${app.response_ms.toLocaleString("en-US")} ms` : "—"],
    ["RESPONSE", app.http_status == null ? "No response" : `HTTP ${app.http_status}`],
  ]) {
    const metric = element("div");
    metric.append(element("span", "", label), element("strong", "", value));
    metrics.append(metric);
  }
  const checked = element("div", "checked", "Checked ");
  checked.append(element("time", "", app.checked_at || "unavailable"));
  article.append(top, element("h2", "", app.name), link, metrics,
    element("p", "detail", app.error || "Responded with the expected status code."), checked);
  return article;
}

export function render(report) {
  const apps = report.applications;
  const healthy = apps.filter(app => app.status === "healthy").length;
  const unhealthy = apps.filter(app => app.status === "unhealthy").length;
  const values = {
    title: report.title,
    overall: healthy === apps.length ? "All systems operational" :
      unhealthy ? "Some services are unavailable" : "Some checks are incomplete",
    generated: report.generated_at,
    healthy, unhealthy, unknown: apps.length - healthy - unhealthy,
    total: ` / ${apps.length}`,
  };
  for (const [id, value] of Object.entries(values)) document.getElementById(id).textContent = value;
  document.title = `${report.title} · Pulse`;
  document.getElementById("applications").replaceChildren(...apps.map(card));
  const url = safeUrl(report.run_url);
  const run = element(url ? "a" : "span", "", url ? "View workflow run ↗" : "Local preview");
  if (url) run.href = url;
  document.getElementById("run-link").replaceChildren(run);
}

// Injectable dependencies let tests exercise refresh failures without a browser
// or external services. Keep the last good snapshot when fetching fails.
export function createRefresh({ fetchReport, showReport, showError }) {
  let snapshot = null;
  return async () => {
    try {
      const report = validateReport(await fetchReport());
      if (!snapshot || report.generated_at !== snapshot.generated_at || report.run_url !== snapshot.run_url) {
        showReport(report);
      }
      snapshot = report;
      showError("");
    } catch {
      showError(snapshot ? "Could not refresh results. Showing the last loaded snapshot; retrying in 60 seconds." :
        "Could not load results. Retrying in 60 seconds. You can also open Raw JSON below.");
    }
  };
}

if (typeof document !== "undefined") {
  const refresh = createRefresh({
    async fetchReport() {
      const url = new URL("status.json", document.baseURI);
      url.searchParams.set("_", Date.now());
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 15000);
      try {
        const response = await fetch(url, { cache: "no-store", signal: controller.signal });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return await response.json();
      } finally {
        clearTimeout(timeout);
      }
    },
    showReport: render,
    showError(message) {
      const notice = document.getElementById("fetch-status");
      notice.textContent = message;
      notice.hidden = !message;
    },
  });
  async function poll() {
    await refresh();
    setTimeout(poll, 60000);
  }
  poll();
}
