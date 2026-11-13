"""Config-driven HTTP checks and latest-results dashboard. Python standard library only."""

import argparse
from datetime import datetime, timezone
import html
import json
import os
from pathlib import Path
import re
import socket
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def load_config(path):
    config = json.loads(Path(path).read_text())
    apps = config.get("applications")
    if not isinstance(apps, list) or not 1 <= len(apps) <= 256:
        raise ValueError("applications must contain 1–256 apps")
    seen = set()
    for app in apps:
        app_id = app.get("id", "")
        if not isinstance(app_id, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", app_id) or app_id in seen:
            raise ValueError("Every app needs a unique lowercase id using letters, numbers and hyphens")
        seen.add(app_id)
        if not isinstance(app.get("name"), str) or not app["name"].strip():
            raise ValueError(f"{app_id}: name is required")
        url = urllib.parse.urlsplit(app.get("url", ""))
        if url.scheme not in ("http", "https") or not url.hostname or url.username or url.password:
            raise ValueError(f"{app_id}: use an HTTP(S) URL without credentials")
        expected = app.get("expected_status", 200)
        if type(expected) is not int or not 100 <= expected <= 599:
            raise ValueError(f"{app_id}: expected_status must be an HTTP status code")
        timeout = app.get("timeout_seconds", 10)
        if type(timeout) not in (int, float) or not 0 < timeout <= 60:
            raise ValueError(f"{app_id}: timeout_seconds must be greater than 0 and at most 60")
    return config


def check(app):
    result = {"id": app["id"], "status": "unhealthy", "checked_at": now(),
              "http_status": None, "response_ms": None, "error": None}
    started = time.perf_counter()
    request = urllib.request.Request(app["url"], headers={"User-Agent": "monitoring-pipeline/1.0", "Cache-Control": "no-cache"})
    try:
        with urllib.request.urlopen(request, timeout=app.get("timeout_seconds", 10)) as response:
            result["http_status"] = response.status
    except urllib.error.HTTPError as error:
        result["http_status"] = error.code
        error.close()
    except (urllib.error.URLError, TimeoutError, socket.timeout, OSError) as error:
        result["error"] = str(error)
    result["response_ms"] = round((time.perf_counter() - started) * 1000)
    if result["http_status"] == app.get("expected_status", 200):
        result["status"] = "healthy"
    elif result["http_status"] is not None:
        result["error"] = f"Expected HTTP {app.get('expected_status', 200)}, received {result['http_status']}"
    return result


def build(config, results_dir, output_dir):
    apps = []
    for app in config["applications"]:
        path = Path(results_dir) / f"{app['id']}.json"
        try:
            result = json.loads(path.read_text())
            if result.get("id") != app["id"] or result.get("status") not in ("healthy", "unhealthy"):
                raise ValueError("Invalid result")
        except (OSError, ValueError, TypeError, AttributeError):
            result = {"status": "unknown", "checked_at": None, "http_status": None,
                      "response_ms": None, "error": "No valid result was produced by this runner"}
        apps.append({**app, **result})
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    run_url = f"https://github.com/{repo}/actions/runs/{run_id}" if repo and run_id else ""
    report = {"title": config.get("title", "Application health"), "generated_at": now(),
              "run_url": run_url, "applications": apps}
    output = Path(output_dir)
    output.mkdir(parents=True, exist_ok=True)
    (output / "status.json").write_text(json.dumps(report, indent=2) + "\n")
    cards = []
    esc = lambda value: html.escape(str(value), quote=True)
    for app in apps:
        status = app["status"]
        latency = f"{app['response_ms']:,} ms" if app.get("response_ms") is not None else "—"
        code = f"HTTP {app['http_status']}" if app.get("http_status") is not None else "No response"
        cards.append(f'''<article class="card {status}">
          <div class="card-top"><span class="service-icon" aria-hidden="true">↗</span><span class="badge"><i></i>{status.title()}</span></div>
          <h2>{esc(app['name'])}</h2><a class="endpoint" href="{esc(app['url'])}">{esc(app['url'])}</a>
          <div class="metrics"><div><span>RESPONSE TIME</span><strong>{latency}</strong></div><div><span>RESPONSE</span><strong>{code}</strong></div></div>
          <p class="detail">{esc(app.get('error') or 'Responded with the expected status code.')}</p>
          <div class="checked">Checked <time>{esc(app.get('checked_at') or 'unavailable')}</time></div></article>''')
    healthy = sum(app["status"] == "healthy" for app in apps)
    unhealthy = sum(app["status"] == "unhealthy" for app in apps)
    unknown = len(apps) - healthy - unhealthy
    overall = "All systems operational" if healthy == len(apps) else ("Some services are unavailable" if unhealthy else "Some checks are incomplete")
    template = (ROOT / "site/index.html").read_text()
    values = {"TITLE": esc(report["title"]), "CARDS": "\n".join(cards), "OVERALL": overall,
              "HEALTHY": str(healthy), "UNHEALTHY": str(unhealthy), "UNKNOWN": str(unknown),
              "TOTAL": str(len(apps)), "GENERATED": esc(report["generated_at"]),
              "RUN_LINK": f'<a href="{esc(run_url)}">View workflow run ↗</a>' if run_url else '<span>Local preview</span>'}
    template = re.sub(r"\{\{([A-Z_]+)\}\}", lambda match: values[match[1]], template)
    (output / "index.html").write_text(template)
    (output / ".nojekyll").touch()
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["matrix", "check", "build", "local"])
    parser.add_argument("--config", default=str(ROOT / "apps.json"))
    parser.add_argument("--app")
    parser.add_argument("--results", default="results")
    parser.add_argument("--output", default="dist")
    args = parser.parse_args()
    config = load_config(args.config)
    if args.command == "matrix":
        print(json.dumps({"include": [{"id": app["id"]} for app in config["applications"]]}, separators=(",", ":")))
    elif args.command in ("check", "local"):
        apps = config["applications"]
        if args.command == "check":
            apps = [app for app in apps if app["id"] == args.app]
            if not apps:
                parser.error("--app must match a configured application id")
        Path(args.results).mkdir(parents=True, exist_ok=True)
        for app in apps:
            result = check(app)
            (Path(args.results) / f"{app['id']}.json").write_text(json.dumps(result, indent=2) + "\n")
            print(f"{app['id']}: {result['status']} ({result['response_ms']} ms)")
        if args.command == "local":
            build(config, args.results, args.output)
    else:
        build(config, args.results, args.output)


if __name__ == "__main__":
    main()
