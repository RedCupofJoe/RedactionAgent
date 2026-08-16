"""Locust load test for redaction + discovery APIs (run from laptop)."""

from __future__ import annotations

import os
import random

from locust import HttpUser, between, task


DISCOVERY_HOST = os.getenv("DISCOVERY_API_URL", "").rstrip("/")


class LabUser(HttpUser):
    wait_time = between(1, 3)

    def on_start(self):
        self.doc_keys = []
        try:
            with self.client.get("/documents", name="/documents", verify=False, catch_response=True) as resp:
                if resp.status_code == 200:
                    docs = resp.json()
                    self.doc_keys = [
                        d["key"] for d in docs if str(d.get("key", "")).lower().endswith(".pdf")
                    ]
                    resp.success()
                else:
                    resp.failure(f"status {resp.status_code}")
        except Exception as exc:  # noqa: BLE001
            print("on_start list failed:", exc)

    @task(3)
    def list_documents(self):
        self.client.get("/documents", name="/documents", verify=False)

    @task(2)
    def redact_one(self):
        if not self.doc_keys:
            return
        key = random.choice(self.doc_keys)
        payload = {
            "documents": [key],
            "person": "Jordan Hale",
            "place": "Plant B",
            "time": "2021",
            "events": "",
            "custom": "",
        }
        self.client.post("/redact", json=payload, name="/redact", verify=False, timeout=300)

    @task(2)
    def discovery_search(self):
        if not DISCOVERY_HOST:
            return
        # Locust HttpUser is bound to --host (redaction). Use absolute URL for discovery.
        self.client.post(
            f"{DISCOVERY_HOST}/search",
            json={"query": "Plant B spill", "top_k": 3, "summarize": False},
            name="discovery:/search",
            verify=False,
            timeout=300,
        )
