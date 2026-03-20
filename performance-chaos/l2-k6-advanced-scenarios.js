// k6 advanced load test — stages, thresholds, checks, groups, scenarios
// Covers: ramp-up/down, spike, soak, breakpoint patterns
// Docs: https://grafana.com/docs/k6/latest/using-k6/scenarios/
//
// Run:
//   k6 run l2-k6-advanced-scenarios.js
//   k6 run --env SCENARIO=spike l2-k6-advanced-scenarios.js
//   k6 run --out influxdb=http://localhost:8086/k6 l2-k6-advanced-scenarios.js
//   k6 run --out experimental-prometheus-rw=http://localhost:9090/api/v1/write l2-k6-advanced-scenarios.js

import http from "k6/http";
import { check, group, sleep, fail } from "k6";
import { Rate, Trend, Counter, Gauge } from "k6/metrics";
import { randomIntBetween, randomItem } from "https://jslib.k6.io/k6-utils/1.4.0/index.js";
import { SharedArray } from "k6/data";
import exec from "k6/execution";

// ---------------------------------------------------------------------------
// Custom metrics
// ---------------------------------------------------------------------------
const httpErrors        = new Rate("http_errors");
const dbQueryLatency    = new Trend("db_query_latency", true);
const activeUsers       = new Gauge("active_users");
const successfulOrders  = new Counter("successful_orders");
const cacheHitRate      = new Rate("cache_hit_rate");

// ---------------------------------------------------------------------------
// Shared test data (loaded once, shared across VUs)
// ---------------------------------------------------------------------------
const testUsers = new SharedArray("users", () => {
  // In production, load from a CSV file: JSON.parse(open("./users.json"))
  return Array.from({ length: 100 }, (_, i) => ({
    username: `user${i + 1}`,
    password: "password123",
  }));
});

const productIds = new SharedArray("products", () =>
  Array.from({ length: 50 }, (_, i) => i + 1)
);

// ---------------------------------------------------------------------------
// Scenario selector via env var
// ---------------------------------------------------------------------------
const SCENARIO = __ENV.SCENARIO || "ramp";

const scenarioMap = {
  // Gradual ramp-up to 100 VUs, sustain, ramp-down
  ramp: {
    rampUp: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "2m", target: 20 },
        { duration: "5m", target: 100 },
        { duration: "2m", target: 100 },
        { duration: "2m", target: 0 },
      ],
      gracefulRampDown: "30s",
      exec: "defaultScenario",
    },
  },

  // Spike test: sudden traffic burst
  spike: {
    spikeTest: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "1m",  target: 10  },  // baseline
        { duration: "30s", target: 500 },  // spike
        { duration: "2m",  target: 500 },  // hold spike
        { duration: "30s", target: 10  },  // recover
        { duration: "1m",  target: 10  },  // verify baseline
        { duration: "30s", target: 0   },
      ],
      gracefulRampDown: "30s",
      exec: "defaultScenario",
    },
  },

  // Soak test: sustained moderate load for long duration
  soak: {
    soakTest: {
      executor: "constant-vus",
      vus: 50,
      duration: "2h",
      exec: "defaultScenario",
    },
  },

  // Breakpoint: keep increasing until system breaks
  breakpoint: {
    breakpointTest: {
      executor: "ramping-arrival-rate",
      startRate: 10,
      timeUnit: "1s",
      preAllocatedVUs: 50,
      maxVUs: 500,
      stages: [
        { duration: "5m",  target: 50  },
        { duration: "5m",  target: 100 },
        { duration: "5m",  target: 200 },
        { duration: "5m",  target: 400 },
      ],
      exec: "defaultScenario",
    },
  },

  // Multi-scenario: browse + checkout + admin concurrently
  multi: {
    browseScenario: {
      executor: "constant-arrival-rate",
      rate: 50,
      timeUnit: "1s",
      duration: "5m",
      preAllocatedVUs: 30,
      maxVUs: 100,
      exec: "browseScenario",
      tags: { scenario: "browse" },
    },
    checkoutScenario: {
      executor: "constant-arrival-rate",
      rate: 10,
      timeUnit: "1s",
      duration: "5m",
      preAllocatedVUs: 10,
      maxVUs: 50,
      exec: "checkoutScenario",
      tags: { scenario: "checkout" },
    },
    adminScenario: {
      executor: "per-vu-iterations",
      vus: 3,
      iterations: 20,
      maxDuration: "5m",
      exec: "adminScenario",
      tags: { scenario: "admin" },
    },
  },
};

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------
export const options = {
  scenarios: scenarioMap[SCENARIO] || scenarioMap.ramp,

  thresholds: {
    // Global latency thresholds
    http_req_duration:                ["p(50)<200", "p(95)<500", "p(99)<1500"],
    // Scenario-specific thresholds via tags
    "http_req_duration{scenario:browse}":   ["p(95)<300"],
    "http_req_duration{scenario:checkout}": ["p(95)<800"],
    "http_req_duration{scenario:admin}":    ["p(95)<1000"],
    // Error rates
    http_errors:      ["rate<0.01"],          // <1% overall errors
    http_req_failed:  ["rate<0.02"],          // <2% failed requests
    checks:           ["rate>0.98"],          // >98% checks pass
    // Custom metrics
    db_query_latency: ["p(95)<100"],          // DB queries under 100ms at p95
    cache_hit_rate:   ["rate>0.80"],          // >80% cache hit rate
  },

  // Graceful stop timeout
  gracefulStop: "30s",

  // HTTP settings
  noConnectionReuse: false,
  userAgent: "k6-advanced-test/1.0",

  // TLS
  insecureSkipTLSVerify: false,
};

