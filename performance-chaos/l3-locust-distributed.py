"""
Locust distributed load test
Covers: HTTP tasks, weighted user classes, custom shapes, events, CSV reporting

Run (standalone):
    locust -f l3-locust-distributed.py --host http://localhost:3000

Run (distributed master):
    locust -f l3-locust-distributed.py --master --host http://localhost:3000 \
           --users 500 --spawn-rate 10 --run-time 10m --headless

Run (distributed worker — run on each worker node):
    locust -f l3-locust-distributed.py --worker --master-host <master-ip>

Run (headless CI mode):
    locust -f l3-locust-distributed.py --host http://localhost:3000 \
           --users 100 --spawn-rate 5 --run-time 5m --headless \
           --csv=results/locust-report --html=results/locust-report.html
"""

import json
import random
import time
import csv
import os
from datetime import datetime

from locust import (
    HttpUser,
    TaskSet,
    between,
    constant_pacing,
    events,
    run_single_user,
    task,
)
from locust.env import Environment
from locust.exception import StopUser
from locust.runners import MasterRunner, WorkerRunner


# ---------------------------------------------------------------------------
# Shared test data
# ---------------------------------------------------------------------------
PRODUCT_IDS = list(range(1, 101))
USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
]


# ---------------------------------------------------------------------------
# Task sets (logical groupings of user actions)
# ---------------------------------------------------------------------------
class BrowseCatalogTasks(TaskSet):
    """Read-heavy tasks: browsing product catalog and search."""

    @task(5)
    def list_products(self):
        page = random.randint(1, 10)
        with self.client.get(
            f"/api/products?page={page}&limit=20",
            name="/api/products",
            catch_response=True,
        ) as res:
            if res.status_code == 200:
                data = res.json()
                if not isinstance(data, (list, dict)):
                    res.failure("Response is not JSON list/dict")
            else:
                res.failure(f"Unexpected status {res.status_code}")

    @task(3)
    def get_product_detail(self):
        product_id = random.choice(PRODUCT_IDS)
        with self.client.get(
            f"/api/products/{product_id}",
            name="/api/products/:id",
            catch_response=True,
        ) as res:
            if res.status_code == 200:
                body = res.json()
                if "id" not in body:
                    res.failure("Missing 'id' in product response")
            elif res.status_code == 404:
                res.success()  # expected for some IDs
            else:
                res.failure(f"Unexpected status {res.status_code}")

    @task(2)
    def search_products(self):
        query = random.choice(["laptop", "phone", "tablet", "watch", "headset"])
        with self.client.get(
            f"/api/products/search?q={query}",
            name="/api/products/search",
            catch_response=True,
        ) as res:
            if res.status_code not in (200, 404):
                res.failure(f"Search failed: {res.status_code}")

    @task(1)
    def stop_browsing(self):
        self.interrupt()


class CheckoutTasks(TaskSet):
    """Write-heavy tasks: cart management and order creation."""

    def on_start(self):
        self.cart_id = None

    @task(3)
    def add_to_cart(self):
        payload = {
            "productId": random.choice(PRODUCT_IDS),
            "quantity": random.randint(1, 3),
        }
        with self.client.post(
            "/api/cart/items",
            json=payload,
            name="/api/cart/items POST",
            catch_response=True,
        ) as res:
            if res.status_code == 201:
                body = res.json()
                self.cart_id = body.get("cartId")
            else:
                res.failure(f"Add to cart failed: {res.status_code}")

    @task(2)
    def view_cart(self):
        if not self.cart_id:
            return
        with self.client.get(
            f"/api/cart/{self.cart_id}",
            name="/api/cart/:id",
            catch_response=True,
        ) as res:
            if res.status_code not in (200, 404):
                res.failure(f"View cart failed: {res.status_code}")

    @task(1)
    def place_order(self):
        if not self.cart_id:
            return
        payload = {
            "cartId": self.cart_id,
            "paymentMethod": "card",
            "shippingAddress": {
                "street": "123 Test St",
                "city": "Testville",
                "country": "US",
                "zip": "12345",
            },
        }
        with self.client.post(
            "/api/orders",
            json=payload,
            name="/api/orders POST",
            catch_response=True,
        ) as res:
            if res.status_code == 201:
                self.cart_id = None  # reset cart after order
            elif res.status_code == 422:
                res.success()  # validation errors are expected
            else:
                res.failure(f"Place order failed: {res.status_code}")
        self.interrupt()

    @task(1)
    def stop_checkout(self):
        self.interrupt()


# ---------------------------------------------------------------------------
# User classes
# ---------------------------------------------------------------------------
class BrowserUser(HttpUser):
    """Simulates read-heavy browser users (70% of traffic)."""

    weight = 70
    wait_time = between(1, 5)
    tasks = {BrowseCatalogTasks: 8, CheckoutTasks: 2}

    def on_start(self):
        """Login before starting tasks."""
        self.client.headers.update(
            {"User-Agent": random.choice(USER_AGENTS)}
        )
        self._login()

    def _login(self):
        user_num = random.randint(1, 1000)
        res = self.client.post(
            "/api/auth/login",
            json={"username": f"user{user_num}", "password": "password"},
            name="/api/auth/login",
        )
        if res.status_code == 200:
            token = res.json().get("token", "")
            self.client.headers.update({"Authorization": f"Bearer {token}"})
        else:
            raise StopUser()


