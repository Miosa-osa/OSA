"""Interval estimates for benchmark proportions. Standard library only.

A benchmark result is a sample proportion: k tasks resolved out of n attempted.
Reporting it as a bare percentage throws away the single most important fact
about it -- how much of the number is sampling noise. On the subset sizes we
can actually afford to run, that is most of it.

Everything here is deliberately conservative:

  * Wilson score interval is the default. It behaves sanely at k=0 and k=n,
    where the textbook normal approximation produces intervals that extend
    past 0 or 1, and it has better coverage than the normal approximation at
    small n. (Brown, Cai & DasGupta 2001, "Interval Estimation for a Binomial
    Proportion", Statistical Science 16(2):101-133.)

  * Clopper-Pearson is offered for the paranoid. It is the exact interval:
    guaranteed at-least-nominal coverage, at the price of being wider than it
    needs to be. If a claim survives Clopper-Pearson it survives anything.

  * The normal ("Wald") interval is implemented only so that
    `test_stats.py` can demonstrate why we do not use it.

Nothing here knows what a benchmark is. It takes k and n.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from statistics import NormalDist

__all__ = [
    "Interval",
    "wilson",
    "clopper_pearson",
    "wald",
    "interval",
    "rule_of_three",
    "min_n_for_halfwidth",
    "two_proportion",
]


@dataclass(frozen=True)
class Interval:
    """A confidence interval on a proportion, in the unit range."""

    point: float
    low: float
    high: float
    confidence: float
    method: str
    k: int
    n: int

    @property
    def halfwidth(self) -> float:
        """Half the width, in proportion units. The +/- you would quote."""
        return (self.high - self.low) / 2.0

    @property
    def width_pp(self) -> float:
        """Full width in percentage points -- the honest 'how big is the fog'."""
        return (self.high - self.low) * 100.0

    def pct(self) -> str:
        return f"{self.point * 100:.1f}%"

    def pct_range(self) -> str:
        return f"{self.low * 100:.1f}%-{self.high * 100:.1f}%"

    def describe(self) -> str:
        """The form we always print: never the point estimate on its own."""
        return (
            f"{self.k}/{self.n} = {self.pct()} "
            f"({int(self.confidence * 100)}% CI {self.pct_range()}, "
            f"{self.method})"
        )

    def to_json(self) -> dict:
        return {
            "k": self.k,
            "n": self.n,
            "point": round(self.point, 6),
            "low": round(self.low, 6),
            "high": round(self.high, 6),
            "width_pp": round(self.width_pp, 2),
            "confidence": self.confidence,
            "method": self.method,
        }


def _z(confidence: float) -> float:
    if not 0.0 < confidence < 1.0:
        raise ValueError(f"confidence must be in (0,1), got {confidence}")
    return NormalDist().inv_cdf(1.0 - (1.0 - confidence) / 2.0)


def _check(k: int, n: int) -> None:
    if n < 0 or k < 0:
        raise ValueError(f"k and n must be non-negative, got k={k} n={n}")
    if k > n:
        raise ValueError(f"k must not exceed n, got k={k} n={n}")


def wilson(k: int, n: int, confidence: float = 0.95) -> Interval:
    """Wilson score interval. The default; use this unless you have a reason."""
    _check(k, n)
    if n == 0:
        return Interval(float("nan"), 0.0, 1.0, confidence, "wilson", k, n)
    z = _z(confidence)
    p = k / n
    denom = 1.0 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    margin = (z / denom) * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    # The Wilson interval provably contains p; the clamps against p only
    # absorb floating-point noise, which at k=0 otherwise yields a lower bound
    # of 2.8e-17 sitting above a point estimate of exactly 0.
    return Interval(
        point=p,
        low=min(max(0.0, centre - margin), p),
        high=max(min(1.0, centre + margin), p),
        confidence=confidence,
        method="wilson",
        k=k,
        n=n,
    )


def _binom_sf_ge(k: int, n: int, p: float) -> float:
    """P(X >= k) for X ~ Binomial(n, p)."""
    if k <= 0:
        return 1.0
    if k > n:
        return 0.0
    return sum(math.comb(n, i) * p**i * (1 - p) ** (n - i) for i in range(k, n + 1))


def _binom_cdf_le(k: int, n: int, p: float) -> float:
    """P(X <= k) for X ~ Binomial(n, p)."""
    if k >= n:
        return 1.0
    if k < 0:
        return 0.0
    return sum(math.comb(n, i) * p**i * (1 - p) ** (n - i) for i in range(0, k + 1))


def _bisect(fn, target: float, lo: float, hi: float, tol: float = 1e-10) -> float:
    """Solve fn(x) == target on [lo, hi] for a monotone fn."""
    for _ in range(200):
        mid = (lo + hi) / 2.0
        if hi - lo < tol:
            return mid
        if (fn(mid) - target) > 0:
            hi = mid
        else:
            lo = mid
    return (lo + hi) / 2.0


def clopper_pearson(k: int, n: int, confidence: float = 0.95) -> Interval:
    """Exact (conservative) interval. Slower; n <= a few thousand is fine."""
    _check(k, n)
    if n == 0:
        return Interval(float("nan"), 0.0, 1.0, confidence, "clopper-pearson", k, n)
    alpha = 1.0 - confidence
    # Lower bound: largest p with P(X >= k | p) <= alpha/2.
    low = 0.0 if k == 0 else _bisect(lambda p: _binom_sf_ge(k, n, p), alpha / 2, 0.0, 1.0)
    # Upper bound: smallest p with P(X <= k | p) <= alpha/2.
    high = (
        1.0
        if k == n
        else _bisect(lambda p: -_binom_cdf_le(k, n, p), -alpha / 2, 0.0, 1.0)
    )
    return Interval(
        point=k / n,
        low=max(0.0, min(low, k / n)),
        high=min(1.0, max(high, k / n)),
        confidence=confidence,
        method="clopper-pearson",
        k=k,
        n=n,
    )


def wald(k: int, n: int, confidence: float = 0.95) -> Interval:
    """Normal approximation. Present as a counter-example -- do not report it.

    At k=0 or k=n it returns a zero-width interval, which is how a 0/10 run
    gets presented as "0%, no uncertainty". That failure mode is exactly why
    `interval()` never dispatches here.
    """
    _check(k, n)
    if n == 0:
        return Interval(float("nan"), 0.0, 1.0, confidence, "wald", k, n)
    p = k / n
    m = _z(confidence) * math.sqrt(p * (1 - p) / n)
    return Interval(p, max(0.0, p - m), min(1.0, p + m), confidence, "wald", k, n)


_METHODS = {"wilson": wilson, "clopper-pearson": clopper_pearson}


def interval(k: int, n: int, confidence: float = 0.95, method: str = "wilson") -> Interval:
    """Dispatch by name. `wald` is intentionally unreachable from here."""
    try:
        return _METHODS[method](k, n, confidence)
    except KeyError:
        raise ValueError(
            f"unknown method {method!r}; choose from {sorted(_METHODS)}"
        ) from None


def rule_of_three(n: int, confidence: float = 0.95) -> float:
    """Upper bound on the true rate after observing zero successes in n trials.

    3/n at 95%. The point: 0/20 does not mean "cannot do it", it means the
    true rate is somewhere under ~14%.
    """
    if n <= 0:
        return 1.0
    return min(1.0, -math.log(1.0 - confidence) / n)


def min_n_for_halfwidth(halfwidth_pp: float, p: float = 0.5, confidence: float = 0.95) -> int:
    """How many tasks you need for a +/- halfwidth_pp result at rate p.

    Uses the normal approximation, which *understates* the requirement, so
    treat the answer as a floor. p=0.5 is the worst case and the default.
    """
    if halfwidth_pp <= 0:
        raise ValueError("halfwidth_pp must be positive")
    h = halfwidth_pp / 100.0
    z = _z(confidence)
    return math.ceil((z * z * p * (1 - p)) / (h * h))


def two_proportion(
    k1: int, n1: int, k2: int, n2: int, confidence: float = 0.95
) -> dict:
    """Is run 1 actually different from run 2?

    Newcombe's method 10: build a Wilson interval for each proportion and
    combine them. Handles small n and extreme proportions, where the pooled
    z-test misbehaves. (Newcombe 1998, Statistics in Medicine 17:873-890.)

    `significant` is True only when the interval for the difference excludes
    zero. Two runs whose intervals overlap are, on this evidence, the same run.
    """
    if n1 == 0 or n2 == 0:
        return {
            "diff": None,
            "low": None,
            "high": None,
            "significant": False,
            "note": "one of the runs is empty; no comparison possible",
        }
    a = wilson(k1, n1, confidence)
    b = wilson(k2, n2, confidence)
    p1, p2 = k1 / n1, k2 / n2
    diff = p1 - p2
    low = diff - math.sqrt((p1 - a.low) ** 2 + (b.high - p2) ** 2)
    high = diff + math.sqrt((a.high - p1) ** 2 + (p2 - b.low) ** 2)
    low, high = max(-1.0, low), min(1.0, high)
    return {
        "diff": round(diff, 6),
        "diff_pp": round(diff * 100, 2),
        "low": round(low, 6),
        "high": round(high, 6),
        "confidence": confidence,
        "method": "newcombe",
        "significant": low > 0.0 or high < 0.0,
        "note": (
            "difference is distinguishable from zero"
            if (low > 0.0 or high < 0.0)
            else "difference is NOT distinguishable from sampling noise"
        ),
    }
