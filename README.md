# kniffo.antigravity-quota

Native **Omarchy 4 (`omarchy-shell`)** bar plugin that displays your live **Google AI / Antigravity plan quota** — showing both **how much you have used** and **how much is left** across every model group and rolling window, alongside Google One AI Credits and local token activity.

## Features

- **Native Omarchy 4 Bar Icon & Chip**: Crisp vector Google AI / Gemini 4-point sparkle icon (`QtQuick.Shapes` with 4x MSAA) that adapts automatically to all Omarchy themes and horizontal/vertical bars, with optional inline `% Left`, `% Used`, or `Used · Left` bar text.
- **Explicit Used vs. Remaining Readout**:
  - **Tightest Quota Hero Card**: Immediate side-by-side **USED %** and **LEFT %** display for your most constrained active quota window.
  - **Per-Group & Per-Window Breakdown**: Tracks rolling **5-Hour** and **Weekly** windows across `Gemini Models`, `Gemini 4 Argon`, and `Claude and GPT models`, with exact complementary percentages (`used + left = 100%`) and live reset countdowns.
- **Google AI Plan & Credits**: Automatically detects your active plan tier (`Google AI Pro`, `Ultra`, `Free`), displays remaining **G1 AI Credits** and `useG1Credits` overage fallback state, and links directly to the credits portal.
- **Local CLI Token Activity**: Incrementally scans local Antigravity CLI transcripts (`~/.gemini/antigravity-cli/brain`) for today's and the last 7 days' token and prompt counts.
- **Sanctioned CLI Integration**: Queries the official `agy` CLI (`-p=/quota` and `-p=/credits` with `--output-format json` and `AGY_CLI_DISABLE_AUTO_UPDATE=true`) with file-locked caching and instant startup hydration.

## Requirements

- **Omarchy 4** (`omarchy-shell` / Quickshell)
- **Python 3**
- **Antigravity CLI (`agy`)** signed in to your Google AI account

## Installation

### Local Install (Symlink-free copy into Omarchy plugins)

Omarchy 4's validator disallows symlinks inside `~/.config/omarchy/plugins/`. Install from this repository via Git or direct copy:

```bash
# Option A: Install via Omarchy's git plugin manager (once committed)
omarchy plugin add /home/kniffo/dev/omarchy-plugin-antigravity-quota --enable --yes

# Option B: Manual install & enable
mkdir -p ~/.config/omarchy/plugins/kniffo.antigravity-quota
rsync -a --delete /home/kniffo/dev/omarchy-plugin-antigravity-quota/ ~/.config/omarchy/plugins/kniffo.antigravity-quota/
omarchy-shell shell rescanPlugins
omarchy plugin enable kniffo.antigravity-quota
```

Move it anywhere on your bar with:

```bash
omarchy bar move kniffo.antigravity-quota --section right
```

Validate at any time with:

```bash
omarchy plugin validate /home/kniffo/dev/omarchy-plugin-antigravity-quota
```

## Bar & Keyboard Controls

### Mouse (Bar Icon)
- **Left-click**: Open / close the Google AI Quota panel
- **Middle-click**: Force an immediate live quota refresh
- **Right-click**: Open inline plugin settings

### Keyboard (Inside Panel)
- `j` / `k` or `↑` / `↓`: Scroll panel
- `r` or `Enter`: Force refresh quota
- `c`: Open Google AI Credits portal in browser
- `s`: Open settings (or save when in settings view)
- `Tab` / `Shift+Tab`: Switch to neighboring Omarchy bar panel
- `Esc`: Exit settings or close panel

### Shell IPC

```bash
omarchy-shell kniffo.antigravity-quota toggle
omarchy-shell kniffo.antigravity-quota refresh
omarchy-shell kniffo.antigravity-quota settings
```

## Configuration (`~/.config/omarchy/shell.json`)

Settings can be changed from the built-in Settings view (`right-click` or `s`) or via `omarchy bar set`:

| Key | Type | Default | Description |
|---|---|---|---|
| `barDisplay` | `"icon" \| "remaining" \| "used" \| "both"` | `"icon"` | Show only the sparkle icon, or include `% Left`, `% Used`, or `Used · Left` on horizontal bars |
| `meterMode` | `"used" \| "remaining"` | `"used"` | Fill progress meters upward with `% Used` or drain downward with `% Left` |
| `warningThresholdPct` | integer (`50`–`99`) | `80` | Highlight icon/percentages in accent color once `% Used` reaches this threshold (`>=90%` uses urgent color) |
| `refreshIntervalSec` | integer (`30`–`3600`) | `300` | Background polling interval in seconds |
| `cliPath` | string | `""` | Optional explicit path to `agy` executable |

## License

MIT