class APIUser(HttpUser):
    """Simulates programmatic API clients (20% of traffic)."""

    weight = 20
    wait_time = constant_pacing(0.5)  # 2 req/s per user

    def on_start(self):
        self._authenticate()

    def _authenticate(self):
        res = self.client.post(
            "/api/auth/token",
            json={"client_id": "api-client", "client_secret": "secret"},
            name="/api/auth/token",
        )
        if res.status_code == 200:
            self.client.headers.update(
                {"Authorization": f"Bearer {res.json().get('access_token', '')}"}
            )

    @task(4)
    def api_list_orders(self):
        self.client.get("/api/orders?limit=50", name="/api/orders")

    @task(3)
    def api_get_inventory(self):
        self.client.get("/api/inventory/summary", name="/api/inventory/summary")

    @task(2)
    def api_create_item(self):
        self.client.post(
            "/api/items",
            json={"name": f"item-{time.time()}", "sku": f"SKU-{random.randint(1000,9999)}"},
            name="/api/items POST",
        )

    @task(1)
    def api_health_check(self):
        self.client.get("/healthz", name="/healthz")


class AdminUser(HttpUser):
    """Simulates admin operations (10% of traffic)."""

    weight = 10
    wait_time = between(5, 15)

    def on_start(self):
        res = self.client.post(
            "/api/auth/login",
            json={"username": "admin", "password": "adminpassword"},
            name="/api/auth/login [admin]",
        )
        if res.status_code == 200:
            self.client.headers.update(
                {"Authorization": f"Bearer {res.json().get('token', '')}"}
            )

    @task(3)
    def admin_list_users(self):
        self.client.get("/api/admin/users", name="/api/admin/users")

    @task(2)
    def admin_generate_report(self):
        self.client.post(
            "/api/admin/reports",
            json={"type": "sales", "period": "daily"},
            name="/api/admin/reports POST",
        )

    @task(1)
    def admin_system_metrics(self):
        self.client.get("/api/admin/metrics", name="/api/admin/metrics")


# ---------------------------------------------------------------------------
# Custom load shape (alternative to --users/--spawn-rate)
# Uncomment and subclass LoadTestShape to use instead of scenario flags
# ---------------------------------------------------------------------------
# from locust import LoadTestShape
#
# class StairStepShape(LoadTestShape):
#     """Stair-step load: increase users every 2 minutes."""
#     stages = [
#         {"duration": 120, "users": 10,  "spawn_rate": 5},
#         {"duration": 240, "users": 50,  "spawn_rate": 10},
#         {"duration": 360, "users": 100, "spawn_rate": 20},
#         {"duration": 480, "users": 200, "spawn_rate": 20},
#         {"duration": 600, "users": 200, "spawn_rate": 20},
#         {"duration": 720, "users": 0,   "spawn_rate": 50},
#     ]
#     def tick(self):
#         run_time = self.get_run_time()
#         for stage in self.stages:
#             if run_time < stage["duration"]:
#                 return stage["users"], stage["spawn_rate"]
#         return None


# ---------------------------------------------------------------------------
# Event hooks
# ---------------------------------------------------------------------------
@events.init.add_listener
def on_locust_init(environment: Environment, **kwargs):
    if isinstance(environment.runner, MasterRunner):
        print("Locust master initialized — waiting for workers")
    elif isinstance(environment.runner, WorkerRunner):
        print(f"Locust worker initialized — master: {environment.runner.master_host}")
    else:
        print("Locust running in standalone mode")

    # Ensure results directory exists
    os.makedirs("results", exist_ok=True)


@events.request.add_listener
def on_request(
    request_type, name, response_time, response_length,
    response, context, exception, **kwargs
):
    """Log slow requests (>1s) to a CSV file."""
    if response_time > 1000:
        log_path = "results/slow-requests.csv"
        file_exists = os.path.exists(log_path)
        with open(log_path, "a", newline="") as f:
            writer = csv.writer(f)
            if not file_exists:
                writer.writerow(["timestamp", "method", "name", "response_time_ms",
                                  "status_code", "error"])
            writer.writerow([
                datetime.utcnow().isoformat(),
                request_type,
                name,
                round(response_time, 2),
                getattr(response, "status_code", "N/A"),
                str(exception) if exception else "",
            ])


@events.test_stop.add_listener
def on_test_stop(environment: Environment, **kwargs):
    stats = environment.runner.stats
    total = stats.total
    print(f"\n--- Test Complete ---")
    print(f"Total requests:   {total.num_requests}")
    print(f"Failed requests:  {total.num_failures}")
    print(f"Avg response:     {total.avg_response_time:.2f}ms")
    print(f"p95 response:     {total.get_response_time_percentile(0.95):.2f}ms")
    print(f"p99 response:     {total.get_response_time_percentile(0.99):.2f}ms")
    print(f"Requests/sec:     {total.current_rps:.2f}")
    print(f"Failure rate:     {(total.num_failures / max(total.num_requests, 1) * 100):.3f}%")


# ---------------------------------------------------------------------------
# Direct execution for single-user debugging
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    run_single_user(BrowserUser)
