#!/usr/bin/env python3
"""Shape assertions for the Swim -> Jump handover fix.

Every check below reads CODE, never a comment. Comment text is stripped first,
because the failure mode this is guarding against is a half-applied edit whose
comments describe the finished state.
"""

import re
import sys

ROOT = "/home/claude/pp/lofty_petports/monsters/lofty_petports/"
TASK = ROOT + "petportsTaskAction.lua"
FLY = ROOT + "petports_flyapproach.lua"


def code(path):
	src = open(path, encoding="utf-8").read()
	src = re.sub(r"--\[\[.*?\]\]", "", src, flags=re.S)
	src = re.sub(r"--[^\n]*", "", src)
	return src


task, fly = code(TASK), code(FLY)
fails = []


def want(label, got, expect):
	if got != expect:
		fails.append(f"{label}: got {got}, expected {expect}")
	else:
		print(f"  ok   {label}  ({got})")


#  1: the two shared constants are context-globals, declared exactly once, and
#     no `local` declaration of either survives anywhere in the tree.
for name in ("JUMP_APPROACH_SLOWDOWN", "JUMP_APPROACH_SPEED"):
	want(f"{name} declared non-local in taskAction",
	     len(re.findall(rf"^{name}\s*=", task, re.M)), 1)
	want(f"{name} has no surviving local declaration",
	     len(re.findall(rf"\blocal\s+{name}\b", task + fly)), 0)

#  2: and the swim mover actually reads both of them.
want("flyapproach reads JUMP_APPROACH_SLOWDOWN",
     len(re.findall(r"\bJUMP_APPROACH_SLOWDOWN\b", fly)), 1)
want("flyapproach reads JUMP_APPROACH_SPEED",
     len(re.findall(r"\bJUMP_APPROACH_SPEED\b", fly)), 2)

#  3: the chase bound is declared once and read once.
want("JUMP_SWIM_CHASE declared local once",
     len(re.findall(r"\blocal\s+JUMP_SWIM_CHASE\s*=", task)), 1)
want("JUMP_SWIM_CHASE read once",
     len(re.findall(r"\bJUMP_SWIM_CHASE\b", task)) - 1, 1)

#  4: the swim arm is an elseif on the SAME branch as the walk arm, not a
#     second independent if that could run alongside it.
want("swim arm is an elseif on the out-of-radius branch",
     len(re.findall(r"elseif\s+mcontroller\.baseParameters\(\)\.gravityEnabled\s*\n"
                    r"\s*and gap <= JUMP_SWIM_CHASE then", task)), 1)

#  5: the arm accepts a straddled waterline, which is the measured case.
want("swim arm accepts both swim and mixed",
     len(re.findall(r'medium == "swim" or medium == "mixed"', task)), 1)

#  6: it issues thrust. A branch that logs and returns is the bug, not the fix.
want("swim arm issues controlApproachVelocity",
     len(re.findall(r"mcontroller\.controlApproachVelocity\(\s*\n?\s*\{ delta\[1\] / length \* JUMP_APPROACH_SPEED",
                    task)), 1)

#  7: the change-gate flag is both set and cleared. A gate that is never
#     cleared logs once per unit lifetime instead of once per event.
want("petportsSwimmingToJump set", len(re.findall(
	r"pather\.petportsSwimmingToJump = true", task)), 1)
want("petportsSwimmingToJump cleared", len(re.findall(
	r"pather\.petportsSwimmingToJump = nil", task)), 1)
want("cleared beside the walk flag, on the takeoff path", len(re.findall(
	r"pather\.petportsWalkingToJump = nil\s*\n\s*pather\.petportsSwimmingToJump = nil",
	task)), 1)

#  8: the brake is wired in. The old bare walkSpeed read must be GONE, not
#     merely joined by a new one -- a leftover would make the brake dead code.
want("no bare walkSpeed read left in the swim actuation",
     len(re.findall(r"local speed = mcontroller\.baseParameters\(\)\.walkSpeed", fly)), 0)
want("swim actuation routes speed through the brake",
     len(re.findall(r"local speed = swimApproachSpeed\(pather,", fly)), 1)

#  9: local function defined ABOVE its call site -- otherwise it is a nil
#     global at call time, which this mod has shipped before.
defn = fly.find("local function swimApproachSpeed")
call = fly.find("swimApproachSpeed(pather,")
want("swimApproachSpeed defined before it is called", defn != -1 and defn < call, True)

# 10: the brake can only slow, never speed a chassis up.
want("brake clamps with math.min",
     len(re.findall(r"return math\.min\(base, JUMP_APPROACH_SPEED\)", fly)), 1)

# 11: both files still carry a stamp, and both moved.
want("taskAction stamp bumped", len(re.findall(
	r'BUILD_STAMP = "2026-09-01f a swimmer can walk back too"', task)), 1)
want("flyapproach stamp bumped", len(re.findall(
	r'BUILD_STAMP = "2026-09-01a the swim run-in brakes for a jump"', fly)), 1)

print()
if fails:
	for f in fails:
		print("FAIL  " + f)
	sys.exit(1)
print("all shape assertions hold")
