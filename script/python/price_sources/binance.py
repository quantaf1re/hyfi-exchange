"""
Binance spot-orderbook price source (public endpoint, no auth).

Pair config requirements:
    'spot_pair': Binance spot symbol, e.g. 'ETHUSDC'
"""

import decimal as dec
import json
import time
import urllib.request

D = dec.Decimal

BINANCE_DEPTH_URL = 'https://api.binance.com/api/v3/depth'


def check_env(pair):
    """No env vars required for the public Binance depth endpoint."""


def get_top_of_book(pair, limit=5):
    """Return (best_bid_d, best_ask_d, oracle_ts) for pair['spot_pair'].

    oracle_ts is captured just before the request and is the timestamp the hook
    stores for staleness-fee logic.
    """
    symbol = pair['spot_pair']
    oracle_ts = int(time.time())
    url = f'{BINANCE_DEPTH_URL}?symbol={symbol}&limit={limit}'
    with urllib.request.urlopen(url, timeout=10) as resp:
        book = json.loads(resp.read())
    bids = [(D(p), D(q)) for p, q in book['bids']]
    asks = [(D(p), D(q)) for p, q in book['asks']]
    if not bids or not asks:
        raise RuntimeError(f"Empty orderbook for {symbol}")
    bids.sort(key=lambda x: x[0], reverse=True)
    asks.sort(key=lambda x: x[0])
    return bids[0][0], asks[0][0], oracle_ts
