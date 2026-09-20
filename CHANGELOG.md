# iStats changelog

All notable changes to this plugin. Versions follow the `version` field in
`manifest.json`.

## 1.1.0

- Clicking a reading in the bar opens the dashboard focused on that domain, with
  the domain card first and highlighted.
- CPU focus lists CPU hogs; memory focus lists memory hogs (by RSS).
- Added a dedicated DISK card with filesystem usage and read/write history.
- Added a memory history graph.
- The collector now also emits memory-sorted process data.
- The bar reading widths are pinned so changing rates no longer shift the bar.
- Bar row hit-testing uses a single area over the row mapped to the reading under
  the pointer, keeping the click and the tooltip in agreement.

## 1.0.0

- First release: network, CPU, GPU, memory and disk readings in the bar, with a
  dashboard containing CPU history, per-thread rings, top processes, GPU dials,
  memory, network, load average and uptime.
- Stdlib-only Python collector streaming one JSON frame per second.
- Theme-aware colours read from the active Omarchy theme.
