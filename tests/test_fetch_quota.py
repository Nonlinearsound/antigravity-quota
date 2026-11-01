#!/usr/bin/env python3
"""Unit tests for scripts/fetch_quota.py."""

from __future__ import annotations

import datetime as dt
import importlib.util
import sys
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parent.parent / "scripts" / "fetch_quota.py"
SPEC = importlib.util.spec_from_file_location("fetch_quota", SCRIPT_PATH)
assert SPEC and SPEC.loader
fq = importlib.util.module_from_spec(SPEC)
sys.modules["fetch_quota"] = fq
SPEC.loader.exec_module(fq)


SAMPLE_QUOTA_PAYLOAD = {
    "status": "SUCCESS",
    "command": {
        "name": "usage",
        "data": {
            "description": "Within each group, models share a weekly limit and a 5-hour limit.",
            "groups": [
                {
                    "name": "Claude and GPT models",
                    "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
                    "buckets": [
                        {
                            "id": "3p-weekly",
                            "name": "Weekly Limit Remaining",
                            "window": "weekly",
                            "remaining_fraction": 1.0,
                            "reset_time": "2026-11-08T18:20:49Z",
                        },
                        {
                            "id": "3p-5h",
                            "name": "Five Hour Limit Remaining",
                            "window": "5h",
                            "remaining_fraction": 1.0,
                            "reset_time": "2026-11-01T23:20:49Z",
                        },
                    ],
                },
                {
                    "name": "Gemini Models",
                    "description": "Models within this group: Gemini Flash, Gemini Pro",
                    "buckets": [
                        {
                            "id": "gemini-weekly",
                            "name": "Weekly Limit Remaining",
                            "window": "weekly",
                            "remaining_fraction": 0.85,
                            "reset_time": "2026-11-08T18:20:49Z",
                        },
                        {
                            "id": "gemini-5h",
                            "name": "Five Hour Limit Remaining",
                            "window": "5h",
                            "remaining_fraction": 0.625,
                            "reset_time": "2026-11-01T23:20:49Z",
                        },
                    ],
                },
                {
                    "name": "Gemini 4 Argon",
                    "description": "For paid Pro plans, Argon quota is separate. Higher Argon quota (included as part of the larger Gemini quota bucket) is available on Ultra plans.",
                    "buckets": [
                        {
                            "id": "gemini-argon-wtu-weekly",
                            "name": "Gemini 4 Argon Weekly Limit",
                            "window": "weekly",
                            "remaining_fraction": 0.919867,
                            "reset_time": "2026-11-08T18:09:57Z",
                        }
                    ],
                },
            ],
        },
    },
}


class FetchQuotaTests(unittest.TestCase):
    def test_split_used_and_remaining_sums_to_100(self) -> None:
        for raw in (0.0, 1.0, 0.5, 0.9787293, 0.919867, 0.333333, -0.5, 1.5, float("nan")):
            res = fq.split_used_and_remaining(raw)
            self.assertAlmostEqual(res["usedPct"] + res["remainingPct"], 100.0, places=5)
            self.assertGreaterEqual(res["usedPct"], 0.0)
            self.assertLessEqual(res["remainingPct"], 100.0)

        exact = fq.split_used_and_remaining(0.9787)
        self.assertEqual(exact["remainingText"], "97.9%")
        self.assertEqual(exact["usedText"], "2.1%")

    def test_normalize_groups_orders_gemini_first_and_detects_pro(self) -> None:
        groups, plan_name, plan_badge, _ = fq.normalize_groups(SAMPLE_QUOTA_PAYLOAD)
        self.assertEqual(plan_name, "Google AI Pro")
        self.assertEqual(plan_badge, "PRO")
        self.assertEqual(len(groups), 3)
        # Gemini Models has 37.5% used > Gemini 4 Argon 8% used > 3P models last
        self.assertEqual(groups[0]["name"], "Gemini Models")
        self.assertEqual(groups[1]["name"], "Gemini 4 Argon")
        self.assertEqual(groups[2]["name"], "Claude and GPT models")

        # 5-Hour bucket sorted before Weekly inside Gemini Models
        self.assertEqual(groups[0]["buckets"][0]["windowBadge"], "5-Hour")
        self.assertEqual(groups[0]["buckets"][0]["usedText"], "37.5%")
        self.assertEqual(groups[0]["buckets"][0]["remainingText"], "62.5%")

    def test_pick_headline_bucket_selects_most_constrained(self) -> None:
        groups, _, _, _ = fq.normalize_groups(SAMPLE_QUOTA_PAYLOAD)
        headline = fq.pick_headline_bucket(groups)
        assert headline is not None
        self.assertEqual(headline["id"], "gemini-5h")
        self.assertEqual(headline["usedText"], "37.5%")
        self.assertEqual(headline["remainingText"], "62.5%")

    def test_expire_stale_buckets_resets_elapsed_windows(self) -> None:
        groups, _, _, _ = fq.normalize_groups(SAMPLE_QUOTA_PAYLOAD)
        future_now = dt.datetime(2026, 11, 2, 12, 0, 0, tzinfo=dt.timezone.utc)
        refreshed = fq.expire_stale_buckets(groups, future_now)
        gemini_5h = refreshed[0]["buckets"][0]
        self.assertEqual(gemini_5h["usedPct"], 0.0)
        self.assertEqual(gemini_5h["remainingPct"], 100.0)
        self.assertEqual(gemini_5h["resetTime"], "")

    def test_text_fallback_parser(self) -> None:
        raw = (
            "Quota:\n"
            "Gemini Models\tWeekly Limit Remaining\t88%\t2026-11-08T18:20:49Z\n"
            "Gemini Models\tFive Hour Limit Remaining\t75%\t2026-11-01T23:20:49Z\n"
        )
        groups, _, _, _ = fq.normalize_groups({"status": "SUCCESS", "response": raw})
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]["buckets"][0]["usedText"], "25%")
        self.assertEqual(groups[0]["buckets"][0]["remainingText"], "75%")


if __name__ == "__main__":
    unittest.main()
