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
  7  No `arch` entry declares itself unbuilt.
  8  Every `plan` entry carries a date.
  9  Every tag cited in a BODY resolves too, not just in `see also`.

CHECKS 7 TO 9 EXIST BECAUSE 1 TO 6 CHECK SHAPE AND NOT TRUTH. On 2026-08-31 a
fully well-formed entry describing a family of "filter beacons" was found in
ARCHITECTURE, having entered the document on 2026-08-23 and survived the v2
carve-up intact. It passed every check above: unique tag, valid category, valid
topic, resolving references, filed under the section its `arch.` prefix demands.
It was also a design that had been superseded months earlier by filters living
on the two beacons that actually exist. Nothing structural was ever going to
catch it -- but its second line said "SPECIFIED, NOT BUILT" while sitting in the
section reserved for what IS built, and that is greppable.

  7  is the direct catch for that class. ARCH is for what exists; a design that
     announces itself unbuilt belongs in PLAN, where the rot table expects it to
     graduate or be abandoned. Anchored to the start of a paragraph so that a
     note about one unbuilt PART of a built system -- "`ceiling` is declared and
     not built" in arch.port.tetherlocation -- does not trip it.

  8  is the slow version of the same thing. A plan with no date has no age, and
     an entry with no age cannot be seen to have rotted. THE DATE MUST RECORD A
     REVIEW THAT HAPPENED. Stamping entries to clear this check is the same
     failure as fabricating a build stamp, and it converts the one tool that
     could have caught the filter beacons into the thing that hides the next one.

  9  is the gap check 5 left open. `see also` was validated and body prose was
     not, so a reference invented mid-paragraph resolved to nothing and said so
     to nobody. Found one on the first run. The category prefix is what
     distinguishes a tag from an ordinary dotted expression, so `edge.source.x`
     and `self.state.update` are ignored and `todo.pathing.whatever` is not.

     A RETIRED TAG IS WRITTEN WITHOUT BACKTICKS, which is the convention this
     check forces and it is the right one. An entry folded into another leaves
     prose behind naming what it used to be called -- "opened as
     todo.pathing.submergedplatform (retired)" -- and that is history, not a
     reference. Backticks claim it resolves. Bare text still greps, since the
     two-direction grep matches strings and not markup, so nothing is lost by
     dropping them and a false reference is gained by keeping them.

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

#  ANCHORED TO THE START OF A LINE, AND THAT ANCHOR IS THE WHOLE PRECISION.
#
#  "SPECIFIED, NOT BUILT." opening a paragraph is a claim about the ENTRY.
#  "**`ceiling` IS DECLARED AND NOT BUILT.**" mid-entry is a claim about one
#  PART of a built system, which is legitimate in ARCHITECTURE. Unanchored, this
#  pattern flags both; anchored, it flags only the first. Leading markdown
#  emphasis is allowed through because the document bolds its shouted claims.
UNBUILT_RE = re.compile(r'^\**(?:SPECIFIED,\s+)?NOT\s+(?:YET\s+)?BUILT\b', re.M)

#  Any ISO date anywhere in the body satisfies check 8. Deliberately loose: the
#  document already dates its markers a dozen different ways ("TRIAGED
#  2026-08-30", "DONE 2026-08-30", "MEASURED 2026-08-31"), and prescribing one
#  spelling would mean rewriting entries to satisfy a linter rather than to say
#  something. The check is that the entry has an AGE, not that it has a keyword.
DATE_RE = re.compile(r'\b20\d\d-\d\d-\d\d\b')


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
				'tagline': i + offset,
			})

		i += 1

	attach_bodies(lines, entries)
	return entries, findings


#  THE BODY IS EVERYTHING BETWEEN THE TAG LINE AND THE NEXT HEADING OF ANY
#  LEVEL. `####` subsections belong to the entry above them -- vent pipes lives
#  under arch.vent.routing that way -- so only `##` and `###` terminate.
def attach_bodies(lines, entries):
	for e in entries:
		start = e['tagline'] + 1
		end = start

		while end < len(lines):
			line = lines[end]
			if line.startswith('### ') or line.startswith('## '):
				break
			end += 1

		e['body'] = '\n'.join(lines[start:end])
		e['bodyline'] = start


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

		if e['cat'] == 'arch':
			m = UNBUILT_RE.search(e['body'])
			if m:
				at = e['bodyline'] + e['body'][:m.start()].count('\n') + 1
				findings.append(f"UNBUILT ARCH  {e['tag']}  line {at} -- "
				                f"declares itself not built while filed under "
				                f"ARCHITECTURE; this belongs in PLAN")

		if e['cat'] == 'plan' and not DATE_RE.search(e['body']):
			findings.append(f"UNDATED PLAN  {e['tag']}  line {e['line']} -- "
			                f"no date in the body, so this design has no age "
			                f"and cannot be seen to have gone stale")

	known = set(seen)
	for e in entries:
		for r in e['refs']:
			if r not in known:
				findings.append(f"DANGLING REF  {e['tag']}  line {e['line']} -- "
				                f"see also '{r}' does not exist")

		#  WHAT MAKES A DOTTED TOKEN A TAG IS THE CATEGORY PREFIX, and nothing
		#  else would work. The document is full of backticked three-part
		#  expressions that are code -- `edge.source.position`,
		#  `self.state.update` -- and they match TAG_RE exactly. Requiring the
		#  first segment to be one of the ten categories separates them
		#  cleanly: measured over the whole document it admits 138 real
		#  references and rejects every code expression.
		for line_no, line in enumerate(e['body'].split('\n')):
			for m in TAG_RE.finditer(line):
				ref = f'{m.group(1)}.{m.group(2)}.{m.group(3)}'

				if m.group(1) in CATEGORIES and ref not in known:
					findings.append(f"DANGLING BODY {e['tag']}  "
					                f"line {e['bodyline'] + line_no + 1} -- "
					                f"cites '{ref}', which does not exist")

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
