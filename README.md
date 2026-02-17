# Codex

London open setup expert for MT5.

## File
- `LondonOpenSetup.mq5`

## Behavior implemented
- Input for timeframe (default `M15`).
- Input for London open broker time (default `11:30`).
- Input for allowed symbols (default `XAUUSD,US30,USDJPY,AUDJPY`).
- Runs only on allowed symbols (supports broker suffixes, e.g. `XAUUSD.a`).
- Waits until the first candle after open is fully closed.
- When next candle opens, it captures high/low of the London-open candle.
- Draws:
  - Horizontal line on candle high.
  - Horizontal line on candle low.
  - Vertical marker at candle open time.
  - Vertical marker at candle close time.
- After levels are set, on each closed candle:
  - If close is above the high line, draws an up arrow on that candle.
  - If close is below the low line, draws a down arrow on that candle.