// ---------------------------------------------------------------------------
// Utility: authenticate and return headers
// ---------------------------------------------------------------------------
function authenticate(baseUrl) {
  const user = randomItem(testUsers);
  const res = http.post(
    `${baseUrl}/api/auth/login`,
    JSON.stringify(user),
    { headers: { "Content-Type": "application/json" }, tags: { name: "login" } }
  );

  const ok = check(res, {
    "login 200": (r) => r.status === 200,
    "login has token": (r) => !!r.json("token"),
  });

  if (!ok) {
    fail(`Authentication failed for ${user.username}: ${res.status}`);
  }

  return {
    "Content-Type": "application/json",
    Authorization: `Bearer ${res.json("token")}`,
  };
}

// ---------------------------------------------------------------------------
// Default scenario: mixed read/write
// ---------------------------------------------------------------------------
export function defaultScenario() {
  const BASE_URL = __ENV.BASE_URL || "http://localhost:3000";
  activeUsers.add(1);

  const headers = authenticate(BASE_URL);

  group("browse_catalog", () => {
    const page = randomIntBetween(1, 10);
    const res = http.get(
      `${BASE_URL}/api/products?page=${page}&limit=20`,
      { headers, tags: { name: "list_products" } }
    );
    httpErrors.add(res.status >= 400);

    const isCached = res.headers["X-Cache"] === "HIT";
    cacheHitRate.add(isCached);

    check(res, {
      "products 200": (r) => r.status === 200,
      "products has items": (r) => Array.isArray(r.json()) || typeof r.json() === "object",
    });
    sleep(randomIntBetween(1, 3));
  });

  group("view_product", () => {
    const productId = randomItem(productIds);
    const start = Date.now();
    const res = http.get(
      `${BASE_URL}/api/products/${productId}`,
      { headers, tags: { name: "get_product" } }
    );
    dbQueryLatency.add(Date.now() - start);
    httpErrors.add(res.status >= 500);

    check(res, {
      "product 200 or 404": (r) => r.status === 200 || r.status === 404,
    });
    sleep(randomIntBetween(1, 2));
  });

  group("create_and_delete_item", () => {
    const createRes = http.post(
      `${BASE_URL}/api/items`,
      JSON.stringify({
        name: `perf-item-${exec.vu.idInTest}-${exec.scenario.iterationInTest}`,
        value: randomIntBetween(1, 999),
        category: randomItem(["electronics", "books", "clothing"]),
      }),
      { headers, tags: { name: "create_item" } }
    );
    httpErrors.add(createRes.status >= 400);

    const created = check(createRes, {
      "create 201": (r) => r.status === 201,
      "create has id": (r) => !!r.json("id"),
    });

    if (created) {
      const itemId = createRes.json("id");
      sleep(0.5);

      const deleteRes = http.del(
        `${BASE_URL}/api/items/${itemId}`,
        null,
        { headers, tags: { name: "delete_item" } }
      );
      check(deleteRes, {
        "delete 204": (r) => r.status === 204 || r.status === 200,
      });
    }
  });

  activeUsers.add(-1);
  sleep(randomIntBetween(1, 3));
}

