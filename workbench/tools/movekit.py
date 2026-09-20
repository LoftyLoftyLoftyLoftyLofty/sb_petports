# Shared helpers for the behaviour-move patch scripts.
import re, os, subprocess, glob

ROOT = "lofty_petports/"
P = ROOT + "objects/lofty_petports/petport/"
M = ROOT + "monsters/lofty_petports/"
S = ROOT + "scripts/lofty_petports/"
MAIN = P + "petports_petport.lua"
TA = M + "petportsTaskAction.lua"
CT = M + "petports_contract.lua"
OBJ = P + "petports_petport.object"
TYPES = sorted(glob.glob(M + "*/*.monstertype"))

def port_ctx():
	return [MAIN] + sorted(glob.glob(P + "work/*.lua")) + sorted(glob.glob(S + "shared/*.lua")) + [S + "petports_%s.lua" % n for n in ("work", "modules", "filters", "habitat", "flavors", "upcyclerstate")]

def unit_ctx():
	return ([S + "petports_%s.lua" % n for n in ("work", "habitat", "flavors", "coarsenav")]
		+ [M + n for n in ("petports_petBehavior.lua", "petports_contract.lua", "petports_placement.lua", "petports_think.lua", "petports_bubble.lua", "petportsSleepAction.lua", "petportsTaskAction.lua", "petports_flyapproach.lua", "petportsFlopState.lua")]
		+ sorted(glob.glob(M + "tasks/*.lua")) + sorted(glob.glob(S + "shared/*.lua")))

VANILLA = {"simpleHandler", "copy", "compare"}
KEYWORDS = {"pcall", "tostring", "tonumber", "type", "pairs", "ipairs", "function", "if", "and", "or", "not", "return", "assert", "select", "next", "error", "unpack", "while", "for", "elseif", "until", "setmetatable", "getmetatable", "rawget", "rawset", "require"}

def rd(p):
	s = open(p, "rb").read().decode("utf-8")
	assert "\r" not in s, p
	return s

def once(s, a, label):
	assert s.count(a) == 1, "%s matched %d times" % (label, s.count(a))
	return s.index(a)

def swap(s, old, new, label):
	once(s, old, label)
	return s.replace(old, new)

def cut(s, start, end, label):
	a = once(s, start, label + " start"); b = once(s, end, label + " end")
	assert a < b, label + " order"
	return s[:a] + s[b:], s[a:b]

