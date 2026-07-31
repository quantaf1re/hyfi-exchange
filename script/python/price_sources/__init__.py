"""
Price-source modules for update_prices.py.

Each module exposes:
    check_env(pair)        -> raises RuntimeError if the pair's config or
                              required env vars are invalid/missing
    get_top_of_book(pair)  -> (best_bid_d, best_ask_d, oracle_ts)

Which source a pair uses is set by the 'price_source' key in its CONFIGS entry.
'cross' composes any two other sources, enabling pairs like NVDA-ETH where the
quote token is priced by a different feed than the base.
"""

from . import binance, alpaca, cross

PRICE_SOURCES = {
    'binance': binance,
    'alpaca': alpaca,
    'cross': cross,
}
