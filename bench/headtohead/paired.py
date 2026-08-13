"""Paired statistics for a same-tasks head-to-head. Standard library only.

Two arms run over the SAME task list are not two independent samples; they are
one sample measured twice. Comparing them with an unpaired two-proportion
interval (which is what `bench/report/stats.two_proportion` gives) throws away
the pairing and is badly under-powered at the n we can afford.

The paired test is McNemar's, computed exactly (binomial, not chi-squared --
the chi-squared approximation is not valid at these counts). It looks only at
the DISCORDANT pairs:

    b = tasks arm A solved and arm B did not
    c = tasks arm B solved and arm A did not

Tasks both arms solved, and tasks neither solved, carry no information about
which arm is better and are correctly ignored. That is also why n=5-8 is so
weak here: with 6 tasks you might have b+c = 2, and 2 discordant pairs cannot
distinguish anything from a coin flip (the smallest attainable two-sided exact
p-value at b+c=2 is 0.5).

`min_discordant_for_significance` exists to make that concrete in the report
instead of leaving the reader to discover it.
"""

from __future__ import annotations

import math
from dataclasses import dataclass


def _binom_pmf(k: int, n: int, p: float = 0.5) -> float:
    return math.comb(n, k) * (p ** k) * ((1 - p) ** (n - k))


def mcnemar_exact(b: int, c: int) -> dict:
    """Exact two-sided McNemar test on discordant counts b and c.

    Under H0 (the arms are equally likely to win a discordant pair), b ~
    Binomial(b + c, 0.5). The two-sided p-value sums every outcome at least as
    extreme as the one observed.
    """
    n = b + c
    if n == 0:
        return {
            "b": b, "c": c, "n_discordant": 0, "p_value": 1.0,
            "significant": False,
            "note": ("no discordant pairs: the arms agreed on every task, so "
                     "this data cannot separate them at all"),
        }
    observed = _binom_pmf(min(b, c), n)
    # Numerical slack so that outcomes with mathematically equal probability
    # are not dropped by float comparison.
    p = sum(_binom_pmf(k, n) for k in range(n + 1)
            if _binom_pmf(k, n) <= observed * (1 + 1e-9))
    p = min(1.0, p)
    return {
        "b": b, "c": c, "n_discordant": n,
        "p_value": round(p, 6),
        "significant": p < 0.05,
        "note": ("difference survives an exact paired test"
                 if p < 0.05 else
                 f"NOT significant: with {n} discordant pair(s) the smallest "
                 f"attainable two-sided p-value is "
                 f"{round(2 * _binom_pmf(0, n), 4)}"),
    }


def min_discordant_for_significance(alpha: float = 0.05) -> int:
    """Smallest b+c at which a two-sided exact McNemar test CAN reach alpha.

    An all-or-nothing split (b=0) is the most extreme outcome possible, so its
    p-value, 2 * 0.5**n, is the floor. Below the n this returns, no observed
    result whatsoever is significant -- which is a fact about the experiment
    design, not about the arms.
    """
    n = 1
    while 2 * (0.5 ** n) >= alpha:
        n += 1
        if n > 64:
            break
    return n


@dataclass(frozen=True)
class PairedComparison:
    arm_a: str
    arm_b: str
    both_solved: int
    a_only: int
    b_only: int
    neither: int
    n_paired: int
    test: dict

    def to_json(self) -> dict:
        return {
            "arm_a": self.arm_a,
            "arm_b": self.arm_b,
            "both_solved": self.both_solved,
            "a_only": self.a_only,
            "b_only": self.b_only,
            "neither_solved": self.neither,
            "n_paired": self.n_paired,
            "mcnemar_exact": self.test,
        }


def compare(arm_a: str, rows_a: dict, arm_b: str, rows_b: dict) -> PairedComparison:
    """Pair two arms on the tasks BOTH attempted.

    `rows_a` / `rows_b` map task name -> row dict. Tasks only one arm ran are
    dropped rather than counted as a loss for the other: an arm that never got
    a task is not an arm that failed it.
    """
    shared = sorted(set(rows_a) & set(rows_b))
    both = a_only = b_only = neither = 0
    for t in shared:
        ra = bool(rows_a[t]["resolved"])
        rb = bool(rows_b[t]["resolved"])
        if ra and rb:
            both += 1
        elif ra:
            a_only += 1
        elif rb:
            b_only += 1
        else:
            neither += 1
    return PairedComparison(
        arm_a=arm_a, arm_b=arm_b,
        both_solved=both, a_only=a_only, b_only=b_only, neither=neither,
        n_paired=len(shared),
        test=mcnemar_exact(a_only, b_only),
    )
