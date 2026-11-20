# omarchy-performance

A bar widget for [Omarchy](https://omarchy.org) that shows CPU and RAM usage at a glance and expands into a live performance panel — modelled on the built-in battery widget.

> **Credit:** Forked from [orviwan/omarchy-performance](https://github.com/orviwan/omarchy-performance) by Jon Barlow.

## Features

- **Bar button** — shows CPU% and RAM `x% (y.yG)` with chip and memory icons, colour-coded automatically:
  - CPU (by peak temperature): Normal → Amber (≥ 70 °C) → Red (≥ 90 °C)
  - RAM (by usage): Normal → Amber (≥ 80 %) → Red (≥ 92 %)
- **Click to open panel** with:
  - CPU % hero with animated progress bar
  - CPU temperature reading + bar
  - GPU temperature reading + bar (shown automatically when detected)
  - Fan RPM + bar (scales dynamically to the sensor's max RPM)
  - Memory used / total + bar
  - **Open in btop** button for deep inspection
- **Automatic hardware detection** via `sensors -j` (AMD `k10temp`, Intel `coretemp`, Dell `dell_smm`, `acpitz`, AMD/NVIDIA/Radeon GPU sensors, and generic fan sensors)
- **Built-in translations** (`en` and `fr`), following Omarchy's language setting live
- **IPC support** (`omarchy-shell skyhonnor.performance toggle`)
- Polls every **4 s** at rest, **2 s** while the panel is open

## Requirements

- [Omarchy](https://omarchy.org) 4.x (Quattro)
- `lm_sensors` — for temperature and fan readings
  ```bash
  omarchy pkg add lm_sensors
  sudo sensors-detect --auto
  ```
- `btop` — for the "Open in btop" button (included by default in Omarchy)

## Installation

```bash
omarchy plugin add https://github.com/SkyHonnor/omarchy-performance.git --enable
```

The plugin is placed to the right of the bar by default (before the battery/power widget). Move it with:

```bash
omarchy bar move skyhonnor.performance --section left
```

## Sensor detection

The plugin reads `sensors -j` directly and picks the best available sensors automatically:

| Metric | Supported sensors |
|--------|-------------------|
| CPU temperature | `k10temp` (`Tctl` / `Tdie`), `coretemp` (`Package id 0`), `dell_smm` (`CPU`), `acpitz` (`temp1`) |
| GPU temperature | `amdgpu` / `radeon` / `nouveau` (`edge`, `junction`, `temp1`) |
| Fan speed | First available `fan*_input` (with dynamic `fan*_max` scaling) |

To customise sensor priority or add another chip, edit `parseSensorsJson()` in `Panel.qml`.

## Uninstall

```bash
omarchy plugin remove skyhonnor.performance
```

## License

MIT — see [LICENSE](LICENSE). Originally created by [Jon Barlow (orviwan)](https://github.com/orviwan/omarchy-performance).
