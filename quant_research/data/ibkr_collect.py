from __future__ import annotations

import csv
import json
import os
import sqlite3
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pandas as pd


@dataclass(frozen=True)
class Instrument:
    symbol: str
    sec_type: str
    exchange: str
    currency: str
    primary_exchange: str
    market: str

    @property
    def key(self) -> str:
        return f"{self.market}_{self.symbol}_{self.sec_type}_{self.exchange}_{self.currency}".replace("/", "-")


def parse_bool(value: str | None, default: bool) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "y"}


def read_universe(path: Path) -> list[Instrument]:
    with path.open(newline="") as handle:
        reader = csv.DictReader(handle)
        return [
            Instrument(
                symbol=row["symbol"].strip(),
                sec_type=row.get("sec_type", "STK").strip() or "STK",
                exchange=row.get("exchange", "SMART").strip() or "SMART",
                currency=row.get("currency", "USD").strip() or "USD",
                primary_exchange=row.get("primary_exchange", "").strip(),
                market=row.get("market", "").strip() or "UNKNOWN",
            )
            for row in reader
        ]


def init_state(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
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


def was_completed(conn: sqlite3.Connection, instrument_key: str, chunk_end: datetime) -> bool:
    row = conn.execute(
        "select status from collection_state where instrument_key = ? and chunk_end = ?",
        (instrument_key, chunk_end.isoformat()),
    ).fetchone()
    return bool(row and row[0] == "ok")


def record_state(
    conn: sqlite3.Connection,
    instrument_key: str,
    chunk_end: datetime,
    status: str,
    rows: int = 0,
    error: str | None = None,
) -> None:
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
        (instrument_key, chunk_end.isoformat(), status, rows, error, datetime.now(timezone.utc).isoformat()),
    )
    conn.commit()


def month_chunks(start: datetime, end: datetime) -> list[datetime]:
    chunks = []
    cursor = end
    while cursor > start:
        chunks.append(cursor)
        cursor = max(start, cursor - timedelta(days=30))
    return chunks


def to_ib_end_time(dt: datetime) -> str:
    return dt.strftime("%Y%m%d %H:%M:%S UTC")


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
        existing = pd.read_parquet(path)
        frame = pd.concat([existing, frame], ignore_index=True)
    frame = frame.drop_duplicates(subset=["time", "symbol", "market"]).sort_values("time")
    frame.to_parquet(path, index=False)
    return len(rows)


def collect_main(args) -> None:
    out = Path(args.out)
    instruments = read_universe(Path(args.universe))
    start = datetime.fromisoformat(args.start).replace(tzinfo=timezone.utc)
    end = datetime.fromisoformat(args.end).replace(tzinfo=timezone.utc)
    bar_size = args.bar_size or os.getenv("IBKR_BAR_SIZE", "1 hour")
    what_to_show = args.what_to_show or os.getenv("IBKR_WHAT_TO_SHOW", "TRADES")
    use_rth = parse_bool(args.use_rth or os.getenv("IBKR_USE_RTH"), True)
    duration = os.getenv("IBKR_CHUNK_DURATION", "1 M")
    sleep_seconds = float(os.getenv("IBKR_REQUEST_SLEEP_SECONDS", "11"))

    manifest = {
        "start": args.start,
        "end": args.end,
        "bar_size": bar_size,
        "what_to_show": what_to_show,
        "use_rth": use_rth,
        "duration": duration,
        "sleep_seconds": sleep_seconds,
        "instrument_count": len(instruments),
    }
    out.mkdir(parents=True, exist_ok=True)
    (out / "collection_manifest.json").write_text(json.dumps(manifest, indent=2))

    if args.dry_run:
        print(json.dumps(manifest, indent=2))
        for instrument in instruments:
            for chunk_end in month_chunks(start, end):
                print(f"DRY {instrument.key} end={to_ib_end_time(chunk_end)}")
        return

    from ib_insync import IB, Stock

    host = os.getenv("IBKR_HOST", "127.0.0.1")
    port = int(os.getenv("IBKR_PORT", "7497"))
    client_id = int(os.getenv("IBKR_CLIENT_ID", "17"))
    readonly = parse_bool(os.getenv("IBKR_READONLY"), True)

    ib = IB()
    ib.connect(host, port, clientId=client_id, readonly=readonly, timeout=20)
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
            for chunk_end in month_chunks(start, end):
                if was_completed(conn, instrument.key, chunk_end):
                    continue
                try:
                    bars = ib.reqHistoricalData(
                        contract,
                        endDateTime=to_ib_end_time(chunk_end),
                        durationStr=duration,
                        barSizeSetting=bar_size,
                        whatToShow=what_to_show,
                        useRTH=use_rth,
                        formatDate=2,
                        keepUpToDate=False,
                    )
                    rows = append_bars(target, bars, instrument)
                    record_state(conn, instrument.key, chunk_end, "ok", rows=rows)
                    print(f"OK {instrument.key} {to_ib_end_time(chunk_end)} rows={rows}")
                except Exception as exc:
                    record_state(conn, instrument.key, chunk_end, "error", error=str(exc))
                    print(f"ERROR {instrument.key} {to_ib_end_time(chunk_end)} {exc}")
                time.sleep(sleep_seconds)
    finally:
        ib.disconnect()
