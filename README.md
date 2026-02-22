# Codex

London open setup experts for MT5.

## Files
- `LondonOpenSetup.mq5` → Base version.
- `LondonOpenSetupV2.mq5` → Version 2 (dynamic breakout line + optional risk-free behavior).

## V2 highlights
- Keeps base logic and daily controls (one buy per day, one sell per day, TP-day lock).
- Uses **dynamic breakout lines** after opening candle:
  - If price wicks above opening high line but closes back below, high line is moved to that candle high.
  - If price wicks below opening low line but closes back above, low line is moved to that candle low.
  - When line moves, a chart text marker is added (`GREEN MOVED` / `RED MOVED`) with old/new values (latest label replaces previous one).
  - Pending orders are still placed from the **opening candle high/low** levels.
  - After a trade is already taken on the symbol/day, line-shift updates are paused.
- Adds optional second-chance risk-free (`InpEnableSecondChanceRiskFree`):
  - If price reaches virtual TP1 (`InpTP1RangeMultiplier * opening-range`),
  - then comes back to entry,
  - then reaches virtual TP-half (`InpTPHalfRangeMultiplier * opening-range`),
  - SL is moved to entry (break-even / risk-free).
- Direct risk-free option (`InpEnableDirectRiskFree`):
  - If price reaches `InpDirectRiskFreeTPMultiplier * opening-range`, SL moves directly to entry.

## Existing configurable behavior
- Adjustable TP/SL multipliers, cancel-range multiplier, pending offset (pips), and normal/reversed direction mode.
- On-chart status panel for debugging in backtest.
