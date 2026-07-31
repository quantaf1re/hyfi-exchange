"""
Cross price source — composes two legs from other price sources.

Prices base/quote as base_leg ÷ quote_leg. Each leg is itself a pair config for
any registered price source ('binance', 'alpaca', or even another 'cross'), so
any token can be paired with a tokenised stock as long as both legs are quoted
in the same numeraire (typically USD).

Pair config requirements:
    'base_leg':  leg config pricing the base token in the numeraire
    'quote_leg': leg config pricing the quote token in the numeraire

Leg config: {'price_source': <name>, <source-specific keys>, 'invert': bool?}
    'invert' (optional) flips a leg quoted the wrong way round
    (e.g. a Binance pair whose quote side is the token you want to price).

Example (NVDA-ETH):
    'base_leg':  {'price_source': 'alpaca',  'stock_symbol': 'NVDA'},  # NVDA/USD
    'quote_leg': {'price_source': 'binance', 'spot_pair': 'ETHUSDC'},  # ETH/USD

Bid/ask are composed conservatively (cross bid hits the quote leg's ask and
vice versa) so both legs' spreads compound into the reported spread. The
oracle timestamp is the older of the two legs', so the on-chain staleness fee
protects against the weakest leg.
"""

import decimal as dec

D = dec.Decimal


def _sources():
    # Imported lazily to avoid a circular import at package-init time.
    from . import PRICE_SOURCES
    return PRICE_SOURCES


def _leg_source(leg, which):
    sources = _sources()
    name = leg.get('price_source')
    if name not in sources:
        raise RuntimeError(f"{which}: unknown price_source {name!r}; available: {', '.join(sources.keys())}")
    return sources[name]


def check_env(pair):
    """Recursively validate both legs' sources and env requirements."""
    for which in ('base_leg', 'quote_leg'):
        leg = pair.get(which)
        if not isinstance(leg, dict):
            raise RuntimeError(f"cross pair needs a {which!r} leg config")
        _leg_source(leg, which).check_env(leg)


def _leg_top_of_book(leg, which):
    bid, ask, ts = _leg_source(leg, which).get_top_of_book(leg)
    if leg.get('invert'):
        bid, ask = D(1) / ask, D(1) / bid
    return bid, ask, ts


def get_top_of_book(pair):
    """Return (best_bid_d, best_ask_d, oracle_ts) for base/quote via two legs."""
    base_bid, base_ask, base_ts = _leg_top_of_book(pair['base_leg'], 'base_leg')
    quote_bid, quote_ask, quote_ts = _leg_top_of_book(pair['quote_leg'], 'quote_leg')
    # Conservative composition: buying the base means selling the quote leg at
    # its bid, and vice versa — both legs' spreads compound.
    best_bid_d = base_bid / quote_ask
    best_ask_d = base_ask / quote_bid
    return best_bid_d, best_ask_d, min(base_ts, quote_ts)
