# Antigravity Quota

**Your Google AI plan, in your Omarchy bar.** A sparkle that tells you at a glance how your quota is holding up, and a keyboard-first panel with every model group and rolling window **used vs. left**, live reset timers, your plan and AI credits, and your local CLI token activity, in your theme's colors.

## What it does

- **A bar icon that knows.** The Google AI sparkle stays calm while quota is plentiful, takes on the accent color past your warning threshold, and glows urgent at 90% used. Its tooltip sums up the tightest window.

- **Used and left, side by side.** Every number appears twice, from both ends: the tightest window leads the panel as a big USED / LEFT pair, and each group and window below echoes it in `10.8% used · 89.2% left`. The two halves always sum to 100%, with no rounding drift.

- **Every window, counted down.** The 5-hour and weekly limits of `Gemini Models`, `Gemini 4 Argon`, and `Claude and GPT models` each get their own meter, badge and reset count (`Resets in 5d 23h · Sun Nov 8, 18:09`), refreshed with live countdown while the panel is open.

- **In your theme's colors.** Meters, percentages and the icon all draw from the shell's own theme palette, switch live with a theme change, and work on horizontal and vertical bars alike.

- **Your plan and your credits.** The panel header names your tier (Pro, Ultra, Free, detected from the quota itself), and a credits card shows your remaining G1 AI credits, whether overage fallback (`useG1Credits`) is on, and a one-click link to the credits portal.

- **Your local token activity.** Today versus the last seven days: total tokens, prompts and a small daily bar chart, read incrementally from your own Antigravity CLI transcripts, so it never costs a quota request.

- **Bar text when you want it.** The icon can stay alone, or carry `% left`, `% used`, or `used · left` inline on the bar, set from the widget's own settings view.

- **Fresh on demand.** Background refresh every 5 minutes, a refresh button and `r` in the panel, a middle-click on the icon, and an IPC `refresh` — all going through a file-locked cooldown so parallel calls never hammer the backend in a burst.

## Install

Antigravity Quota needs the [Antigravity CLI](https://antigravity.google) (`agy`), signed in to your Google AI account. It finds `agy` on `PATH`, in `~/.local/bin`, `~/.gemini/antigravity-cli/bin`, `/usr/local/bin` or `/usr/bin`; set **Antigravity CLI path** in the widget's settings if yours is elsewhere. Python needs no extra package — it ships with every Omarchy install.

```
omarchy plugin add https://github.com/Nonlinearsound/antigravity-quota.git
```

The sparkle lands in the bar's right section; drag it anywhere on the bar.

### Uninstall

```
omarchy plugin remove nonlinearsound.omarchy-plugin-antigravity-quota
rm -rf ~/.cache/omarchy/antigravity-quota
```

Antigravity Quota changes nothing in Antigravity's own settings, and nothing else to clean up.

### Keys

| Key | Does |
| --- | --- |
| `j` `k` / arrows | Scroll the panel |
| `r` / `Enter` | Refresh the quota |
| `s` | Open settings (save again with `s`) |
| `c` | Open the Google AI credits portal |
| `Tab` | Next bar panel |
| `Esc` | Back out of settings, then close |

On the bar icon: left-click toggles the panel, middle-click forces a refresh, right-click opens the settings view.

Antigravity Quota answers over IPC, so you can bind it in `~/.config/hypr/bindings.lua`:

```
omarchy-shell nonlinearsound.omarchy-plugin-antigravity-quota toggle
omarchy-shell nonlinearsound.omarchy-plugin-antigravity-quota refresh
omarchy-shell nonlinearsound.omarchy-plugin-antigravity-quota settings
```

## Settings

| Setting | Default |
| --- | --- |
| Bar display | Icon only (or `% left`, `% used`, `used · left`) |
| Meter style | Fill upward with `% used` (or drain downward with `% left`) |
| Warning threshold | 80% used (accent color; urgent at 90%) |
| Refresh interval | 300 s (30–3600) |
| Antigravity CLI path | found automatically |

## How it works, and what it touches

All data comes from the CLI you already trust: one helper script (`scripts/fetch_quota.py`, stdlib-only Python) asks `agy` in its non-interactive JSON print mode (`-p=/quota --output-format json`, `-p=/credits ...`), normalizes the answer, derives every `used`/`left` pair from a single source fraction, and hands the panel one JSON document. Nothing is scraped, and no third-party proxy is involved — it is the same quota the CLI itself shows.

- **Files:** the helper keeps a 15-second probe cache, its lock and a transcript index under `~/.cache/omarchy/antigravity-quota/` (0600, atomic writes); the panel hydrates its last known state from that cache for an instant paint on shell startup. Transcript stats read only `~/.gemini/antigravity-cli/brain/*/.../transcript.jsonl`.

- **Network:** none of its own. `agy` talks to Google's backend, and the credits portal opens in your browser. If the CLI is missing or Google is down, the panel says so plainly and falls back to the last cached numbers, marked as stale.

- **Privacy:** no prompts and no conversation text ever touch a command line. Quota numbers come from your own signed-in CLI and stay on your disk. Removing the plugin changes nothing in Antigravity's own settings — only the cache folder, covered by the uninstall step above.

## Compatibility

Verified on stock **Omarchy 4** (omarchy-shell / Quickshell) with the built-in bar, left/center/right sections, horizontal and vertical bars, and dark and light themes. The helper works on any install that has `agy`; Python ships with Omarchy. Unit tests (`python3 -m unittest discover -s tests`) cover the same normalization code the panel consumes, including the invariant `usedPct + remainingPct == 100`.

## License

MIT
