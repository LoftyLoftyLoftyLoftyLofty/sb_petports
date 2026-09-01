#!/usr/bin/env python3
"""
PETPORTS -- pane pre-flight.

Stands in for petports_luacheck.py, which was not in the working copy this
session. It exists because of one specific failure and catches that class:

    PORTRAIT_SCALE was renamed, three text replacements were applied to rename
    every use, ONE OF THEM SILENTLY DID NOT MATCH, and the surviving reference
    became a nil GLOBAL. Lua does not complain about reading an undefined
    global -- it hands back nil -- so the file loaded, the pane opened, and it
    threw inside update() on the first frame that drew a portrait:

        attempt to perform arithmetic on a nil value (global 'PORTRAIT_SCALE')

    Nothing static caught it. Balance was fine, JSON was fine, every callback
    resolved. An UPPER_CASE identifier that is read but never declared is the
    exact shape of that bug and is nearly free to look for.

Checks, in order of how much each has cost:

  1  UNDEFINED CONSTANTS. Any UPPER_CASE name read but never declared local.
  2  UNUSED CONSTANTS. The other half of a half-applied rename.
  3  LOCAL FUNCTION USED ABOVE ITS DEFINITION -- a nil global at call time.
  4  CALLBACK WIRING both ways against the .config.
  5  WIDGET NAMES the script touches but the config does not declare.
  6  LUA 5.3 SYNTAX. Starbound is 5.1: no \\u{}, no goto, no integer division.
  7  GEOMETRY. Nothing outside the pane's usable band.

Usage:  petports_paneheck.py <pane.lua> <pane.config> [--band LOW HIGH]
Exit 1 on any finding, so it can gate a delivery.
"""

import json
import re
import sys


def strip_json_comments(raw):
	"""Starbound JSON allows // comments; json.loads does not."""
	out, in_str, esc, i = [], False, False, 0
	while i < len(raw):
		c = raw[i]
		if in_str:
			out.append(c)
			if esc:
				esc = False
			elif c == '\\':
				esc = True
			elif c == '"':
				in_str = False
			i += 1
			continue
		if c == '"':
			in_str = True
			out.append(c)
			i += 1
			continue
		if c == '/' and i + 1 < len(raw) and raw[i + 1] == '/':
			while i < len(raw) and raw[i] != '\n':
				i += 1
			continue
		out.append(c)
		i += 1
	return ''.join(out)


def strip_lua(src):
	"""Blank out comments and string bodies, preserving line count."""
	out, i, n = [], 0, len(src)
	while i < n:
		if src.startswith('--[[', i):
			j = src.find(']]', i)
			chunk = src[i:n if j < 0 else j + 2]
			out.append(re.sub(r'[^\n]', ' ', chunk))
			i = n if j < 0 else j + 2
			continue
		if src.startswith('--', i):
			j = src.find('\n', i)
			j = n if j < 0 else j
			out.append(' ' * (j - i))
			i = j
			continue
		c = src[i]
		if c in '"\'':
			q, start = c, i
			i += 1
			while i < n:
				if src[i] == '\\':
					i += 2
					continue
				if src[i] == q:
					i += 1
					break
				if src[i] == '\n':
					break
				i += 1
			out.append(re.sub(r'[^\n]', ' ', src[start:i]))
			continue
		out.append(c)
		i += 1
	return ''.join(out)


