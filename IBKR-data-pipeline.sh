#!/usr/bin/env bash
set -euo pipefail

# IBKR Data Pipeline
#
# This single file expands into a Docker-ready IBKR data collection and
# relationship-scan bundle. It is intentionally committed as one file so future
# VMs can duplicate the workflow without storing a full app tree in the repo.

TARGET_DIR="${1:-ibkr-data-pipeline}"

mkdir -p "${TARGET_DIR}/app" "${TARGET_DIR}/config" "${TARGET_DIR}/data" "${TARGET_DIR}/reports"

cat > "${TARGET_DIR}/Dockerfile" <<'EOF'
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tini \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY app /app/app
COPY config /app/config

ENTRYPOINT ["/usr/bin/tini", "--", "python", "-m", "app.ibkr_pipeline"]
EOF

cat > "${TARGET_DIR}/requirements.txt" <<'EOF'
ib-insync==0.9.86
numpy
pandas
pyarrow
EOF

cat > "${TARGET_DIR}/docker-compose.yml" <<'EOF'
services:
  ibkr-data-pipeline:
    build:
      context: .
      dockerfile: Dockerfile
    image: homelab-ibkr-data-pipeline:latest
    env_file:
      - .env.example
    volumes:
      - ./data:/app/data
      - ./reports:/app/reports
      - ./config:/app/config:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    command: ["--help"]
EOF

cat > "${TARGET_DIR}/.env.example" <<'EOF'
# Copy to .env.private and edit. Do not commit real credentials or account data.

# IB Gateway / TWS API. Use paper first: 7497 is common for TWS paper,
# 4002 is common for IB Gateway paper, but confirm your local config.
IBKR_HOST=host.docker.internal
IBKR_PORT=7497
IBKR_CLIENT_ID=17
IBKR_READONLY=true

# Conservative pacing. IBKR historical data is not an unlimited bulk data feed.
IBKR_REQUEST_SLEEP_SECONDS=11
IBKR_CHUNK_DAYS=30
IBKR_BAR_SIZE=1 hour
IBKR_WHAT_TO_SHOW=TRADES
IBKR_USE_RTH=true
EOF

cat > "${TARGET_DIR}/config/universe_seed.csv" <<'EOF'
market,symbol,sec_type,exchange,currency,primary_exchange
US,XLE,STK,SMART,USD,ARCA
US,USO,STK,SMART,USD,ARCA
US,XOP,STK,SMART,USD,ARCA
US,SPY,STK,SMART,USD,ARCA
US,QQQ,STK,SMART,USD,NASDAQ
US,SMH,STK,SMART,USD,NASDAQ
US,SOXX,STK,SMART,USD,NASDAQ
US,IWM,STK,SMART,USD,ARCA
HK,2800,STK,SEHK,HKD,SEHK
HK,2828,STK,SEHK,HKD,SEHK
SG,ES3,STK,SGX,SGD,SGX
SG,G3B,STK,SGX,SGD,SGX
UK,ISF,STK,LSE,GBP,LSE
UK,VUKE,STK,LSE,GBP,LSE
EOF

cat > "${TARGET_DIR}/app/__init__.py" <<'EOF'
"""IBKR data pipeline package."""
EOF

cat > "${TARGET_DIR}/app/ibkr_pipeline.py" <<'EOF'
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import sqlite3
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
import pandas as pd


BARS_PER_YEAR = 252 * 6.5


@dataclass(frozen=True)
class Instrument:
    market: str
    symbol: str
    sec_type: str
    exchange: str
    currency: str
    primary_exchange: str

    @property
    def key(self) -> str:
        return f"{self.market}_{self.symbol}_{self.sec_type}_{self.exchange}_{self.currency}".replace("/", "-")


@dataclass(frozen=True)
class PairParams:
    beta_window: int
    entry_z: float
    horizon: int
    stop_z: float


def parse_bool(value: str | None, default: bool) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "y"}


def read_universe(path: Path, market: str | None = None) -> list[Instrument]:
    with path.open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    instruments = [
        Instrument(
            market=row.get("market", "UNKNOWN").strip(),
            symbol=row["symbol"].strip(),
            sec_type=row.get("sec_type", "STK").strip() or "STK",
            exchange=row.get("exchange", "SMART").strip() or "SMART",
            currency=row.get("currency", "USD").strip() or "USD",
            primary_exchange=row.get("primary_exchange", "").strip(),
        )
        for row in rows
    ]
    if market:
        instruments = [i for i in instruments if i.market.upper() == market.upper()]
    return instruments


def month_chunks(start: datetime, end: datetime, chunk_days: int) -> list[datetime]:
    chunks = []
    cursor = end
    while cursor > start:
        chunks.append(cursor)
        cursor = max(start, cursor - timedelta(days=chunk_days))
    return chunks


