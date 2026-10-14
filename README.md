# GravityBar 📊

> **GravityBar** is a native macOS menu bar utility built in Swift & SwiftUI that gives developers and AI power users real-time visibility into usage limits, quota consumption, rate limits, and countdown timers across Claude, Codex, and Antigravity / Gemini.

---

## Key Features

- **Menu Bar Status Item**: Compact, non-intrusive status item with dynamic SF Symbol gauges reflecting current highest urgency quota.
- **Rich Interactive Popover**:
  - Instant inspection on click or hover.
  - Overall quota health summary with live last-updated timestamps and manual refresh button.
  - Granular progress meters for every provider with color-coded thresholds:
    - 🟢 **Normal**: `< 60%`
    - 🟡 **Elevated**: `60% - 85%`
    - 🔴 **Critical / Rate-Limited**: `> 85%`
  - Reset countdowns (e.g. `78% used • Resets in 1h 42m`).
- **Provider Support**:
  1. **Claude**: 5-hour rolling window + weekly window (percentages and reset countdowns).
  2. **Codex**: 5-hour rolling window + weekly window (percentages and reset countdowns).
  3. **Antigravity / Gemini**: 5-hour rolling window + weekly window (percentages and reset countdowns).
  4. **Mock Provider**: Zero-config mock dataset for offline design iteration and testing.
- **Preferences & Configuration**:
  - Per-provider enable/disable toggles (customize per personal or work Mac).
  - Adjustable background polling intervals (30s, 1m, 5m).
  - Custom log file and session token paths.
  - Mock mode toggle for rapid UI development.

---

## Project Structure

```
gravity-bar/
├── .github/
│   ├── dependabot.yml       # Dependency update bot config
│   └── workflows/
│       ├── ci.yml            # macOS Swift build & test CI
│       └── security.yml      # Gitleaks automated secret scanning
├── mockup/
│   └── index.html           # Interactive HTML/CSS prototype & style lab
├── scripts/
│   └── build_app.sh         # Release build and .app bundle packager
├── Sources/
│   └── GravityBar/
│       ├── GravityBarApp.swift
│       ├── StatusBarController.swift
│       ├── Models/
│       │   ├── GravityBarTokens.swift
│       │   └── UsageMetric.swift
│       ├── Services/
│       │   ├── UsageManager.swift
│       │   └── Providers/
│       └── Views/
│           ├── PopoverView.swift
│           ├── UsageMetricRowView.swift
│           └── SettingsView.swift
├── Makefile
├── Package.swift
├── .gitignore
└── README.md
```

---

## Branching & Workflow

- `main`: Production-ready releases only.
- `develop`: Integration branch for active feature development.
- `feature/*`: Dedicated branches for individual modules and features.

---

## Quick Start

### 1. Build and Run Native App
Build the native macOS menu bar application using either `make` or Swift Package Manager:

```bash
# Run automated self-tests
make test

# Launch GravityBar in the menu bar (live development)
make run

# Build standalone macOS Application bundle (dist/GravityBar.app)
make app

# Install GravityBar to /Applications
make install
```


> **Note**: When GravityBar launches, it docks in your macOS menu bar with a gauge icon and quota percentage. Click the menu bar item or hover over it to inspect the popover.

### 2. Configure Credentials & Local Paths
GravityBar comes with **Mock Mode** enabled by default so you can inspect the UI immediately out of the box.

To connect live accounts:
1. Open the Popover and click the **Preferences** gear (`⚙`).
2. Toggle off **Mock Provider Mode**.
3. Enable or disable providers (customize for work Mac with Codex or personal Mac with Claude/Gemini).
4. Specify paths to local state/session files:
   - **Claude**: `~/.claude/state.json`
   - **Codex**: `~/.codex/session.json`
   - **Gemini**: `~/.gemini/antigravity-ide/metrics.json`
5. Click **Apply & Close**. If local files are not yet present, GravityBar gracefully falls back to synthetic mock values without crashing.

### 3. Interactive Mockup Preview
Before or alongside native app usage, you can inspect or modify styles in the browser:

```bash
open mockup/index.html
```

---

## License

MIT