def check(lua_path, cfg_path, band):
	src = open(lua_path, 'rb').read().decode('utf-8')
	clean = strip_lua(src)
	cfg = json.loads(strip_json_comments(open(cfg_path, 'rb').read().decode('utf-8')))
	gui = cfg.get('gui', {})
	findings = []

	def line_of(pos):
		return src[:pos].count('\n') + 1

	# -- 0: BLOCK BALANCE ----------------------------------------------------
	#
	# This is first because it is the only check here that catches a file
	# that will not COMPILE, and it was missing when a stray `end` shipped:
	#
	#     :488: 'end' expected (to close 'function' at line 456) near 'elseif'
	#
	# An orphaned `end` left behind by a text-sliced deletion closed an `if`
	# early and stranded its `elseif`. Nothing else in this tool looks at
	# structure, so every other check passed on a file the engine could not
	# even parse.
	#
	# COUNTED EXACTLY, NOT HEURISTICALLY. Earlier passes counted `function`,
	# `if`, `for` and `while` as openers and came out at -1 or -2 on healthy
	# files, so "is this number normal" needed calibrating against known-good
	# panes -- which is useless as a gate. `for` and `while` do not open the
	# block; their `do` does. So the openers are `function`, `if` and `do`,
	# `repeat`/`until` pair on their own, and a correct file balances at
	# exactly zero.
	depth = 0
	opens = []
	for m in re.finditer(r'\b(function|if|do|end|repeat|until|elseif|else)\b', clean):
		word = m.group(1)
		if word in ('function', 'if', 'do'):
			depth += 1
			opens.append((word, line_of(m.start())))
		elif word == 'repeat':
			depth += 1
			opens.append(('repeat', line_of(m.start())))
		elif word in ('end', 'until'):
			depth -= 1
			if depth < 0:
				findings.append(f"BLOCK BALANCE       extra '{word}' at line "
				                f"{line_of(m.start())} -- closes a block that "
				                f"was never opened")
				depth = 0
			elif opens:
				opens.pop()

	if depth > 0:
		where = ', '.join(f"{w} at line {ln}" for w, ln in opens[-3:])
		findings.append(f"BLOCK BALANCE       {depth} block(s) left open -- "
		                f"innermost: {where}")

	# -- 1 & 2: constants ----------------------------------------------------
	declared = {}
	for m in re.finditer(r'^\s*local\s+([A-Z][A-Z0-9_]{2,})\s*=', clean, re.M):
		declared.setdefault(m.group(1), line_of(m.start()))

	read = {}
	for m in re.finditer(r'\b([A-Z][A-Z0-9_]{2,})\b', clean):
		name = m.group(1)
		if name in ('PETPORTS',):
			continue
		read.setdefault(name, []).append(line_of(m.start()))

	for name, lines in sorted(read.items()):
		if name not in declared:
			findings.append(f"UNDEFINED CONSTANT  {name}  read at line(s) "
			                f"{', '.join(str(x) for x in lines[:4])} -- nil global at runtime")

	for name, defline in sorted(declared.items()):
		uses = [x for x in read.get(name, []) if x != defline]
		if not uses:
			findings.append(f"UNUSED CONSTANT     {name}  declared line {defline} "
			                f"-- half-applied rename?")

	# -- 3: local function used above its definition -------------------------
	fwd = set(re.findall(r'^\s*local\s+([A-Za-z_]\w*)\s*$', clean, re.M))
	for m in re.finditer(r'^\s*local\s+function\s+([A-Za-z_]\w*)', clean, re.M):
		name, defline = m.group(1), line_of(m.start())
		if name in fwd:
			continue
		for u in re.finditer(r'\b' + re.escape(name) + r'\s*\(', clean):
			if line_of(u.start()) < defline:
				findings.append(f"USED BEFORE DEFINED {name}  called line "
				                f"{line_of(u.start())}, defined line {defline}")
				break

	# -- 3b: bare calls to undefined functions -------------------------------
	#
	# The constant check above is UPPER_CASE only, so a missing lowercase
	# helper slipped straight past it -- a one-shot debug dump called j(),
	# which lives in the upcycler pane and had never been copied into this
	# one. Identical failure to PORTRAIT_SCALE: nil global, loads fine,
	# throws when that branch first runs. Caught before it shipped only
	# because someone happened to grep for it.
	ENGINE = {
		# lua 5.1 stdlib
		'assert', 'error', 'ipairs', 'next', 'pairs', 'pcall', 'print',
		'rawget', 'rawset', 'require', 'select', 'setmetatable', 'tonumber',
		'tostring', 'type', 'unpack', 'xpcall', 'getmetatable', 'rawequal',
		'collectgarbage', 'loadstring',
		# starbound pane/entity callbacks the ENGINE calls on us
		'init', 'update', 'uninit', 'createTooltip', 'displayed', 'dismissed',
		'canvasClickEvent', 'canvasKeyEvent',
	}
	local_names = set(re.findall(r'\blocal\s+function\s+([A-Za-z_]\w*)', clean))
	local_names |= set(re.findall(r'\blocal\s+([A-Za-z_]\w*)\s*=', clean))
	local_names |= set(re.findall(r'\blocal\s+([A-Za-z_]\w*)\s*$', clean, re.M))
	global_fns = set(re.findall(r'^function\s+([A-Za-z_]\w*)\s*\(', clean, re.M))

	seen_bad = set()
	for m in re.finditer(r'(?<![\w.:])([a-z_]\w*)\s*\(', clean):
		name = m.group(1)
		if name in local_names or name in global_fns or name in ENGINE:
			continue
		if name in ('function', 'if', 'while', 'for', 'return', 'and', 'or', 'not', 'end'):
			continue
		if name in seen_bad:
			continue
		seen_bad.add(name)
		findings.append(f"UNDEFINED CALL      {name}()  at line {line_of(m.start())} "
		                f"-- not a local, a pane global, or engine")

	# -- 4: callbacks, both directions ---------------------------------------
	swc = set(cfg.get('scriptWidgetCallbacks', []))
	globals_defined = set(re.findall(r'^function\s+([A-Za-z_]\w*)\s*\(', clean, re.M))
	for name in sorted(swc - globals_defined):
		findings.append(f"CALLBACK MISSING    {name}  declared in config, not defined in lua")

	used = set()

	#  ROW CALLBACKS ARE THE INVERSE RULE AND MUST NOT BE REPORTED.
	#
	#  A widget inside a list's listTemplate is built by ListWidget's own parser,
	#  which has never heard of scriptWidgetCallbacks. Naming one there makes
	#  addListItem throw at CONSTRUCTION and the pane never opens -- so for row
	#  widgets, ABSENCE from scriptWidgetCallbacks is correct and presence is the
	#  bug. They are registered at runtime with widget.registerMemberCallback.
	#
	#  Reported the other way round instead: a row callback that the script never
	#  registers is the failure worth catching, and it is checked below.
	row_used = set()

	def walk(node, in_template=False):
		if isinstance(node, dict):
			for k, v in node.items():
				if k in ('callback', 'rightClickCallback') and isinstance(v, str):
					(row_used if in_template else used).add(v)
				walk(v, in_template or k == 'listTemplate')
		elif isinstance(node, list):
			for v in node:
				walk(v, in_template)

	walk(gui)

	#  A ROW CALLBACK MUST BE REGISTERED IN LUA, and registerMemberCallback is
	#  the only way to do it. Missing registration is a click that silently does
	#  nothing -- quieter than the construction throw, and harder to find.
	#  SCANNED FROM THE RAW SOURCE, NOT `clean`. strip_lua removes string
	#  literals, and the registered name IS a string literal -- searching the
	#  stripped text reports every correctly registered callback as missing.
	#  Found by this check firing on the upcycler, which registers both of its.
	registered = set(re.findall(
		r'registerMemberCallback\s*\([^,]+,\s*["\']([\w]+)["\']', src))

	#  `null` IS A PLACEHOLDER, NOT A CALLBACK -- the same exclusion the
	#  pane-level check makes just below.
	for name in sorted(row_used - {'null', 'close'}):
		if name not in registered:
			findings.append(f"ROW CALLBACK UNREGISTERED  {name}  named inside a "
				f"listTemplate, never passed to widget.registerMemberCallback")
		if name in swc:
			findings.append(f"ROW CALLBACK IN swc        {name}  is a row callback "
				f"AND named in scriptWidgetCallbacks -- throws at CONSTRUCTION")
	for name in sorted(used - swc - {'null', 'close'}):
		findings.append(f"CALLBACK UNWIRED    {name}  named by a widget, absent from "
		                f"scriptWidgetCallbacks -- throws at CONSTRUCTION")

	#  A WIDGET THAT MUST NAME A CALLBACK AND DOES NOT.
	#
	#  THE CHECK ABOVE CANNOT SEE THIS, and the difference cost a client crash on
	#  2026-09-01. It compares callbacks that ARE named against scriptWidgetCallbacks;
	#  a widget with no `callback` key at all never enters `used`, so a missing one
	#  is invisible to it. A textbox added with no callback threw
	#
	#      (WidgetParserException) Failed to find textbox callback named: 'tbPetName'
	#
	#  inside the ContainerPane CONSTRUCTOR -- WidgetParser falls back to the
	#  WIDGET'S OWN NAME and throws when nothing of that name is registered. The
	#  pane did not misbehave, it failed to exist, and interacting dropped the
	#  client to the main menu.
	#
	#  TEXTBOX ONLY, BECAUSE TEXTBOX IS WHAT WAS MEASURED. Other types may share
	#  the rule and none of them have been tested, so they are not asserted here.
	#  Adding one means crashing a pane on purpose first; a guessed entry in this
	#  set would fail working panes and get the whole check switched off.
	#
	#  ROW WIDGETS ARE EXEMPT AND THAT IS NOT AN OVERSIGHT. Inside a listTemplate
	#  the opposite rule applies -- see the row-callback notes above -- and whether
	#  a row TEXTBOX must name one is untested. Skipped rather than guessed.
	REQUIRES_CALLBACK = ('textbox',)

	def walk_required(node, name=None, in_template=False):
		if isinstance(node, dict):
			if (not in_template
			    and node.get('type') in REQUIRES_CALLBACK
			    and not isinstance(node.get('callback'), str)):
				findings.append(f"CALLBACK MISSING    {name}  is a "
					f"{node.get('type')} with no callback -- WidgetParser falls back "
					f"to the widget name and throws at CONSTRUCTION")
			for k, v in node.items():
				walk_required(v, k, in_template or k == 'listTemplate')
		elif isinstance(node, list):
			for v in node:
				walk_required(v, name, in_template)

	walk_required(gui)

	# -- 5: widget names -----------------------------------------------------
	prefixes = set(re.findall(r'"([A-Za-z_]\w*)"\s*\.\.', clean))
	for name in sorted(set(re.findall(r'widget\.\w+\(\s*"([A-Za-z_]\w*)"', clean))):
		if name not in gui and name not in prefixes:
			findings.append(f"UNKNOWN WIDGET      {name}  touched by lua, not declared in config")

	# -- 6: Lua 5.3 syntax in a 5.1 engine -----------------------------------
	for pattern, why in ((r'\\u\{', r'\u{} escape'),
	                     (r'\bgoto\b', 'goto'),
	                     (r'//(?!/)', 'integer division')):
		for m in re.finditer(pattern, clean):
			findings.append(f"LUA 5.3 SYNTAX      {why} at line {line_of(m.start())} "
			                f"-- Starbound is 5.1")

	# -- 7: geometry ---------------------------------------------------------
	low, high = band
	for name, w in gui.items():
		if not isinstance(w, dict) or name == 'close':
			continue
		pos = w.get('position')
		if isinstance(pos, list) and len(pos) == 2 and not (low <= pos[1] <= high):
			findings.append(f"OUTSIDE PANE        {name} at y={pos[1]} "
			                f"-- usable band is {low}..{high}")

	return findings


def main():
	args = [a for a in sys.argv[1:]]
	band = (25, 310)
	if '--band' in args:
		i = args.index('--band')
		band = (int(args[i + 1]), int(args[i + 2]))
		args = args[:i] + args[i + 3:]

	if len(args) != 2:
		print(__doc__)
		return 2

	findings = check(args[0], args[1], band)
	if not findings:
		print("pane pre-flight: clean")
		return 0

	print(f"pane pre-flight: {len(findings)} finding(s)\n")
	for f in findings:
		print("  " + f)
	return 1


if __name__ == '__main__':
	sys.exit(main())