def ib_end_time(dt: datetime) -> str:
    return dt.strftime("%Y%m%d %H:%M:%S UTC")


def init_state(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.execute(
        """
        create table if not exists collection_state (
            instrument_key text not null,
            chunk_end text not null,
            status text not null,
            rows integer not null default 0,
            error text,
            updated_at text not null,
            primary key (instrument_key, chunk_end)
        )
        """
    )
    return conn


def completed(conn: sqlite3.Connection, key: str, chunk_end: datetime) -> bool:
    row = conn.execute(
        "select status from collection_state where instrument_key = ? and chunk_end = ?",
        (key, chunk_end.isoformat()),
    ).fetchone()
    return bool(row and row[0] == "ok")


def record(conn: sqlite3.Connection, key: str, chunk_end: datetime, status: str, rows: int = 0, error: str | None = None) -> None:
    conn.execute(
        """
        insert into collection_state(instrument_key, chunk_end, status, rows, error, updated_at)
        values(?, ?, ?, ?, ?, ?)
        on conflict(instrument_key, chunk_end) do update set
            status = excluded.status,
            rows = excluded.rows,
            error = excluded.error,
            updated_at = excluded.updated_at
        """,
        (key, chunk_end.isoformat(), status, rows, error, datetime.now(timezone.utc).isoformat()),
    )
    conn.commit()


def append_bars(path: Path, bars: list[object], instrument: Instrument) -> int:
    rows = []
    for bar in bars:
        rows.append(
            {
                "time": pd.Timestamp(bar.date).tz_localize(None) if getattr(bar, "date", None) is not None else None,
                "symbol": instrument.symbol,
                "market": instrument.market,
                "open": bar.open,
                "high": bar.high,
                "low": bar.low,
                "close": bar.close,
                "volume": bar.volume,
                "bar_count": getattr(bar, "barCount", None),
                "wap": getattr(bar, "average", None),
            }
        )
    if not rows:
        return 0
    frame = pd.DataFrame(rows).dropna(subset=["time"])
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        frame = pd.concat([pd.read_parquet(path), frame], ignore_index=True)
    frame = frame.drop_duplicates(["time", "symbol", "market"]).sort_values("time")
    frame.to_parquet(path, index=False)
    return len(rows)


def collect(args: argparse.Namespace) -> None:
    start = datetime.fromisoformat(args.start).replace(tzinfo=timezone.utc)
    end = datetime.fromisoformat(args.end).replace(tzinfo=timezone.utc)
    out = Path(args.out)
    instruments = read_universe(Path(args.universe), args.market)
    bar_size = args.bar_size or os.getenv("IBKR_BAR_SIZE", "1 hour")
    what = args.what_to_show or os.getenv("IBKR_WHAT_TO_SHOW", "TRADES")
    use_rth = parse_bool(args.use_rth or os.getenv("IBKR_USE_RTH"), True)
    chunk_days = int(os.getenv("IBKR_CHUNK_DAYS", "30"))
    sleep_seconds = float(os.getenv("IBKR_REQUEST_SLEEP_SECONDS", "11"))

    manifest = {
        "start": args.start,
        "end": args.end,
        "market": args.market,
        "bar_size": bar_size,
        "what_to_show": what,
        "use_rth": use_rth,
        "chunk_days": chunk_days,
        "sleep_seconds": sleep_seconds,
        "instrument_count": len(instruments),
    }
    out.mkdir(parents=True, exist_ok=True)
    (out / "collection_manifest.json").write_text(json.dumps(manifest, indent=2))

    if args.dry_run:
        print(json.dumps(manifest, indent=2))
        for instrument in instruments:
            for chunk_end in month_chunks(start, end, chunk_days):
                print(f"DRY {instrument.key} end={ib_end_time(chunk_end)}")
        return

    from ib_insync import IB, Stock

    ib = IB()
    ib.connect(
        os.getenv("IBKR_HOST", "127.0.0.1"),
        int(os.getenv("IBKR_PORT", "7497")),
        clientId=int(os.getenv("IBKR_CLIENT_ID", "17")),
        readonly=parse_bool(os.getenv("IBKR_READONLY"), True),
        timeout=20,
    )
    conn = init_state(out / "collection_state.sqlite")
    try:
        for instrument in instruments:
            contract = Stock(
                instrument.symbol,
                instrument.exchange,
                instrument.currency,
                primaryExchange=instrument.primary_exchange or None,
            )
            qualified = ib.qualifyContracts(contract)
            if not qualified:
                raise RuntimeError(f"IBKR could not qualify contract: {instrument}")
            contract = qualified[0]
            target = out / "bars_1h" / f"{instrument.key}.parquet"
            for chunk_end in month_chunks(start, end, chunk_days):
                if completed(conn, instrument.key, chunk_end):
                    continue
                try:
                    bars = ib.reqHistoricalData(
                        contract,
                        endDateTime=ib_end_time(chunk_end),
                        durationStr=f"{chunk_days} D",
                        barSizeSetting=bar_size,
                        whatToShow=what,
                        useRTH=use_rth,
                        formatDate=2,
                        keepUpToDate=False,
                    )
                    rows = append_bars(target, bars, instrument)
                    record(conn, instrument.key, chunk_end, "ok", rows=rows)
                    print(f"OK {instrument.key} {ib_end_time(chunk_end)} rows={rows}")
                except Exception as exc:
                    record(conn, instrument.key, chunk_end, "error", error=str(exc))
                    print(f"ERROR {instrument.key} {ib_end_time(chunk_end)} {exc}")
                time.sleep(sleep_seconds)
    finally:
        ib.disconnect()


def load_bars(root: Path, instruments: list[Instrument]) -> dict[str, pd.DataFrame]:
    bars = {}
    for instrument in instruments:
        path = root / "bars_1h" / f"{instrument.key}.parquet"
        if not path.exists():
            continue
        frame = pd.read_parquet(path)
        frame["time"] = pd.to_datetime(frame["time"])
        bars[instrument.symbol] = frame.drop_duplicates("time").set_index("time").sort_index()
    return bars


def rolling_beta(y: pd.Series, x: pd.Series, window: int) -> tuple[pd.Series, pd.Series]:
    beta = y.rolling(window).cov(x) / x.rolling(window).var()
    alpha = y.rolling(window).mean() - beta * x.rolling(window).mean()
    return alpha, beta


def build_pair(primary: pd.DataFrame, hedge: pd.DataFrame, params: PairParams) -> pd.DataFrame:
    close = pd.concat({"p": primary["close"], "h": hedge["close"]}, axis=1).dropna()
    y = np.log(close["p"])
    x = np.log(close["h"])
    alpha, beta = rolling_beta(y, x, params.beta_window)
    spread = y - alpha - beta * x
    z = (spread - spread.rolling(params.beta_window).mean()) / spread.rolling(params.beta_window).std()
    pair_ret = close["p"].pct_change() - beta.shift(1) * close["h"].pct_change()
    return pd.DataFrame({"z": z, "beta": beta, "pair_ret": pair_ret}).replace([np.inf, -np.inf], np.nan).dropna()


def simulate(frame: pd.DataFrame, params: PairParams, cost_bps: float) -> tuple[pd.Series, pd.DataFrame]:
    returns = pd.Series(0.0, index=frame.index)
    trades = []
    i = 0
    while i < len(frame) - params.horizon - 1:
        row = frame.iloc[i]
        if abs(row["z"]) < params.entry_z:
            i += 1
            continue
        direction = -np.sign(row["z"])
        exit_i = min(i + params.horizon, len(frame) - 1)
        reason = "horizon"
        for j in range(i + 1, min(i + params.horizon + 1, len(frame))):
            z_now = frame["z"].iloc[j]
            if np.sign(z_now) != np.sign(row["z"]) or abs(z_now) < 0.25:
                exit_i = j
                reason = "mean_revert"
                break
            if abs(z_now) >= params.stop_z:
                exit_i = j
                reason = "stop"
                break
        gross = float((direction * frame["pair_ret"].iloc[i + 1 : exit_i + 1].fillna(0)).sum())
        net = gross - 2 * cost_bps / 10_000
        returns.iloc[i] -= cost_bps / 10_000
        returns.iloc[exit_i] += net + cost_bps / 10_000
        trades.append({"entry": frame.index[i], "exit": frame.index[exit_i], "net_return": net, "hold_bars": exit_i - i, "exit_reason": reason})
        i = exit_i + 1
    return returns, pd.DataFrame(trades)


def metrics(returns: pd.Series, trades: pd.DataFrame) -> dict[str, float]:
    equity = (1 + returns.fillna(0)).cumprod()
    std = returns.std()
    pnl = trades["net_return"] if len(trades) else pd.Series(dtype=float)
    wins = pnl[pnl > 0]
    losses = pnl[pnl < 0]
    years = len(returns) / BARS_PER_YEAR if len(returns) else np.nan
    return {
        "total_return": float(equity.iloc[-1] - 1) if len(equity) else 0.0,
        "Sharpe_0rf": float(returns.mean() / std * math.sqrt(BARS_PER_YEAR)) if std and std > 0 else np.nan,
        "max_drawdown": float((equity / equity.cummax() - 1).min()) if len(equity) else 0.0,
        "trades": int(len(trades)),
        "trades_per_year": float(len(trades) / years) if years and years > 0 else np.nan,
        "win_rate": float((pnl > 0).mean()) if len(pnl) else np.nan,
        "avg_trade": float(pnl.mean()) if len(pnl) else np.nan,
        "profit_factor": float(wins.sum() / abs(losses.sum())) if abs(losses.sum()) > 0 else np.nan,
    }


def scan(args: argparse.Namespace) -> None:
    instruments = read_universe(Path(args.universe), args.market)
    bars = load_bars(Path(args.bars), instruments)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    if not bars:
        print("No cached bars found. Run collect first.")
        return
    latest_time = max(frame.index.max() for frame in bars.values())
    cutoff = latest_time - pd.Timedelta(days=args.latest_days)
    params_list = [
        PairParams(beta_window=bw, entry_z=z, horizon=h, stop_z=s)
        for bw in [80, 120, 180]
        for z in [1.75, 2.0, 2.25]
        for h in [1, 2, 4]
        for s in [3.0, 3.5]
    ]
    rows = []
    symbols = sorted(bars)
    for i, primary in enumerate(symbols):
        for hedge in symbols[i + 1 :]:
            for params in params_list:
                frame = build_pair(bars[primary], bars[hedge], params)
                frame = frame[frame.index >= cutoff]
                if len(frame) < params.beta_window:
                    continue
                returns, trades = simulate(frame, params, args.cost_bps)
                row = metrics(returns, trades)
                if row["trades"] < args.min_trades:
                    continue
                row.update({"primary": primary, "hedge": hedge, **params.__dict__})
                rows.append(row)
    results = pd.DataFrame(rows)
    if results.empty:
        print("No qualifying pair results.")
        return
    results = results.sort_values(["Sharpe_0rf", "profit_factor", "avg_trade"], ascending=False)
    results.to_csv(out / "relationship_scan.csv", index=False)
    shortlist = results[(results["Sharpe_0rf"] > 1.0) & (results["profit_factor"] > 1.3) & (results["avg_trade"] > 2 * args.cost_bps / 10_000)]
    shortlist.to_csv(out / "shortlist.csv", index=False)
    print(results.head(20).to_string(index=False))


def main() -> None:
    parser = argparse.ArgumentParser(prog="ibkr-data-pipeline")
    sub = parser.add_subparsers(dest="command", required=True)
    collect_cmd = sub.add_parser("collect")
    collect_cmd.add_argument("--universe", default="config/universe_seed.csv")
    collect_cmd.add_argument("--market", default=None)
    collect_cmd.add_argument("--out", default="data/ibkr")
    collect_cmd.add_argument("--start", required=True)
    collect_cmd.add_argument("--end", required=True)
    collect_cmd.add_argument("--bar-size", default=None)
    collect_cmd.add_argument("--what-to-show", default=None)
    collect_cmd.add_argument("--use-rth", default=None, choices=["true", "false"])
    collect_cmd.add_argument("--dry-run", action="store_true")

    scan_cmd = sub.add_parser("scan")
    scan_cmd.add_argument("--bars", default="data/ibkr")
    scan_cmd.add_argument("--universe", default="config/universe_seed.csv")
    scan_cmd.add_argument("--market", default=None)
    scan_cmd.add_argument("--out", default="reports/relationship_scan")
    scan_cmd.add_argument("--latest-days", type=int, default=22)
    scan_cmd.add_argument("--cost-bps", type=float, default=3.0)
    scan_cmd.add_argument("--min-trades", type=int, default=8)

    args = parser.parse_args()
    if args.command == "collect":
        collect(args)
    elif args.command == "scan":
        scan(args)


if __name__ == "__main__":
    main()
EOF

cat > "${TARGET_DIR}/README.md" <<'EOF'
# IBKR Data Pipeline

This bundle collects throttled 1-hour IBKR historical bars into Parquet files and scans cached bars for retail stat-arb pair relationships.

Build:

```bash
docker compose build
```

Dry-run collection schedule:

```bash
docker compose run --rm ibkr-data-pipeline collect --start 2026-01-01 --end 2026-06-09 --dry-run
```

Collect bars after IB Gateway/TWS API is enabled:

```bash
cp .env.example .env.private
docker compose --env-file .env.private run --rm ibkr-data-pipeline collect --start 2026-01-01 --end 2026-06-09 --market US
```

Scan latest-month relationships from cached bars:

```bash
docker compose run --rm ibkr-data-pipeline scan --market US --latest-days 22 --cost-bps 3
```

IBKR notes:

- Historical bars require relevant market-data subscriptions.
- Historical requests are paced and chunked; do not treat IBKR as an unlimited bulk data feed.
- Use `TRADES` bars for broad scans, then add `BID_ASK` only for shortlisted execution-cost validation.
EOF

echo "Created ${TARGET_DIR}"
echo "Next:"
echo "  cd ${TARGET_DIR}"
echo "  docker compose build"
echo "  docker compose run --rm ibkr-data-pipeline collect --start 2026-01-01 --end 2026-06-09 --dry-run"
