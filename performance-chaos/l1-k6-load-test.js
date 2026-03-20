// k6 basic load test — HTTP GET/POST with checks and metrics
// Docs: https://grafana.com/docs/k6/latest/
//
// Run:
//   k6 run l1-k6-load-test.js
//   k6 run --vus 50 --duration 5m l1-k6-load-test.js
//   k6 run --out influxdb=http://localhost:8086/k6 l1-k6-load-test.js
//   k6 run --out json=results.json l1-k6-load-test.js

import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend, Counter } from "k6/metrics";

// ---------------------------------------------------------------------------
// Custom metrics
// ---------------------------------------------------------------------------
const errorRate = new Rate("error_rate");
const apiLatency = new Trend("api_latency", true); // true = time metric (ms)
const requestsTotal = new Counter("requests_total");

// ---------------------------------------------------------------------------
// Test options
// ---------------------------------------------------------------------------
export const options = {
  // Constant load: 20 virtual users for 1 minute
  vus: 20,
  duration: "1m",

  // Success thresholds — test fails if these are breached
  thresholds: {
    // 95% of requests must complete below 500ms
    http_req_duration: ["p(95)<500", "p(99)<1000"],
    // Error rate must stay below 1%
    error_rate: ["rate<0.01"],
    // All checks must pass
    checks: ["rate>0.99"],
  },
};

// ---------------------------------------------------------------------------
// Test setup — runs once before all VUs start
// ---------------------------------------------------------------------------
export function setup() {
  const BASE_URL = __ENV.BASE_URL || "http://localhost:3000";

  // Authenticate and get token for use in default function
  const loginRes = http.post(
    `${BASE_URL}/api/auth/login`,
    JSON.stringify({ username: "testuser", password: "testpassword" }),
    { headers: { "Content-Type": "application/json" } }
  );

  check(loginRes, {
    "login status 200": (r) => r.status === 200,
    "login has token": (r) => r.json("token") !== undefined,
  });

  return {
    baseUrl: BASE_URL,
    token: loginRes.json("token") || "",
  };
}

// ---------------------------------------------------------------------------
// Default function — called repeatedly by each VU
// ---------------------------------------------------------------------------
export default function (data) {
  const BASE_URL = data.baseUrl;
  const TOKEN = data.token;

  const headers = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${TOKEN}`,
  };

  // --- Request 1: GET list endpoint ---
  const listStart = Date.now();
  const listRes = http.get(`${BASE_URL}/api/items`, { headers });
  apiLatency.add(Date.now() - listStart);
  requestsTotal.add(1);

  const listOk = check(listRes, {
    "GET /api/items status 200": (r) => r.status === 200,
    "GET /api/items has body": (r) => r.body && r.body.length > 0,
    "GET /api/items response time < 200ms": (r) => r.timings.duration < 200,
  });
  errorRate.add(!listOk);

  sleep(0.5);

  // --- Request 2: POST create item ---
  const payload = JSON.stringify({
    name: `item-${__VU}-${__ITER}`,
    value: Math.floor(Math.random() * 1000),
    timestamp: new Date().toISOString(),
  });

  const createStart = Date.now();
  const createRes = http.post(`${BASE_URL}/api/items`, payload, { headers });
  apiLatency.add(Date.now() - createStart);
  requestsTotal.add(1);

  const createOk = check(createRes, {
    "POST /api/items status 201": (r) => r.status === 201,
    "POST /api/items has id": (r) => r.json("id") !== undefined,
    "POST /api/items response time < 500ms": (r) => r.timings.duration < 500,
  });
  errorRate.add(!createOk);

  sleep(0.5);

  // --- Request 3: GET single item ---
  const itemId = createRes.json("id") || "1";
  const getStart = Date.now();
  const getRes = http.get(`${BASE_URL}/api/items/${itemId}`, { headers });
  apiLatency.add(Date.now() - getStart);
  requestsTotal.add(1);

  const getOk = check(getRes, {
    "GET /api/items/:id status 200": (r) => r.status === 200,
    "GET /api/items/:id correct id": (r) => r.json("id") == itemId,
  });
  errorRate.add(!getOk);

  sleep(1);

  // --- Request 4: DELETE item ---
  const deleteStart = Date.now();
  const deleteRes = http.del(`${BASE_URL}/api/items/${itemId}`, null, {
    headers,
  });
  apiLatency.add(Date.now() - deleteStart);
  requestsTotal.add(1);

  const deleteOk = check(deleteRes, {
    "DELETE /api/items/:id status 204": (r) =>
      r.status === 204 || r.status === 200,
  });
  errorRate.add(!deleteOk);

  sleep(1);
}

// ---------------------------------------------------------------------------
// Teardown — runs once after all VUs finish
// ---------------------------------------------------------------------------
export function teardown(data) {
  console.log(`Test completed. Base URL: ${data.baseUrl}`);
  console.log(`Total requests tracked in custom counter: see summary`);
}

// ---------------------------------------------------------------------------
// Custom summary output
// ---------------------------------------------------------------------------
export function handleSummary(data) {
  const p95 = data.metrics.http_req_duration?.values?.["p(95)"] || 0;
  const p99 = data.metrics.http_req_duration?.values?.["p(99)"] || 0;
  const errRate = data.metrics.error_rate?.values?.rate || 0;
  const totalReqs = data.metrics.http_reqs?.values?.count || 0;
  const rps = data.metrics.http_reqs?.values?.rate || 0;

  const summary = {
    timestamp: new Date().toISOString(),
    total_requests: totalReqs,
    requests_per_second: rps.toFixed(2),
    p95_latency_ms: p95.toFixed(2),
    p99_latency_ms: p99.toFixed(2),
    error_rate_pct: (errRate * 100).toFixed(3),
    passed: data.state?.testRunDuration > 0,
  };

  return {
    stdout: JSON.stringify(summary, null, 2) + "\n",
    "summary.json": JSON.stringify(data, null, 2),
  };
}
