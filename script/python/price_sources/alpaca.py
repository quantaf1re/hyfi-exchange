"""
Alpaca stock-quote price source (auth via ALPACA_API_KEY / ALPACA_API_SECRET_KEY).

Used for tokenised stocks priced off the underlying US equities.

Pair config requirements:
    'stock_symbol': Alpaca symbol of the underlying stock, e.g. 'NVDA'
"""

import decimal as dec
import json
import os
import time
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo

D = dec.Decimal

ALPACA_QUOTES_URL = 'https://data.alpaca.markets/v2/stocks/quotes/latest'
ET_TZ = ZoneInfo('America/New_York')


def check_env(pair):
    """Raise if the Alpaca API credentials are not set."""
    if not os.getenv('ALPACA_API_KEY') or not os.getenv('ALPACA_API_SECRET_KEY'):
        raise RuntimeError(
            f"Missing env vars (ALPACA_API_KEY set={bool(os.getenv('ALPACA_API_KEY'))}, "
            f"ALPACA_API_SECRET_KEY set={bool(os.getenv('ALPACA_API_SECRET_KEY'))})"
        )


def _feed_now():
    """Pick the Alpaca feed by the current US/Eastern clock.

    - 'sip' covers ~4:00-20:00 ET (pre-market, regular and after-hours)
    - 'overnight' covers 20:00-4:00 ET

    Together these give continuous two-sided quotes 24h, 5 days a week.

    Alpaca never switches feeds automatically — omitting `feed` defaults to
    'sip' on unlimited subscriptions and 'iex' otherwise — so always pass it
    explicitly.
    """
    now_et = datetime.now(ET_TZ)
    return 'sip' if 4 <= now_et.hour < 20 else 'overnight'


def get_top_of_book(pair):
    """Return (best_bid_d, best_ask_d, oracle_ts) for pair['stock_symbol'].

    oracle_ts is captured just before the request and is the timestamp the hook
    stores for staleness-fee logic.
    """
    symbol = pair['stock_symbol']
    oracle_ts = int(time.time())
    feed = _feed_now()
    url = f'{ALPACA_QUOTES_URL}?symbols={symbol}&feed={feed}'
    req = urllib.request.Request(url, headers={
        'APCA-API-KEY-ID':     os.getenv('ALPACA_API_KEY'),
        'APCA-API-SECRET-KEY': os.getenv('ALPACA_API_SECRET_KEY'),
    })
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read())
    quote = data.get('quotes', {}).get(symbol)
    if not quote:
        raise RuntimeError(f'No {feed} quote returned for {symbol}')
    best_bid_d, best_ask_d = D(str(quote['bp'])), D(str(quote['ap']))
    # Alpaca uses 0 to mean "no active bid/ask" (e.g. market closed on weekends)
    if best_bid_d <= 0 or best_ask_d <= 0:
        raise RuntimeError(f"No active bid/ask for {symbol} on feed {feed} (bp={quote['bp']}, ap={quote['ap']})")
    return best_bid_d, best_ask_d, oracle_ts
