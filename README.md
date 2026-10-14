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
├── Sources/
│   └── GravityBar/
│       ├── GravityBarApp.swift
│       ├── StatusBarController.swift
│       ├── Models/
│       │   └── UsageMetric.swift
│       ├── Services/
│       │   ├── UsageManager.swift
│       │   └── Providers/
│       └── Views/
│           ├── PopoverView.swift
│           ├── UsageMetricRowView.swift
│           └── SettingsView.swift
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

## Quick Start (Mockup Preview)

Open the interactive HTML mockup in your browser to inspect or tweak the UI styles, colors, and layouts before building the native Swift app:

```bash
open mockup/index.html
```

---

## License

MIT
