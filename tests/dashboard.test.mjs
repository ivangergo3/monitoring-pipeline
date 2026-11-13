import test from "node:test";
import assert from "node:assert/strict";
import { createRefresh, safeUrl, validateReport } from "../site/dashboard.mjs";

const report = {
  title: "Demo", generated_at: "2026-11-13T17:28:58+00:00", run_url: "",
  applications: [{ name: "Demo API", url: "https://example.com/health", status: "healthy" }],
};

test("reject executable URLs and credentials", () => {
  for (const value of ["javascript:alert(1)", "data:text/html,test", "https://user:pass@example.com", "invalid"]) {
    assert.equal(safeUrl(value), null);
  }
  assert.equal(safeUrl("https://example.com/health"), "https://example.com/health");
});

test("reject invalid snapshots before replacing visible results", () => {
  assert.equal(validateReport(report), report);
  for (const value of [null, {}, { ...report, generated_at: "invalid" }, { ...report, applications: [] },
    { ...report, applications: [{ ...report.applications[0], status: "made-up" }] }]) {
    assert.throws(() => validateReport(value));
  }
});

test("refresh preserves last good results on failure and recovers without page reload", async () => {
  let current = report;
  const shown = [];
  const errors = [];
  const refresh = createRefresh({
    fetchReport: async () => { if (current instanceof Error) throw current; return current; },
    showReport: value => shown.push(value), showError: value => errors.push(value),
  });
  await refresh();
  await refresh();
  assert.equal(shown.length, 1); // Unchanged data doesn't rebuild the DOM.
  current = new Error("Network unavailable");
  await refresh();
  assert.equal(shown.length, 1);
  assert.match(errors.at(-1), /last loaded snapshot/);
  current = { ...report, generated_at: "2026-11-13T18:28:58+00:00" };
  await refresh();
  assert.equal(shown.length, 2);
  assert.equal(errors.at(-1), "");
});

test("first-load failure shows an error instead of an operational status", async () => {
  let message;
  const refresh = createRefresh({
    fetchReport: async () => { throw new Error("HTTP 404"); },
    showReport: () => assert.fail("Should not render a failed response"),
    showError: value => { message = value; },
  });
  await refresh();
  assert.match(message, /Could not load results/);
});
