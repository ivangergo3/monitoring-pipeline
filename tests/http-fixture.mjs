// Local HTTP fixture for Bash integration tests; never contacts external hosts.
import http from "node:http";
import { writeFileSync } from "node:fs";
const server = http.createServer((request, response) => {
  if (request.url === "/redirect") {
    response.writeHead(302, { Location: "/ok" });
    response.end();
  } else if (request.url === "/slow" || request.url === "/slow-body") {
    if (request.url === "/slow-body") { response.writeHead(200); response.flushHeaders(); }
    setTimeout(() => { if (!response.destroyed) response.end("late"); }, 250);
  } else {
    response.writeHead(request.url === "/fail" ? 503 : 200);
    response.end("test");
  }
});
server.listen(0, "127.0.0.1", () => writeFileSync(process.argv[2], String(server.address().port)));
