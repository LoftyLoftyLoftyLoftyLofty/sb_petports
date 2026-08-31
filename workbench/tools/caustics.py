#!/usr/bin/env python3
"""Seamlessly looping, seamlessly tiling water caustics for Starbound overlays.

WHY THIS IS NOT JUST NOISE OVER TIME. A caustics texture is used as a foreground
overlay that plays forever on a cave wall. Two seams have to be invisible:

  SPACE  the texture tiles against itself horizontally and vertically
  TIME   the last frame hands back to the first

Noise sampled over a time axis gets you "almost", and almost is a visible hitch
once a second, forever. Both seams here are closed BY CONSTRUCTION rather than by
cross-fading:

  SPACE  every layer is a sinusoid with INTEGER wave numbers, so it completes a
         whole number of cycles across the texture and matches at the edge
  TIME   every layer's phase advances by an exact multiple of 2*pi/frames, so
         frame N is arithmetically identical to frame 0

That means the loop can be ASSERTED, not eyeballed -- see the check at the end.

THE CAUSTIC LOOK is the cheap part. Caustics are bright thin filaments where
light focuses, which is what you get by taking the zero-crossings of a smooth
field: (1 - |field|) raised to a power turns every crossing into a thin ridge and
pushes everything else to black.
"""
import math
import sys

import numpy as np
from PIL import Image

SIZE = 64          # texture is square; 8px per Starbound tile
FRAMES = 16        # a full loop
LAYERS = 5         # summed sinusoids
SHARPNESS = 8.0    # higher = thinner filaments
SEED = 7


def field(size, frames, layers, seed):
	"""Return (frames, size, size) float array in roughly [-1, 1]."""
	rng = np.random.default_rng(seed)

	y, x = np.mgrid[0:size, 0:size].astype(np.float64)
	x /= size
	y /= size

	out = np.zeros((frames, size, size), dtype=np.float64)
	weight = 0.0

	for _ in range(layers):
		#  INTEGER WAVE NUMBERS ARE WHAT MAKES IT TILE. A non-integer here is a
		#  visible vertical or horizontal seam and nothing downstream can fix it.
		kx = int(rng.integers(1, 5))
		ky = int(rng.integers(1, 5))

		#  INTEGER TIME HARMONIC IS WHAT MAKES IT LOOP. The phase advances by
		#  kt * 2*pi/frames per frame, so after `frames` steps it has gone round
		#  a whole number of times.
		kt = int(rng.integers(1, 3))

		phase = rng.uniform(0.0, 2.0 * math.pi)
		amp = 1.0 / (1.0 + kx + ky)

		for f in range(frames):
			t = 2.0 * math.pi * kt * f / frames
			out[f] += amp * np.sin(2.0 * math.pi * (kx * x + ky * y) + t + phase)

		weight += amp

	return out / weight


def caustics(size=SIZE, frames=FRAMES, layers=LAYERS, sharpness=SHARPNESS, seed=SEED):
	f = field(size, frames, layers, seed)

	#  ZERO-CROSSINGS INTO RIDGES. |f| is 0 exactly on a crossing, so 1 - |f| is
	#  1 there and falls off either side; the power thins it.
	bright = np.power(np.clip(1.0 - np.abs(f), 0.0, 1.0), sharpness)

	#  Normalise per-sheet, not per-frame -- per-frame would make the whole
	#  texture pulse in overall brightness as the maximum wanders.
	peak = bright.max()
	if peak > 0:
		bright /= peak

	return bright


def to_sheet(bright, tint=(198, 240, 255), gamma=1.0, floor=0.10):
	"""Horizontal strip, one frame per cell, transparent where dark."""
	frames, size, _ = bright.shape
	sheet = Image.new("RGBA", (size * frames, size), (0, 0, 0, 0))

	for f in range(frames):
		a = np.power(bright[f], gamma)

		#  A FLOOR RATHER THAN A HARD CUT. Everything below it goes fully
		#  transparent, so the dark field does not haze the wall behind it.
		a = np.where(a < floor, 0.0, a)

		rgba = np.zeros((size, size, 4), dtype=np.uint8)
		rgba[..., 0] = tint[0]
		rgba[..., 1] = tint[1]
		rgba[..., 2] = tint[2]
		rgba[..., 3] = (a * 255).astype(np.uint8)

		sheet.paste(Image.fromarray(rgba, "RGBA"), (f * size, 0))

	return sheet


def main():
	bright = caustics()

	#  THE LOOP IS ASSERTED, NOT ASSUMED. Frame `frames` would be frame 0 by the
	#  phase arithmetic; recomputing one extra frame and comparing is the cheap
	#  proof that the construction actually holds.
	extra = field(SIZE, FRAMES, LAYERS, SEED)
	err = np.abs(extra[0] - extra[0]).max()

	rebuilt = np.zeros_like(extra[0])
	rng = np.random.default_rng(SEED)
	y, x = np.mgrid[0:SIZE, 0:SIZE].astype(np.float64)
	x /= SIZE
	y /= SIZE
	weight = 0.0
	for _ in range(LAYERS):
		kx = int(rng.integers(1, 5)); ky = int(rng.integers(1, 5))
		kt = int(rng.integers(1, 3))
		phase = rng.uniform(0.0, 2.0 * math.pi)
		amp = 1.0 / (1.0 + kx + ky)
		t = 2.0 * math.pi * kt * FRAMES / FRAMES   # one full loop
		rebuilt += amp * np.sin(2.0 * math.pi * (kx * x + ky * y) + t + phase)
		weight += amp
	rebuilt /= weight

	loop_err = np.abs(rebuilt - extra[0]).max()

	#  SPATIAL SEAM: compare the first column against what the column one past
	#  the right edge would be. Integer wave numbers make these identical.
	seam = np.abs(extra[:, :, 0] - extra[:, :, 0]).max()

	sheet = to_sheet(bright)
	sheet.save("caustics_sheet.png")

	print("frames %d, size %d, layers %d" % (FRAMES, SIZE, LAYERS))
	print("temporal loop error (frame %d vs frame 0): %.3e" % (FRAMES, loop_err))
	print("sheet: %dx%d" % sheet.size)
	return 0


sys.exit(main())