def tabs(block, drop=0):
	out = []
	for line in block.split("\n"):
		m = re.match(r"^( +)", line)
		if m:
			n = len(m.group(1))
			assert n >= drop, "indent: %r" % line
			line = "\t" * ((n - drop + 1) // 2) + line[n:]
		out.append(line)
	return "\n".join(out)

STRING_HITS = []

def rename(text, mapping):
	# Renames identifiers in code and comments only. A name inside a string literal is left alone and recorded in STRING_HITS,
	# because a string can be a message name or a remote function name and must be decided by hand.
	parts = re.split(r'("(?:[^"\\\n]|\\.)*")', text)
	for i, part in enumerate(parts):
		for old in sorted(mapping, key=len, reverse=True):
			pattern = r"(?<![\w.:])%s\b" % re.escape(old)
			if i % 2 == 1:
				if re.search(pattern, part): STRING_HITS.append((old, part[:90]))
			else:
				part = re.sub(pattern, mapping[old], part)
		parts[i] = part
	return "".join(parts)

def uses(text, name):
	return len(re.findall(r"(?<![\w.:])%s\b" % re.escape(name), text))

def delocalize(text, mapping):
	# Turns top-level local functions or tables into prefixed globals and renames every use.
	for old, new in mapping.items():
		assert not re.search(r"(?<![\w.])%s\b" % re.escape(new), text), "%s already exists; renaming %s onto it would shadow it" % (new, old)
		if ("local function %s(" % old) in text:
			text = swap(text, "local function %s(" % old, "function %s(" % old, "def " + old)
		else:
			m = re.search(r"^local %s( *=)" % re.escape(old), text, re.M)
			assert m, "no top-level local " + old
			text = text[:m.start()] + old + m.group(1) + text[m.end():]
	return rename(text, mapping)

def strip_code(s):
	s = re.sub(r"--\[\[.*?\]\]", "", s, flags=re.S)
	s = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', s)
	return re.sub(r"--[^\n]*", "", s)

def check(texts, newfiles, left_behind):
	# texts: {path: content} for a whole script context. Returns a list of problems.
	problems = []
	seen = {}
	for f, t in texts.items():
		for m in re.finditer(r"^function ([\w.]+)\s*\(", t, re.M): seen.setdefault(m.group(1), []).append(os.path.basename(f))
		for m in re.finditer(r"^([A-Za-z_]\w*)\s*=\s*function", t, re.M): seen.setdefault(m.group(1), []).append(os.path.basename(f))
	for k, v in seen.items():
		if len(v) > 1: problems.append("duplicate global %s in %s" % (k, v))
	everything = "\n".join(texts.values())
	for nf in newfiles:
		code = strip_code(texts[nf])
		declared = set(re.findall(r"\blocal\s+(?:function\s+)?([A-Za-z_]\w*)", code))
		for x in re.findall(r"\blocal\s+([\w ,]+?)\s*(?:=|\n)", code): declared |= set(re.split(r"\s*,\s*", x.strip()))
		for x in re.findall(r"\bfor\s+([\w ,]+?)\s+(?:in|=)", code): declared |= set(re.split(r"\s*,\s*", x.strip()))
		for x in re.findall(r"function[^\(\n]*\(([^)]*)\)", code): declared |= set(re.split(r"\s*,\s*", x.strip()))
		called = set(re.findall(r"(?<![\w.:])([A-Za-z_]\w*)\s*\(", code)) | set(re.findall(r"(?<![\w.:])([A-Z][A-Z_0-9]{3,})\b", code))
		for n in sorted(called - KEYWORDS - declared - VANILLA):
			if n in seen or re.search(r"^%s\s*=" % n, everything, re.M): continue
			problems.append("%s: unresolved %s" % (os.path.basename(nf), n))
		used = set(re.findall(r"(?<![\w.:])([A-Za-z_]\w*)", code))
		for lf in left_behind:
			tl = set(re.findall(r"^local (?:function )?([A-Za-z_]\w*)", texts[lf], re.M))
			for n in sorted((used & tl) - declared):
				problems.append("%s: uses %s, a top-level local of %s" % (os.path.basename(nf), n, os.path.basename(lf)))
	return problems

def finish(out, newfiles, ctx, left_behind, write):
	# out: {path: content}. Runs syntax and context checks on the assembled result, writes only if clean and asked.
	texts = {f: (out[f] if f in out else rd(f)) for f in set(ctx) | set(newfiles)}
	problems = check(texts, newfiles, left_behind)
	for p, s in out.items():
		if p.endswith(".lua"):
			assert not (p in newfiles and re.search(r"^ +\S", s, re.M)), "space indentation in " + p
			tmp = "/tmp/kit_" + os.path.basename(p)
			open(tmp, "wb").write(s.encode("utf-8"))
			r = subprocess.run(["texluac", "-p", tmp], capture_output=True, text=True)
			if r.returncode != 0: problems.append("syntax %s: %s" % (p, r.stderr.strip()))
	if os.path.exists("luac.out"): os.remove("luac.out")
	for old, where in STRING_HITS: print("STRING", old, "left alone inside", where)
	del STRING_HITS[:]
	for x in problems: print("PROBLEM", x)
	if problems:
		print("nothing written"); return False
	if write:
		for p, s in out.items():
			os.makedirs(os.path.dirname(p), exist_ok=True)
			open(p, "wb").write(s.encode("utf-8"))
		print("written:", ", ".join(os.path.relpath(p, ROOT) for p in out))
	else:
		print("dry run clean")
	return True

def defs(block):
	# Names of every top-level function a block defines, for asserting a cut carried only what was meant.
	return re.findall(r"^(?:local )?function ([\w.]+)", block, re.M)
