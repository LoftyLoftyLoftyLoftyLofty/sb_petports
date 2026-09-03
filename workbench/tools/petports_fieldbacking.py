#  PETPORTS -- FIELD BACKING GENERATOR
#
#  THE RECIPE IS READ OFF THE EXISTING ART, NOT INVENTED.
#
#  restockconfig/field_backing.png and petportconfig/namefield_backing.png are
#  both 12 tall and pixel-identical in construction; only their widths differ.
#  A third backing hand-drawn to look "about the same" would drift the first
#  time one of them is retouched, so this states the construction once.
#
#  THE CONSTRUCTION, sampled 2026-09-03:
#
#      1px outer frame          (24, 26, 30, 255)   opaque
#      inner left column        (90, 96, 104, 255)  the sunken bevel
#      inner bottom row         (90, 96, 104, 255)  same
#      everything else          (28, 30, 34, 210)   translucent fill
#
#  The bevel is on the LEFT and BOTTOM only -- top and right get no highlight --
#  which is what makes the field read as pressed into the panel rather than
#  raised off it.
#
#  Run from the mod root:  python3 workbench/tools/petports_fieldbacking.py

from PIL import Image

FRAME = (24, 26, 30, 255)
BEVEL = (90, 96, 104, 255)
FILL = (28, 30, 34, 210)

HEIGHT = 12


def backing(width, height=HEIGHT):
	im = Image.new("RGBA", (width, height), FILL)
	px = im.load()

	for x in range(width):
		px[x, 0] = FRAME
		px[x, height - 1] = FRAME
		px[x, height - 2] = BEVEL

	for y in range(height):
		px[0, y] = FRAME
		px[width - 1, y] = FRAME

	for y in range(1, height - 1):
		px[1, y] = BEVEL

	#  The corner where the two bevel runs meet belongs to the bevel, and the
	#  frame is reasserted after so the outer edge is never broken by it.
	px[0, height - 1] = FRAME
	px[width - 1, height - 1] = FRAME

	return im


if __name__ == "__main__":
	#  26 WIDE AGAINST A 24 maxWidth FIELD, so the frame sits one pixel outside
	#  the text on each side and the digits never touch it.
	out = "interface/lofty_petports/petportconfig/colorfield_backing.png"
	backing(26).save(out)
	print("wrote %s" % out)