// ---------------------------------------------------------------------------
// Browse-only scenario
// ---------------------------------------------------------------------------
export function browseScenario() {
  const BASE_URL = __ENV.BASE_URL || "http://localhost:3000";
  const headers = { "Content-Type": "application/json" };

  const res = http.get(
    `${BASE_URL}/api/products?page=${randomIntBetween(1, 20)}`,
    { headers, tags: { name: "browse_products", scenario: "browse" } }
  );
  httpErrors.add(res.status >= 400);
  check(res, { "browse 200": (r) => r.status === 200 });
  sleep(randomIntBetween(1, 5));
}

// ---------------------------------------------------------------------------
// Checkout scenario
// ---------------------------------------------------------------------------
export function checkoutScenario() {
  const BASE_URL = __ENV.BASE_URL || "http://localhost:3000";
  const headers = authenticate(BASE_URL);

  // Add to cart
  const cartRes = http.post(
    `${BASE_URL}/api/cart/items`,
    JSON.stringify({ productId: randomItem(productIds), quantity: 1 }),
    { headers, tags: { name: "add_to_cart", scenario: "checkout" } }
  );

  if (cartRes.status !== 201) return;

  const cartId = cartRes.json("cartId");
  sleep(1);

  // Place order
  const orderRes = http.post(
    `${BASE_URL}/api/orders`,
    JSON.stringify({
      cartId,
      paymentMethod: "card",
      shippingAddress: { street: "123 Test St", city: "Testville", country: "US", zip: "12345" },
    }),
    { headers, tags: { name: "place_order", scenario: "checkout" } }
  );

  const ok = check(orderRes, {
    "order 201": (r) => r.status === 201,
  });

  if (ok) successfulOrders.add(1);
  httpErrors.add(orderRes.status >= 500);
  sleep(2);
}

// ---------------------------------------------------------------------------
// Admin scenario
// ---------------------------------------------------------------------------
export function adminScenario() {
  const BASE_URL = __ENV.BASE_URL || "http://localhost:3000";

  const loginRes = http.post(
    `${BASE_URL}/api/auth/login`,
    JSON.stringify({ username: "admin", password: "adminpassword" }),
    { tags: { name: "admin_login", scenario: "admin" } }
  );

  if (loginRes.status !== 200) return;

  const headers = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${loginRes.json("token")}`,
  };

  group("admin_operations", () => {
    http.get(`${BASE_URL}/api/admin/users`, { headers, tags: { name: "admin_users", scenario: "admin" } });
    sleep(1);
    http.get(`${BASE_URL}/api/admin/metrics`, { headers, tags: { name: "admin_metrics", scenario: "admin" } });
    sleep(1);
    http.post(
      `${BASE_URL}/api/admin/reports`,
      JSON.stringify({ type: "daily-sales" }),
      { headers, tags: { name: "admin_report", scenario: "admin" } }
    );
  });

  sleep(randomIntBetween(5, 10));
}

// ---------------------------------------------------------------------------
// Custom summary
// ---------------------------------------------------------------------------
export function handleSummary(data) {
  const metrics = data.metrics;

  const report = {
    timestamp: new Date().toISOString(),
    scenario: SCENARIO,
    duration_ms: data.state?.testRunDuration,
    thresholds_passed: Object.entries(data.metrics)
      .filter(([, m]) => m.thresholds)
      .every(([, m]) => Object.values(m.thresholds).every((t) => !t.ok === false)),
    requests: {
      total:   metrics.http_reqs?.values?.count,
      rps:     metrics.http_reqs?.values?.rate?.toFixed(2),
      failed:  metrics.http_req_failed?.values?.passes,
    },
    latency: {
      avg_ms: metrics.http_req_duration?.values?.avg?.toFixed(2),
      p50_ms: metrics.http_req_duration?.values?.["p(50)"]?.toFixed(2),
      p95_ms: metrics.http_req_duration?.values?.["p(95)"]?.toFixed(2),
      p99_ms: metrics.http_req_duration?.values?.["p(99)"]?.toFixed(2),
      max_ms: metrics.http_req_duration?.values?.max?.toFixed(2),
    },
    custom: {
      error_rate:        metrics.http_errors?.values?.rate?.toFixed(4),
      cache_hit_rate:    metrics.cache_hit_rate?.values?.rate?.toFixed(4),
      successful_orders: metrics.successful_orders?.values?.count,
      db_p95_ms:         metrics.db_query_latency?.values?.["p(95)"]?.toFixed(2),
    },
  };

  return {
    stdout: JSON.stringify(report, null, 2) + "\n",
    [`results/k6-advanced-${SCENARIO}-${Date.now()}.json`]: JSON.stringify(data, null, 2),
  };
}
