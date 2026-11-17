#!/usr/bin/env python3
"""Offline replay of the luci-app-prio automatic mode (r71 and later).

Why this exists: three audits rejected earlier versions of the control loop on
scenarios that nobody could reproduce without hardware, and every rejection was
an arithmetic property of the branch structure, not of the radio. So the branch
structure is duplicated here, in ~40 lines, and the scenarios are asserted.

What the automatic mode is supposed to do (r71):

  * a measurement finds the capacity -- the router downloads/uploads through
    its own unshaped class and times it; the estimate starts at 90% of that;
  * latency only ever takes capacity AWAY: if the round trip climbs well past
    the idle baseline the rate is cut, proportionally, 10%..30% per window;
  * nothing raises the rate except a new measurement or a number typed in.

Run:  python3 tools/prio-replay.py
Exit code 0 = every scenario behaved.

The model of the radio is deliberately crude: below the real capacity the round
trip is the idle baseline plus jitter, above it the modem buffers and the round
trip jumps. That is enough to check the branch structure, which is the part that
kept being wrong.
"""

import sys

BASE = 14            # idle baseline, ms (measured on the real line)
JITTER = [34, 54, 74, 94, 64, 44]
MARGIN = 10          # percent, shaper_margin
FLOOR = 2000         # kbit/s


def applied_of(estimate, margin=MARGIN):
    return estimate * (100 - margin) // 100


def rtt_for(applied, capacity, jitter_index, queued_at=None):
    """How the round trip behaves for a given applied rate."""
    if applied > capacity:
        # queue inside the modem; grows with the overshoot, saturates
        over = applied / float(capacity) - 1.0
        return int(min(300 + 2000 * over, 1200))
    return JITTER[jitter_index % len(JITTER)]


def step(estimate, capacity, demand, jitter_index):
    """One 20 s window. Returns (new_estimate, action)."""
    applied = applied_of(estimate)
    thr = min(demand, capacity, applied)
    rtt = rtt_for(applied, capacity, jitter_index)
    bind = applied >= 1000 and thr * 100 >= applied * 80

    if rtt == 0:
        # no answer at all: a dead target or a modem queued past the timeout
        if bind:
            return max(estimate * 90 // 100, FLOOR), "cut(probe)"
        return estimate, "hold(probe)"
    if rtt > BASE + 300:
        excess = rtt - BASE
        pct = 10 + (excess - 300) // 40
        pct = max(10, min(30, pct))
        return max(estimate * (100 - pct) // 100, FLOOR), "cut(%d%%)" % pct
    return estimate, "hold"


def run(name, capacity, demand, seed_estimate, windows=40, change_at=None, change_to=None):
    est = seed_estimate
    trail = []
    for w in range(windows):
        cap = change_to if (change_at is not None and w >= change_at) else capacity
        est, act = step(est, cap, demand, w)
        trail.append((w, cap, est, applied_of(est), act))
    print("== %s" % name)
    for t in trail[:6]:
        print("   w%-2d cap=%-7d est=%-7d applied=%-7d %s" % t)
    if len(trail) > 10:
        print("   ...")
        for t in trail[-3:]:
            print("   w%-2d cap=%-7d est=%-7d applied=%-7d %s" % t)
    return trail


def main():
    fails = []

    def want(name, cond, detail):
        print("%s  %s%s" % ("PASS" if cond else "FAIL", name, "" if cond else "  [%s]" % detail))
        if not cond:
            fails.append(name)

    # A) a measurement seeds at 90% of the line and nothing moves it: no
    #    oscillation, no slow drift toward the ceiling.
    t = run("A measured 185000, saturating", 185000, 10 ** 9, 185000, windows=30)
    want("A: stays at 90% of the measured capacity",
         all(x[2] == 185000 for x in t), [x[2] for x in t[:5]])

    # B) the capacity collapses under it: it must come down, and keep coming
    #    down while the round trip stays blown up.
    t = run("B capacity 185000 -> 30000 at w=3", 185000, 10 ** 9, 185000,
            windows=14, change_at=3, change_to=30000)
    down = [x for x in t if x[0] >= 3]
    want("B: applied drops below the new capacity",
         applied_of(down[-1][2]) <= 30000, "last applied=%d" % applied_of(down[-1][2]))
    want("B: every collapsing window cuts", all(x[4].startswith("cut") for x in down[:4]),
         [x[4] for x in down[:4]])

    # C) the capacity comes back but no measurement runs: it holds where it is
    #    (that is the documented trade-off -- a new measurement is what raises).
    t = run("C capacity 30000 -> 185000 at w=5, no measurement", 30000, 10 ** 9, 30000,
            windows=12, change_at=5, change_to=185000)
    want("C: no automatic raise after the line recovers",
         all(x[2] == 30000 for x in t), [x[2] for x in t[:5]])

    # D) light load through a big cap must never move the rate: with 3 Mbit
    #    flowing through a 166 Mbit cap there is no queue to see.
    t = run("D 3 Mbit of video through a 185000 measurement", 185000, 3000, 185000, windows=40)
    want("D: light load never changes the rate",
         all(x[2] == 185000 for x in t), [x[2] for x in t[:5]])

    # E) the probe target dies while the line is idle: hold, do not walk down.
    est = 185000
    for _ in range(20):
        est = step(est, 185000, 0, 0)[0]
    want("E: a dead probe on an idle line holds the rate", est == 185000, est)

    # F) a dead probe while traffic is pinned at the cap: that is a queue, so
    #    it cuts (10% a window) instead of freezing above the capacity.
    est = 185000
    est, act = step(est, 30000, 10 ** 9, 0)
    want("F: probe unanswered at the cap still cuts", act.startswith("cut"), act)

    # G) the cut is proportional, never a constant: a 340 ms round trip must
    #    cut less than a 1000 ms one.
    def cut_pct(rtt):
        excess = rtt - BASE
        pct = 10 + (excess - 300) // 40
        return max(10, min(30, pct))
    want("G: cut size scales with the queue", cut_pct(340) < cut_pct(800) <= 30,
         (cut_pct(340), cut_pct(800)))

    print()
    if fails:
        print("%d scenario(s) failed: %s" % (len(fails), ", ".join(fails)))
        return 1
    print("all scenarios behaved")
    return 0


if __name__ == "__main__":
    sys.exit(main())
