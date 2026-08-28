#!/usr/bin/env python3
"""
PETPORTS -- handoff tag lint.

The v2 handoff is organised by CATEGORY rather than by topic, and every entry
carries a tag:

    ### Water is a closed set for gravity-disabled actors
    `dead.locomotion.pelagic` -- see also `fact.pathing.swimedges`

The tag is what makes the document greppable in two directions:

    grep 'dd\\.'          every design decision
    grep '\\.pathing\\.'   everything about pathing, whatever its category

THAT SECOND ONE ONLY WORKS IF THE TOPIC SEGMENT IS SPELLED IDENTICALLY
EVERYWHERE, which is the whole reason this script exists. A topic invented
on the fly -- `pathfinding` beside `pathing` -- does not fail loudly. It just
quietly stops appearing in the grep that was supposed to find it, which is
exactly the rot the reorganisation is meant to remove.

Checks:

  1  Every entry has a tag.
  2  Every tag is unique.
  3  Category prefix is one of the ten.
  4  Topic segment is in the closed vocabulary.
  5  Every `see also` resolves to a tag that exists.
  6  Entries sit under the section their category names.

Also prints a census, which doubles as a progress readout while the v1
document is being carved up: entries per category, and per topic.

Usage:  petports_handoff.py PETPORTS_HANDOFF.md [--quiet]
Exit 1 on any finding.
"""

import re
import sys
from collections import Counter, defaultdict

CATEGORIES = {
	'status': 'STATUS',
	'arch':   'ARCHITECTURE',
	'dd':     'DESIGN DECISIONS',
	'plan':   'DESIGN INTENT -- PLANNED',
	'nice':   'DESIGN INTENT -- NICE TO HAVE',
	'fact':   'ENGINE FACTS',
	'dead':   'DISPROVEN',
	'ref':    'REFERENCE',
	'todo':   'BACKLOG',
	'proc':   'PROCESS',
}

# CLOSED ON PURPOSE. Adding one is fine; adding one without noticing is not.
TOPICS = {
	'port', 'unit', 'locomotion', 'pathing', 'dispatch',
	'network', 'vent', 'cargo', 'filter', 'beacon',
	'farming', 'upcycler', 'fuel', 'module', 'pane',
	'item', 'art', 'tooling',
}

TAG_RE = re.compile(r'`([a-z]+)\.([a-z]+)\.([a-z0-9]+)`')
SEEALSO_RE = re.compile(r'see also\s+(.*)$', re.I)


def parse(path):
	lines = open(path, encoding='utf-8').read().split('\n')
	entries, section, findings = [], None, []

	i = 0
	while i < len(lines):
		line = lines[i]

		if line.startswith('## '):
			section = line[3:].strip()

		elif line.startswith('### '):
			heading = line[4:].strip()
			# The tag line sits directly under the heading, allowing a blank.
			tagline, offset = None, None
			for look in (1, 2):
				if i + look < len(lines) and TAG_RE.search(lines[i + look]):
					tagline, offset = lines[i + look], look
					break

			if tagline is None:
				findings.append(f"NO TAG        line {i+1}: '{heading[:56]}'")
				i += 1
				continue

			m = TAG_RE.search(tagline)
			cat, topic, slug = m.group(1), m.group(2), m.group(3)

			refs = []
			sa = SEEALSO_RE.search(tagline)
			if sa:
				refs = ['.'.join(t) for t in TAG_RE.findall(sa.group(1))]

			entries.append({
				'line': i + 1,
				'heading': heading,
				'tag': f'{cat}.{topic}.{slug}',
				'cat': cat, 'topic': topic,
				'section': section,
				'refs': refs,
			})

		i += 1

	return entries, findings


def check(entries, findings):
	seen = {}
	for e in entries:
		if e['tag'] in seen:
			findings.append(f"DUPLICATE TAG {e['tag']}  line {e['line']} "
			                f"and line {seen[e['tag']]}")
		seen[e['tag']] = e['line']

		if e['cat'] not in CATEGORIES:
			findings.append(f"BAD CATEGORY  {e['tag']}  line {e['line']} -- "
			                f"'{e['cat']}' is not one of "
			                f"{', '.join(sorted(CATEGORIES))}")

		if e['topic'] not in TOPICS:
			near = [t for t in TOPICS if t.startswith(e['topic'][:4])]
			hint = f" -- did you mean {'/'.join(near)}?" if near else ""
			findings.append(f"BAD TOPIC     {e['tag']}  line {e['line']} -- "
			                f"'{e['topic']}' is not in the vocabulary{hint}")

		want = CATEGORIES.get(e['cat'])
		if want and e['section'] and want.lower() not in e['section'].lower():
			findings.append(f"WRONG SECTION {e['tag']}  line {e['line']} -- "
			                f"filed under '{e['section']}', category says "
			                f"'{want}'")

	known = set(seen)
	for e in entries:
		for r in e['refs']:
			if r not in known:
				findings.append(f"DANGLING REF  {e['tag']}  line {e['line']} -- "
				                f"see also '{r}' does not exist")

	return findings


def census(entries):
	print(f"\n{len(entries)} tagged entries\n")

	bycat = Counter(e['cat'] for e in entries)
	print("  by category")
	for c in CATEGORIES:
		n = bycat.get(c, 0)
		bar = '#' * min(40, n)
		print(f"    {c:7s} {n:4d}  {bar}")

	bytopic = Counter(e['topic'] for e in entries)
	print("\n  by topic")
	for t, n in bytopic.most_common():
		print(f"    {t:11s} {n:4d}")

	unused = sorted(TOPICS - set(bytopic))
	if unused:
		print(f"\n  topics never used: {', '.join(unused)}")

	# A topic with entries in only one category is usually a topic that has
	# not been cross-filed yet, which is useful while carving v1 up.
	spread = defaultdict(set)
	for e in entries:
		spread[e['topic']].add(e['cat'])
	thin = sorted(t for t, cs in spread.items() if len(cs) == 1)
	if thin:
		print(f"  single-category topics: {', '.join(thin)}")


def main():
	args = [a for a in sys.argv[1:] if not a.startswith('--')]
	quiet = '--quiet' in sys.argv

	if len(args) != 1:
		print(__doc__)
		return 2

	entries, findings = parse(args[0])
	findings = check(entries, findings)

	if not quiet:
		census(entries)

	if not findings:
		print("\nhandoff lint: clean")
		return 0

	print(f"\nhandoff lint: {len(findings)} finding(s)\n")
	for f in findings:
		print("  " + f)
	return 1


if __name__ == '__main__':
	sys.exit(main())
