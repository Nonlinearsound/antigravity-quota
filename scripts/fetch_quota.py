#!/usr/bin/env python3
"""Collect Google AI / Antigravity plan quota, credits, and local usage as JSON.

Invokes the official Antigravity CLI (`agy`) in non-interactive JSON print mode
(`-p=/quota --output-format json` and `-p=/credits --output-format json`) with
`AGY_CLI_DISABLE_AUTO_UPDATE=true`, normalizes every quota group and window into
explicit `used` and `remaining` percentages that always sum to 100%, and merges
fast mtime-cached local token counts from Antigravity CLI transcripts.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

PLUGIN_ID = "nonlinearsound.omarchy-plugin-antigravity-quota"
PROBE_COOLDOWN_SEC = 15.0
CLI_TIMEOUT_SEC = 20.0
CREDITS_PORTAL_URL = "https://one.google.com/ai/credits"


def cache_dir() -> Path:
    base = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache"))
    target = base / "omarchy" / "antigravity-quota"
    target.mkdir(parents=True, exist_ok=True)
    return target


def agy_data_dir() -> Path:
    return Path.home() / ".gemini" / "antigravity-cli"


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".", suffix=".tmp")
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, separators=(",", ":"), sort_keys=True) + "\n")
        tmp.chmod(0o600)
        tmp.replace(path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


def read_json_file(path: Path) -> dict[str, Any] | None:
    try:
        if not path.is_file():
            return None
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def expand_user_path(raw: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(raw.strip())))


def resolve_agy_binary(explicit_path: str = "") -> tuple[str | None, str]:
    configured = explicit_path.strip() or os.environ.get("ANTIGRAVITY_CLI_PATH", "").strip()
    if configured:
        candidate = expand_user_path(configured)
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate), ""
        return (
            None,
            f"Configured Antigravity CLI path is not executable: {candidate}",
        )

    found = shutil.which("agy")
    if found:
        return found, ""

    candidates = [
        Path.home() / ".local" / "bin" / "agy",
        agy_data_dir() / "bin" / "agy",
        Path("/usr/local/bin/agy"),
        Path("/usr/bin/agy"),
    ]
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate), ""

    return (
        None,
        "Antigravity CLI (`agy`) was not found. Install `agy` or set `cliPath` in plugin settings.",
    )


def clamp_fraction(value: Any) -> float:
    try:
        num = float(value)
        if num != num:  # NaN
            return 0.0
        return max(0.0, min(1.0, num))
    except Exception:
        return 0.0


def split_used_and_remaining(remaining_fraction: Any) -> dict[str, Any]:
    """Compute exact complementary used/remaining fractions and percentages.

    Rounding to tenths of a percent from a single integer (`remaining_tenths`)
    guarantees `usedPct + remainingPct == 100.0` with no rounding drift.
    """
    rem_frac = clamp_fraction(remaining_fraction)
    used_frac = max(0.0, min(1.0, 1.0 - rem_frac))

    rem_tenths = max(0, min(1000, round(rem_frac * 1000)))
    used_tenths = 1000 - rem_tenths

    rem_pct = rem_tenths / 10.0
    used_pct = used_tenths / 10.0

    return {
        "remainingFraction": round(rem_frac, 6),
        "usedFraction": round(used_frac, 6),
        "remainingPct": rem_pct,
        "usedPct": used_pct,
        "remainingText": format_pct(rem_pct),
        "usedText": format_pct(used_pct),
    }


def format_pct(pct: float) -> str:
    tenths = round(pct * 10)
    if tenths % 10 == 0:
        return f"{tenths // 10}%"
    return f"{tenths / 10.0:.1f}%"


def normalize_reset_iso(raw: Any) -> str:
    if raw is None:
        return ""
    text = str(raw).strip()
    if not text:
        return ""
    try:
        parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    except Exception:
        return text


def window_badge(window: str, bucket_name: str = "") -> str:
    w = (window or "").strip().lower()
    name = (bucket_name or "").strip().lower()
    if w in ("5h", "5-hour", "five_hour") or "five hour" in name or "5-hour" in name or "5h" in name:
        return "5-Hour"
    if w in ("weekly", "7d", "7-day") or "week" in name:
        return "Weekly"
    if w in ("daily", "24h", "1d") or "daily" in name or "day" in name:
        return "Daily"
    if w in ("monthly", "30d") or "month" in name:
        return "Monthly"
    if w:
        return w.upper() if len(w) <= 3 else w.capitalize()
    return "Window"


def window_rank(window: str) -> int:
    badge = window_badge(window)
    if badge == "5-Hour":
        return 0
    if badge == "Daily":
        return 1
    if badge == "Weekly":
        return 2
    if badge == "Monthly":
        return 3
    return 4


def clean_bucket_title(name: str, group_name: str, badge: str) -> str:
    raw = (name or "").strip()
    if not raw:
        return f"{badge} Limit"
    cleaned = re.sub(r"\s+Remaining\s*$", "", raw, flags=re.IGNORECASE).strip()
    if group_name and cleaned.lower().startswith(group_name.lower()):
        trimmed = cleaned[len(group_name) :].strip(" -·:")
        if trimmed:
            cleaned = trimmed
    return cleaned or f"{badge} Limit"


def infer_plan_tier(groups: list[dict[str, Any]], raw_description: str = "") -> tuple[str, str]:
    blob_parts = [raw_description]
    for group in groups:
        blob_parts.append(str(group.get("name") or ""))
        blob_parts.append(str(group.get("description") or ""))
        for bucket in group.get("buckets") or []:
            blob_parts.append(str(bucket.get("id") or ""))
            blob_parts.append(str(bucket.get("name") or ""))
            blob_parts.append(str(bucket.get("description") or ""))
    blob = " ".join(blob_parts)
    lower = blob.lower()

    if "for paid pro plans" in lower:
        return "Google AI Pro", "PRO"
    if "ultra plan" in lower and "available on ultra plans" not in lower:
        return "Google AI Ultra", "ULTRA"
    if "starter quota" in lower or "free tier" in lower or "free individual" in lower:
        return "Google AI Free", "FREE"
    if groups:
        return "Google AI Plan", "ACTIVE"
    return "Google AI", ""


def parse_text_fallback(response_text: str) -> list[dict[str, Any]]:
    """Fallback parser if CLI ever omits command.data and returns TSV/table lines."""
    grouped: dict[str, list[dict[str, Any]]] = {}
    for line in (response_text or "").splitlines():
        stripped = line.strip()
        if not stripped or stripped.lower().startswith("quota:"):
            continue
        parts = [p.strip() for p in re.split(r"\t+|\s{2,}", stripped) if p.strip()]
        if len(parts) < 3:
            continue
        group_name, bucket_name, pct_raw = parts[0], parts[1], parts[2]
        reset_raw = parts[3] if len(parts) >= 4 else ""
        match = re.search(r"(\d+(?:\.\d+)?)\s*%", pct_raw)
        if not match:
            continue
        rem_fraction = clamp_fraction(float(match.group(1)) / 100.0)
        badge = window_badge("", bucket_name)
        grouped.setdefault(group_name, []).append(
            {
                "id": re.sub(r"[^a-z0-9]+", "-", f"{group_name}-{bucket_name}".lower()).strip("-"),
                "name": bucket_name,
                "window": "5h" if badge == "5-Hour" else badge.lower(),
                "remaining_fraction": rem_fraction,
                "reset_time": reset_raw,
            }
        )

    return [{"name": g_name, "description": "", "buckets": b_list} for g_name, b_list in grouped.items()]


def normalize_groups(quota_payload: dict[str, Any]) -> tuple[list[dict[str, Any]], str, str, str]:
    cmd = quota_payload.get("command") if isinstance(quota_payload.get("command"), dict) else {}
    data = cmd.get("data") if isinstance(cmd.get("data"), dict) else {}
    raw_description = str(data.get("description") or "").strip()
    raw_groups = data.get("groups") if isinstance(data.get("groups"), list) else []

    if not raw_groups and quota_payload.get("response"):
        raw_groups = parse_text_fallback(str(quota_payload.get("response") or ""))

    plan_name, plan_badge = infer_plan_tier(raw_groups, raw_description)

    groups_out: list[dict[str, Any]] = []
    for raw_group in raw_groups:
        if not isinstance(raw_group, dict):
            continue
        g_name = str(raw_group.get("name") or "Models").strip()
        g_desc = str(raw_group.get("description") or "").strip()
        raw_buckets = raw_group.get("buckets") if isinstance(raw_group.get("buckets"), list) else []

        buckets_out: list[dict[str, Any]] = []
        for idx, raw_bucket in enumerate(raw_buckets):
            if not isinstance(raw_bucket, dict):
                continue
            b_name = str(raw_bucket.get("name") or "").strip()
            b_window = str(raw_bucket.get("window") or "").strip()
            badge = window_badge(b_window, b_name)
            split = split_used_and_remaining(raw_bucket.get("remaining_fraction", 1.0))
            buckets_out.append(
                {
                    "id": str(raw_bucket.get("id") or f"{g_name}-{idx}"),
                    "name": b_name or f"{badge} Limit",
                    "title": clean_bucket_title(b_name, g_name, badge),
                    "groupName": g_name,
                    "window": b_window or badge.lower(),
                    "windowBadge": badge,
                    "description": str(raw_bucket.get("description") or "").strip(),
                    "resetTime": normalize_reset_iso(raw_bucket.get("reset_time")),
                    **split,
                }
            )

        buckets_out.sort(key=lambda b: (window_rank(b["window"]), b["title"]))
        if not buckets_out:
            continue

        tightest = max(
            buckets_out,
            key=lambda b: (b["usedFraction"], -window_rank(b["window"])),
        )
        groups_out.append(
            {
                "name": g_name,
                "description": g_desc,
                "usedFraction": tightest["usedFraction"],
                "remainingFraction": tightest["remainingFraction"],
                "usedPct": tightest["usedPct"],
                "remainingPct": tightest["remainingPct"],
                "usedText": tightest["usedText"],
                "remainingText": tightest["remainingText"],
                "buckets": buckets_out,
            }
        )

    # Keep Google / Gemini model groups first, ordered with active usage on top,
    # followed by third-party routed model groups (Claude / GPT).
    def group_sort_key(idx_and_group: tuple[int, dict[str, Any]]) -> tuple[int, float, int]:
        idx, grp = idx_and_group
        is_third_party = 0 if "gemini" in grp["name"].lower() or "google" in grp["name"].lower() else 1
        return (is_third_party, -float(grp["usedFraction"]), idx)

    groups_out = [grp for _, grp in sorted(enumerate(groups_out), key=group_sort_key)]
    return groups_out, plan_name, plan_badge, raw_description


def pick_headline_bucket(groups: list[dict[str, Any]]) -> dict[str, Any] | None:
    all_buckets: list[dict[str, Any]] = []
    for group in groups:
        for bucket in group.get("buckets") or []:
            all_buckets.append(bucket)
    if not all_buckets:
        return None

    # If any bucket has non-zero usage, highlight the most constrained one
    # (highest usedFraction; tie-break by shorter reset window, then Gemini first).
    def sort_key(bucket: dict[str, Any]) -> tuple[float, int, int]:
        is_gemini = 1 if "gemini" in str(bucket.get("groupName") or "").lower() else 0
        return (
            float(bucket.get("usedFraction") or 0.0),
            is_gemini,
            -window_rank(str(bucket.get("window") or "")),
        )

    return max(all_buckets, key=sort_key)


def expire_stale_buckets(groups: list[dict[str, Any]], now_utc: dt.datetime) -> list[dict[str, Any]]:
    refreshed_groups: list[dict[str, Any]] = []
    for group in groups:
        new_buckets: list[dict[str, Any]] = []
        for bucket in group.get("buckets") or []:
            entry = dict(bucket)
            reset_raw = str(entry.get("resetTime") or "")
            if reset_raw:
                try:
                    reset_dt = dt.datetime.fromisoformat(reset_raw.replace("Z", "+00:00"))
                    if reset_dt.tzinfo is None:
                        reset_dt = reset_dt.replace(tzinfo=dt.timezone.utc)
                    if reset_dt <= now_utc:
                        entry.update(split_used_and_remaining(1.0))
                        entry["resetTime"] = ""
                except Exception:
                    pass
            new_buckets.append(entry)

        if not new_buckets:
            continue
        tightest = max(
            new_buckets,
            key=lambda b: (b["usedFraction"], -window_rank(b["window"])),
        )
        new_group = dict(group)
        new_group["buckets"] = new_buckets
        new_group["usedFraction"] = tightest["usedFraction"]
        new_group["remainingFraction"] = tightest["remainingFraction"]
        new_group["usedPct"] = tightest["usedPct"]
        new_group["remainingPct"] = tightest["remainingPct"]
        new_group["usedText"] = tightest["usedText"]
        new_group["remainingText"] = tightest["remainingText"]
        refreshed_groups.append(new_group)
    return refreshed_groups


def read_use_g1_credits() -> bool:
    settings_path = agy_data_dir() / "settings.json"
    data = read_json_file(settings_path)
    if not data:
        return False
    return bool(data.get("useG1Credits") is True)


def probe_agy(agy_bin: str) -> dict[str, Any]:
    env = dict(os.environ)
    env["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
    env["NO_COLOR"] = "1"

    base_args = [agy_bin, "--output-format", "json", "--print-timeout", "15s"]
    run_cwd = tempfile.gettempdir()

    try:
        quota_proc = subprocess.Popen(
            [*base_args, "-p=/quota"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=run_cwd,
            env=env,
        )
        credits_proc = subprocess.Popen(
            [*base_args, "-p=/credits"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=run_cwd,
            env=env,
        )
        quota_out, quota_err = quota_proc.communicate(timeout=CLI_TIMEOUT_SEC)
        credits_out, credits_err = credits_proc.communicate(timeout=CLI_TIMEOUT_SEC)
    except subprocess.TimeoutExpired:
        for proc_Name in ("quota_proc", "credits_proc"):
            proc = locals().get(proc_Name)
            if proc is not None:
                try:
                    proc.kill()
                except Exception:
                    pass
        return {
            "ok": False,
            "transport": True,
            "statusText": "Quota check timed out",
            "helpText": "Antigravity CLI timed out while contacting Google AI. Will retry automatically.",
        }
    except Exception as exc:
        return {
            "ok": False,
            "transport": True,
            "statusText": "Failed to run Antigravity CLI",
            "helpText": str(exc),
        }

    quota_json: dict[str, Any] | None = None
    for line in reversed((quota_out or "").splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                quota_json = json.loads(line)
                break
            except Exception:
                continue

    if not quota_json or quota_json.get("status") != "SUCCESS":
        err_detail = ""
        if quota_json and quota_json.get("error"):
            err_detail = str(quota_json.get("error"))
        elif quota_err:
            err_detail = quota_err.strip().splitlines()[-1]
        elif quota_out:
            err_detail = quota_out.strip().splitlines()[-1]

        lower_err = err_detail.lower()
        is_auth = any(tok in lower_err for tok in ("login", "auth", "unauthenticated", "sign in", "credential"))
        is_transport = any(
            tok in lower_err
            for tok in ("network", "timeout", "timed out", "connection", "dns", " dial ", "unreachable")
        )
        return {
            "ok": False,
            "transport": is_transport and not is_auth,
            "statusText": "Sign-in required" if is_auth else "Quota unavailable",
            "helpText": (
                "Run `agy` in a terminal to sign in to your Google AI account."
                if is_auth
                else (err_detail or "Could not query quota from `agy`.")
            ),
        }

    groups, plan_name, plan_badge, description = normalize_groups(quota_json)
    if not groups:
        return {
            "ok": False,
            "transport": False,
            "statusText": "No quota buckets returned",
            "helpText": "Google AI returned an empty quota response. Run `agy` and try `/quota`.",
        }

    credits_info = {
        "available": False,
        "remainingCredits": 0,
        "useG1Credits": read_use_g1_credits(),
        "upgradeUri": CREDITS_PORTAL_URL,
    }
    for line in reversed((credits_out or "").splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                c_json = json.loads(line)
                c_cmd = c_json.get("command") if isinstance(c_json.get("command"), dict) else {}
                c_data = c_cmd.get("data") if isinstance(c_cmd.get("data"), dict) else {}
                if c_json.get("status") == "SUCCESS" and c_data:
                    credits_info["available"] = True
                    credits_info["remainingCredits"] = max(0, int(round(float(c_data.get("remaining_credits") or 0))))
                    if c_data.get("upgrade_uri"):
                        credits_info["upgradeUri"] = str(c_data.get("upgrade_uri"))
                break
            except Exception:
                continue

    return {
        "ok": True,
        "planName": plan_name,
        "planBadge": plan_badge,
        "planDescription": description,
        "groups": groups,
        "credits": credits_info,
        "fetchedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "fetchedAtMs": int(time.time() * 1000),
    }


def local_date_str(value: Any, fallback: str) -> str:
    if not value:
        return fallback
    try:
        parsed = dt.datetime.fromisoformat(str(value).strip().replace("Z", "+00:00"))
        if parsed.tzinfo is not None:
            parsed = parsed.astimezone()
        return parsed.date().strftime("%Y-%m-%d")
    except Exception:
        return fallback


def scan_local_transcripts() -> dict[str, Any]:
    """Incrementally scan local Antigravity transcripts for token/session counts."""
    brain_dir = agy_data_dir() / "brain"
    today_date = dt.datetime.now().date()
    today_str = today_date.strftime("%Y-%m-%d")
    recent_dates = [(today_date - dt.timedelta(days=offset)).strftime("%Y-%m-%d") for offset in range(6, -1, -1)]

    index_path = cache_dir() / "transcript-index.json"
    cached_index = read_json_file(index_path) or {}
    cached_files = cached_index.get("files") if isinstance(cached_index.get("files"), dict) else {}

    next_files: dict[str, Any] = {}
    dirty = False

    if brain_dir.is_dir():
        for conv_dir in brain_dir.iterdir():
            if not conv_dir.is_dir():
                continue
            transcript = conv_dir / ".system_generated" / "logs" / "transcript.jsonl"
            try:
                st = transcript.stat()
            except OSError:
                continue

            key = conv_dir.name
            prev = cached_files.get(key)
            if (
                isinstance(prev, dict)
                and prev.get("mtimeNs") == st.st_mtime_ns
                and prev.get("size") == st.st_size
            ):
                next_files[key] = prev
                continue

            dirty = True
            by_day_tokens: dict[str, int] = {}
            by_day_prompts: dict[str, int] = {}
            input_total = 0
            output_total = 0
            cache_total = 0
            prompt_total = 0

            try:
                with transcript.open("r", encoding="utf-8", errors="replace") as handle:
                    for raw_line in handle:
                        if '"USER_INPUT"' not in raw_line and '"PLANNER_RESPONSE"' not in raw_line:
                            continue
                        try:
                            step = json.loads(raw_line)
                        except Exception:
                            continue
                        step_type = step.get("type")
                        day = local_date_str(step.get("created_at"), today_str)
                        if step_type == "USER_INPUT":
                            prompt_total += 1
                            by_day_prompts[day] = by_day_prompts.get(day, 0) + 1
                        elif step_type == "PLANNER_RESPONSE":
                            in_tok = max(0, int(step.get("input_tokens") or 0))
                            out_tok = max(0, int(step.get("output_tokens") or 0)) + max(
                                0, int(step.get("thinking_tokens") or 0)
                            )
                            cache_tok = max(0, int(step.get("cache_read_tokens") or 0))
                            step_total = in_tok + out_tok + cache_tok
                            if step_total > 0:
                                input_total += in_tok
                                output_total += out_tok
                                cache_total += cache_tok
                                by_day_tokens[day] = by_day_tokens.get(day, 0) + step_total
            except OSError:
                continue

            next_files[key] = {
                "mtimeNs": st.st_mtime_ns,
                "size": st.st_size,
                "prompts": prompt_total,
                "inputTokens": input_total,
                "outputTokens": output_total,
                "cacheTokens": cache_total,
                "byDayTokens": by_day_tokens,
                "byDayPrompts": by_day_prompts,
            }

    if dirty or len(next_files) != len(cached_files):
        try:
            atomic_write_json(index_path, {"schemaVersion": 1, "files": next_files})
        except Exception:
            pass

    recent_tokens = {d: 0 for d in recent_dates}
    recent_prompts = {d: 0 for d in recent_dates}
    today_sessions = 0
    total_sessions = 0
    total_prompts = 0
    total_input = 0
    total_output = 0
    total_cache = 0

    for entry in next_files.values():
        e_tokens = entry.get("byDayTokens") or {}
        e_prompts = entry.get("byDayPrompts") or {}
        conv_tot = int(entry.get("inputTokens") or 0) + int(entry.get("outputTokens") or 0) + int(
            entry.get("cacheTokens") or 0
        )
        if conv_tot > 0 or int(entry.get("prompts") or 0) > 0:
            total_sessions += 1
        if int(e_tokens.get(today_str) or 0) > 0 or int(e_prompts.get(today_str) or 0) > 0:
            today_sessions += 1

        total_prompts += int(entry.get("prompts") or 0)
        total_input += int(entry.get("inputTokens") or 0)
        total_output += int(entry.get("outputTokens") or 0)
        total_cache += int(entry.get("cacheTokens") or 0)

        for d in recent_dates:
            recent_tokens[d] += int(e_tokens.get(d) or 0)
            recent_prompts[d] += int(e_prompts.get(d) or 0)

    week_tokens = sum(recent_tokens.values())
    total_tokens = total_input + total_output + total_cache

    return {
        "hasActivity": total_sessions > 0 or total_tokens > 0,
        "todayPrompts": recent_prompts[today_str],
        "todaySessions": today_sessions,
        "todayTokens": recent_tokens[today_str],
        "weekTokens": week_tokens,
        "totalPrompts": total_prompts,
        "totalSessions": total_sessions,
        "totalTokens": total_tokens,
        "inputTokens": total_input,
        "outputTokens": total_output,
        "cacheTokens": total_cache,
        "recentDays": [
            {"date": d, "tokens": recent_tokens[d], "prompts": recent_prompts[d]}
            for d in recent_dates
        ],
    }


def collect(cli_path: str = "", force: bool = False) -> dict[str, Any]:
    cdir = cache_dir()
    probe_cache_path = cdir / "quota-probe.json"
    lock_path = cdir / "quota-probe.lock"

    local_activity = scan_local_transcripts()
    agy_bin, bin_err = resolve_agy_binary(cli_path)

    if not agy_bin:
        return {
            "schemaVersion": 1,
            "ready": False,
            "stale": False,
            "retryAdvised": False,
            "statusText": "Antigravity CLI not found",
            "helpText": bin_err,
            "planName": "Google AI",
            "planBadge": "",
            "planDescription": "",
            "headline": None,
            "groups": [],
            "credits": {
                "available": False,
                "remainingCredits": 0,
                "useG1Credits": read_use_g1_credits(),
                "upgradeUri": CREDITS_PORTAL_URL,
            },
            "localActivity": local_activity,
            "fetchedAt": "",
            "fetchedAtMs": 0,
        }

    with lock_path.open("w", encoding="utf-8") as lock_handle:
        fcntl.flock(lock_handle, fcntl.LOCK_EX)
        cached = read_json_file(probe_cache_path)
        now_ms = int(time.time() * 1000)

        use_cached_directly = (
            not force
            and cached is not None
            and cached.get("ok") is True
            and (now_ms - int(cached.get("fetchedAtMs") or 0)) < int(PROBE_COOLDOWN_SEC * 1000)
        )

        if use_cached_directly:
            probe = dict(cached)
            stale = False
            status_text = ""
            help_text = ""
            retry_advised = False
        else:
            live = probe_agy(agy_bin)
            if live.get("ok") is True:
                atomic_write_json(probe_cache_path, live)
                probe = live
                stale = False
                status_text = ""
                help_text = ""
                retry_advised = False
            elif cached is not None and cached.get("ok") is True:
                probe = dict(cached)
                stale = True
                status_text = str(live.get("statusText") or "Showing cached quota")
                help_text = str(live.get("helpText") or "")
                retry_advised = bool(live.get("transport") is True)
            else:
                return {
                    "schemaVersion": 1,
                    "ready": False,
                    "stale": False,
                    "retryAdvised": bool(live.get("transport") is True),
                    "statusText": str(live.get("statusText") or "Quota unavailable"),
                    "helpText": str(live.get("helpText") or ""),
                    "planName": "Google AI",
                    "planBadge": "",
                    "planDescription": "",
                    "headline": None,
                    "groups": [],
                    "credits": {
                        "available": False,
                        "remainingCredits": 0,
                        "useG1Credits": read_use_g1_credits(),
                        "upgradeUri": CREDITS_PORTAL_URL,
                    },
                    "localActivity": local_activity,
                    "fetchedAt": "",
                    "fetchedAtMs": 0,
                }

    now_utc = dt.datetime.now(dt.timezone.utc)
    groups = expire_stale_buckets(probe.get("groups") or [], now_utc)
    headline = pick_headline_bucket(groups)

    credits = dict(probe.get("credits") or {})
    credits["useG1Credits"] = read_use_g1_credits()
    credits.setdefault("upgradeUri", CREDITS_PORTAL_URL)
    credits.setdefault("remainingCredits", 0)
    credits.setdefault("available", False)

    return {
        "schemaVersion": 1,
        "ready": len(groups) > 0,
        "stale": stale,
        "retryAdvised": retry_advised,
        "statusText": status_text,
        "helpText": help_text,
        "planName": str(probe.get("planName") or "Google AI Plan"),
        "planBadge": str(probe.get("planBadge") or ""),
        "planDescription": str(probe.get("planDescription") or ""),
        "headline": headline,
        "groups": groups,
        "credits": credits,
        "localActivity": local_activity,
        "fetchedAt": str(probe.get("fetchedAt") or ""),
        "fetchedAtMs": int(probe.get("fetchedAtMs") or 0),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Fetch Google AI plan quota as JSON.")
    parser.add_argument("--cli-path", default="", help="Optional path to the `agy` executable.")
    parser.add_argument("--force", action="store_true", help="Bypass probe cooldown cache.")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON output.")
    args = parser.parse_args(argv)

    payload = collect(cli_path=args.cli_path, force=args.force)
    if args.pretty:
        sys.stdout.write(json.dumps(payload, indent=2) + "\n")
    else:
        sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
