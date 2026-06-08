from __future__ import annotations

import csv
import math
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd


BARS_PER_YEAR = 252 * 6.5


@dataclass(frozen=True)
class PairParams:
    beta_window: int
    entry_z: float
    horizon: int
    stop_z: float


def read_universe(path: Path, market: str | None) -> pd.DataFrame:
    with path.open(newline="") as handle:
        frame = pd.DataFrame(csv.DictReader(handle))
    if market:
        frame = frame[frame["market"].str.upper() == market.upper()]
    return frame


def load_bars(root: Path, universe: pd.DataFrame) -> dict[str, pd.DataFrame]:
    bars = {}
    for row in universe.itertuples():
        key = f"{row.market}_{row.symbol}_{row.sec_type}_{row.exchange}_{row.currency}".replace("/", "-")
        path = root / "bars_1h" / f"{key}.parquet"
        if not path.exists():
            continue
        frame = pd.read_parquet(path)
        frame["time"] = pd.to_datetime(frame["time"])
        frame = frame.drop_duplicates("time").set_index("time").sort_index()
        bars[row.symbol] = frame[["open", "high", "low", "close", "volume"]]
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
        path = direction * frame["pair_ret"].iloc[i + 1 : exit_i + 1].fillna(0)
        gross = float(path.sum())
        net = gross - 2 * cost_bps / 10_000
        returns.iloc[i + 1 : exit_i + 1] += path.to_numpy()
        returns.iloc[i] -= cost_bps / 10_000
        returns.iloc[exit_i] -= cost_bps / 10_000
        trades.append(
            {
                "entry_time": frame.index[i],
                "exit_time": frame.index[exit_i],
                "entry_z": float(row["z"]),
                "beta": float(row["beta"]),
                "gross_return": gross,
                "net_return": net,
                "hold_bars": exit_i - i,
                "exit_reason": reason,
            }
        )
        i = exit_i + 1
    return returns, pd.DataFrame(trades)


def metrics(returns: pd.Series, trades: pd.DataFrame) -> dict[str, float]:
    returns = returns.fillna(0)
    equity = (1 + returns).cumprod()
    years = len(returns) / BARS_PER_YEAR if len(returns) else np.nan
    std = returns.std()
    pnl = trades["net_return"] if len(trades) else pd.Series(dtype=float)
    wins = pnl[pnl > 0]
    losses = pnl[pnl < 0]
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


def parameter_grid() -> list[PairParams]:
    return [
        PairParams(beta_window=bw, entry_z=z, horizon=h, stop_z=s)
        for bw in [80, 120, 180]
        for z in [1.75, 2.0, 2.25]
        for h in [1, 2, 4]
        for s in [3.0, 3.5]
    ]


def scan_main(args) -> None:
    universe = read_universe(Path(args.universe), args.market)
    bars = load_bars(Path(args.bars), universe)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    rows = []
    latest_cutoff = None
    if bars:
        latest_time = max(frame.index.max() for frame in bars.values())
        latest_cutoff = latest_time - pd.Timedelta(days=args.latest_days)

    params_list = parameter_grid()
    symbols = sorted(bars)
    for i, primary in enumerate(symbols):
        for hedge in symbols[i + 1 :]:
            for params in params_list:
                frame = build_pair(bars[primary], bars[hedge], params)
                if latest_cutoff is not None:
                    frame = frame[frame.index >= latest_cutoff]
                if len(frame) < params.beta_window:
                    continue
                returns, trades = simulate(frame, params, args.cost_bps)
                row = metrics(returns, trades)
                if row["trades"] < args.min_trades:
                    continue
                row.update(
                    {
                        "primary": primary,
                        "hedge": hedge,
                        "beta_window": params.beta_window,
                        "entry_z": params.entry_z,
                        "horizon": params.horizon,
                        "stop_z": params.stop_z,
                        "cost_bps_one_way": args.cost_bps,
                    }
                )
                rows.append(row)

    results = pd.DataFrame(rows)
    if results.empty:
        print("No qualifying pair results. Collect more bars or lower --min-trades.")
        return
    results = results.sort_values(["Sharpe_0rf", "profit_factor", "avg_trade"], ascending=False)
    results.to_csv(out / "relationship_scan.csv", index=False)
    shortlist = results[
        (results["Sharpe_0rf"] > 1.0)
        & (results["profit_factor"] > 1.3)
        & (results["avg_trade"] > (2 * args.cost_bps / 10_000))
    ]
    shortlist.to_csv(out / "shortlist.csv", index=False)
    print(results.head(20).to_string(index=False))
