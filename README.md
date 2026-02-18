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
- Pending order placement logic:
  - Up breakout: places `Buy Limit` on upper line, SL on lower line, TP = 2x opening-candle range.
  - Down breakout: places `Sell Limit` on lower line, SL on upper line, TP = 2x opening-candle range.
- On-chart status panel (`Comment`) is shown every processed candle, including:
  - Buy/Sell permission state
  - Stop-hit/range-block flags
  - Existence of open position or pending order
  - Last action / reason why pending was placed or blocked

## Daily risk/permission rules
- At the start of each new day, all EA rules are reset.
- At the start of each new day, all pending orders for the symbol are deleted.
- At the start of each new day, all lines/markers/arrows created by EA are deleted to keep chart clean.
- Only one open position per symbol is allowed.
- If there is any open position or pending order on symbol, EA will not place a new pending order.
- If a buy trade is stopped out once in the day, no more buy pending orders are allowed that day.
- If a sell trade is stopped out once in the day, no more sell pending orders are allowed that day.
- If both sides got stopped out in the same day, no more trading is allowed for that symbol on that day.
- Range invalidation rule:
  - If a candle close is more than `2x` opening-candle range above the green line, buy side is blocked for that day and buy pending is cancelled.
  - If a candle close is more than `2x` opening-candle range below the red line, sell side is blocked for that day and sell pending is cancelled.
