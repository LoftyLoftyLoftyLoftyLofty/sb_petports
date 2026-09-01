#!/usr/bin/env python3
"""Replay the arrival brake, old gate vs new, over every firing in the log.

CONTROL, NOT ARGUMENT. The new predicate has to do two things and both are
checkable against measurements already taken: fire on the arrivals the brake
was built for, and decline the three that dropped a unit on a lip. Reasoning
about it in prose was how the old gate survived a triage pass.

Rows are read straight out of starbound.log's ARCMOVER lines, plus the launch
case the original brake was written against, which predates this log.
"""

import re
import sys

LAND_BRAKE_ARRIVED = 0.05
LAND_BRAKE_OVERRUN = 1.5
LAND_BRAKE_STATIONARY = 0.1
LAND_BRAKE_CEILING = 1.0
LAND_BRAKE_REACH = 0.5  # the retired one, replayed for comparison


def old_gate(here, landing, vel):
	return (abs(here[0] - landing[0]) <= LAND_BRAKE_REACH
	        and here[1] <= landing[1] + LAND_BRAKE_CEILING
	        and vel[1] < 0)


def new_gate(here, landing, vel):
	if abs(vel[0]) < LAND_BRAKE_STATIONARY:
		ahead = 0.0
	else:
		ahead = (landing[0] - here[0]) * (1 if vel[0] > 0 else -1)
	return (ahead <= LAND_BRAKE_ARRIVED
	        and ahead >= -LAND_BRAKE_OVERRUN
	        and here[1] <= landing[1] + LAND_BRAKE_CEILING
	        and vel[1] < 0), ahead


#  what, here, landing, vel, should_fire
CASES = [
	("23:50 ledge fall, dropped on the lip at 2536",
	 (2535.59, 1150.56), (2536, 1149.8), (7.2, -20.0), False),
	("24:22 pool exit, perched on the lip at 2523",
	 (2523.40, 1160.80), (2523, 1160.8), (-10.8, -21.2), False),
	("24:51 pool exit, same to the decimal",
	 (2523.40, 1160.80), (2523, 1160.8), (-10.8, -21.2), False),
	("24:10 good arrival, dead on the landing",
	 (2531.00, 1152.80), (2531, 1152.8), (-12.0, -18.8), True),
	("the five-lap slide-off the brake was built for",
	 (2493.00, 1155.80), (2493, 1155.8), (8.0, -25.0), True),
	("overshot half a tile past, still descending",
	 (2493.50, 1155.60), (2493, 1155.8), (8.0, -25.0), True),
	("overshot a whole tile past on a fast arc",
	 (2494.00, 1155.40), (2493, 1155.8), (8.0, -25.0), True),
	("overshot far past -- the arc failed, not the last tenth",
	 (2496.00, 1155.40), (2493, 1155.8), (8.0, -25.0), False),
	("passing over five tiles up on the way somewhere else",
	 (2493.00, 1160.80), (2493, 1155.8), (8.0, -25.0), False),
	("rising out of a launch, landing dead ahead",
	 (2528.00, 1158.80), (2523, 1160.8), (-12.0, 28.8), False),
	("motionless above the landing, landing to the RIGHT",
	 (2492.60, 1155.90), (2493, 1155.8), (0.0, -1.5353), True),
]

fails = []
print(f"{'':2} {'ahead':>7}  {'old':>5} {'new':>5}  case")
for what, here, landing, vel, want in CASES:
	old = old_gate(here, landing, vel)
	new, ahead = new_gate(here, landing, vel)
	mark = "ok" if new == want else "!!"
	if new != want:
		fails.append(f"{what}: fired={new}, expected {want}")
	print(f"{mark:2} {ahead:7.2f}  {str(old):>5} {str(new):>5}  {what}")

print()
#  The point of the change, stated as an assertion rather than a claim.
regressions = [w for w, h, l, v, want in CASES
               if want and old_gate(h, l, v) and not new_gate(h, l, v)[0]]
if regressions:
	fails.append("the new gate DROPPED an arrival the old one caught: "
	             + "; ".join(regressions))

fixed = [w for w, h, l, v, want in CASES
         if not want and old_gate(h, l, v) and not new_gate(h, l, v)[0]]
print(f"declines the old gate got wrong: {len(fixed)}")
for w in fixed:
	print("   " + w)

if fails:
	print()
	for f in fails:
		print("FAIL  " + f)
	sys.exit(1)
print("\nbrake predicate holds on every replayed case")
