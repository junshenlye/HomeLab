from __future__ import annotations

import argparse

from quant_research.data.ibkr_collect import collect_main
from quant_research.research.relationship_scan import scan_main


def main() -> None:
    parser = argparse.ArgumentParser(prog="quant-research")
    subparsers = parser.add_subparsers(dest="command", required=True)

    collect = subparsers.add_parser("collect-ibkr", help="Collect resumable IBKR historical bars")
    collect.add_argument("--universe", default="config/universe_seed.csv")
    collect.add_argument("--out", default="data/ibkr")
    collect.add_argument("--start", required=True, help="Inclusive start date, YYYY-MM-DD")
    collect.add_argument("--end", required=True, help="Exclusive end date, YYYY-MM-DD")
    collect.add_argument("--bar-size", default=None)
    collect.add_argument("--what-to-show", default=None)
    collect.add_argument("--use-rth", default=None, choices=["true", "false"])
    collect.add_argument("--dry-run", action="store_true")

    scan = subparsers.add_parser("scan-relationships", help="Scan pair residual mean reversion from cached bars")
    scan.add_argument("--bars", default="data/ibkr")
    scan.add_argument("--universe", default="config/universe_seed.csv")
    scan.add_argument("--out", default="reports/relationship_scan")
    scan.add_argument("--market", default=None, help="Optional market filter, e.g. US/HK/SG/UK")
    scan.add_argument("--lookback-days", type=int, default=45)
    scan.add_argument("--latest-days", type=int, default=22)
    scan.add_argument("--cost-bps", type=float, default=3.0)
    scan.add_argument("--min-trades", type=int, default=8)

    args = parser.parse_args()
    if args.command == "collect-ibkr":
        collect_main(args)
    elif args.command == "scan-relationships":
        scan_main(args)


if __name__ == "__main__":
    main()
