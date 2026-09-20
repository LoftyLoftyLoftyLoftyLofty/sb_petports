#!/usr/bin/env python3
# Builds the example add-on exactly the way a modder would: copy three files, find-replace one word, fix three lines.
import os, json, shutil

SRC = "lofty_petports/"
OUT = "lofty_petports_example_copper/"
NAME = "lofty_petports_example_copper"
WORD_OLD, WORD_NEW = "asterite", "copper"

FILES = {
	"scripts/lofty_petports/shared/asterite.lua": "scripts/%s/shared/copper.lua" % NAME,
	"objects/lofty_petports/petport/work/asterite.lua": "scripts/%s/work/copper.lua" % NAME,
	"monsters/lofty_petports/tasks/asterite.lua": "scripts/%s/tasks/copper.lua" % NAME,
}

# The only hand edits after the find-replace: (old line after replace, line the modder writes instead)
HAND = [
	('require "/scripts/lofty_petports/shared/copper.lua"', 'require "/scripts/%s/shared/copper.lua"' % NAME),
	('PETPORTS_CONSTANTS.copper.flag = "copper"', 'PETPORTS_CONSTANTS.copper.flag = "asterite"'),
	('PETPORTS_CONSTANTS.copper.sparkProjectile = "petports_copperspark"', 'PETPORTS_CONSTANTS.copper.sparkProjectile = "petports_asteritespark"'),
]

if os.path.exists(OUT): shutil.rmtree(OUT)
used = {h[0]: 0 for h in HAND}
for src, dst in FILES.items():
	s = open(SRC + src, encoding="utf-8").read()
	assert "Asterite" not in s and "ASTERITE" not in s
	s = s.replace(WORD_OLD, WORD_NEW)
	for old, new in HAND:
		used[old] += s.count(old)
		s = s.replace(old, new)
	assert WORD_OLD not in s.replace('flag = "asterite"', "").replace("petports_asteritespark", ""), dst
	os.makedirs(os.path.dirname(OUT + dst), exist_ok=True)
	open(OUT + dst, "wb").write(s.encode("utf-8"))
assert used[HAND[0][0]] == 2 and used[HAND[1][0]] == 1 and used[HAND[2][0]] == 1, used

def write_json(path, data):
	os.makedirs(os.path.dirname(OUT + path) or OUT, exist_ok=True)
	open(OUT + path, "wb").write((json.dumps(data, indent="\t") + "\n").encode("utf-8"))

write_json("_metadata", {
	"name": NAME,
	"friendlyName": "Petports example: copper mining",
	"author": "Lofty",
	"description": "Example add-on. The asterite module also mines copper.",
	"version": "1.0",
	"requires": ["lofty_petports"]
})
write_json("objects/lofty_petports/petport/petports_petport.object.patch", [
	{"op": "add", "path": "/scripts/-", "value": "/scripts/%s/work/copper.lua" % NAME}
])
for chassis in ("amphibious", "aquatic", "drone", "flyer", "sinker", "unrestricted"):
	assert os.path.exists(SRC + "monsters/lofty_petports/%s/petports_%s.monstertype" % (chassis, chassis))
	write_json("monsters/lofty_petports/%s/petports_%s.monstertype.patch" % (chassis, chassis), [
		{"op": "add", "path": "/baseParameters/scripts/-", "value": "/scripts/%s/tasks/copper.lua" % NAME}
	])
write_json("interface/lofty_petports/shared/petports_strings.config.patch", [
	{"op": "add", "path": "/petport/task/copper", "value": "Mining Copper"}
])
print("built", OUT)
