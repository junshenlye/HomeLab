# IBKR Data Pipeline

## Purpose

This pipeline makes market data collection a planned process instead of a repeated research roadblock.

The workflow is:

1. Run IB Gateway or TWS with API enabled.
2. Run the `quant-research` Docker container.
3. Collect 1-hour bars into `data/ibkr/bars_1h/*.parquet`.
4. Run mass pair relationship scans from cached bars.
5. Shortlist only pairs with current-month performance after costs.
6. Run deeper pair-specific walk-forward validation before any execution integration.

## IBKR Constraints To Design Around

IBKR is a broker data source, not an unlimited historical data warehouse. The collector is intentionally conservative:

- Historical API data requires the same market-data subscription permission as streaming top-of-book data.
- Historical requests must be chunked so each request returns only a few thousand bars.
- IBKR documents historical pacing constraints and warns that excessive requests can trigger throttling or disconnects.
- Streaming top-of-book subscriptions consume market data lines.
- BID_ASK historical requests count more heavily than trade bars.

Official references:

- Historical market data subscription requirement: https://interactivebrokers.github.io/tws-api/historical_data.html
- Historical data pacing and chunk-size limitations: https://interactivebrokers.github.io/tws-api/historical_limitations.html
- Market data line behavior: https://interactivebrokers.github.io/tws-api/market_data.html
- API pacing overview: https://www.interactivebrokers.com/campus/ibkr-api-page/twsapi-doc/

Practical default for research collection:

- Use `1 hour` bars.
- Pull `TRADES` first; add `BID_ASK` only for shortlisted execution-cost validation.
- Request one-month chunks.
- Sleep between requests.
- Persist request state in SQLite so failed jobs resume.
- Keep the initial universe small by market, then expand.

## Local Commands

Build the container:

```bash
docker compose build quant-research
```

Dry-run a collection job:

```bash
docker compose run --rm quant-research collect-ibkr \
  --universe config/universe_seed.csv \
  --start 2026-01-01 \
  --end 2026-06-09 \
  --dry-run
```

Collect bars, assuming IB Gateway or TWS is reachable:

```bash
docker compose run --rm --env-file .env.quant.private quant-research collect-ibkr \
  --universe config/universe_seed.csv \
  --start 2026-01-01 \
  --end 2026-06-09
```

Scan latest-month relationships from cached bars:

```bash
docker compose run --rm quant-research scan-relationships \
  --bars data/ibkr \
  --universe config/universe_seed.csv \
  --market US \
  --latest-days 22 \
  --cost-bps 3
```

## Research Standard

A candidate does not pass because the full-period scan looks good. It must pass this sequence:

1. Relationship exists structurally: hedge ratio is stable enough to price the spread.
2. Latest-month 1-hour residual dislocations have positive net expectancy after estimated costs.
3. Nested walk-forward validation survives parameter selection using only prior data.
4. Bid/ask or live quote replay shows the average trade edge survives real spread and slippage.
5. Execution design supports pair-order fill control and immediate flattening when one leg fails.
