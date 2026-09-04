#!/usr/bin/env python3
"""Block balance for Lua 5.1, tokenised properly.

The naive strip-comments-then-strip-strings approach is WRONG on this codebase
and silently so: a log string containing ` -- ` has its closing quote eaten by
the comment pass, which desyncs everything after it. Several strings in
petports_petport.lua do exactly that. Tokenise once, left to right, tracking
which construct we are inside.

Reports the block nesting depth at EOF and the line of any unmatched opener.
"""
import io
import re
import sys

OPEN = {"function", "if", "for", "while", "do", "repeat"}
CLOSE = {"end", "until"}

WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
LONG_OPEN = re.compile(r"\[(=*)\[")


def tokens(src):
	"""Yield (word, line) for every Lua keyword outside strings and comments."""
	i, n, line = 0, len(src), 1
	while i < n:
		c = src[i]

		if c == "\n":
			line += 1
			i += 1
			continue

		#  comment, long or short
		if src.startswith("--", i):
			m = LONG_OPEN.match(src, i + 2)
			if m:
				close = "]" + m.group(1) + "]"
				j = src.find(close, m.end())
				j = n if j == -1 else j + len(close)
			else:
				j = src.find("\n", i)
				j = n if j == -1 else j
			line += src.count("\n", i, j)
			i = j
			continue

		#  long string
		m = LONG_OPEN.match(src, i)
		if m:
			close = "]" + m.group(1) + "]"
			j = src.find(close, m.end())
			j = n if j == -1 else j + len(close)
			line += src.count("\n", i, j)
			i = j
			continue

		#  quoted string, escapes respected
		if c in "\"'":
			j = i + 1
			while j < n:
				if src[j] == "\\":
					j += 2
					continue
				if src[j] == c:
					j += 1
					break
				if src[j] == "\n":
					break
				j += 1
			line += src.count("\n", i, j)
			i = j
			continue

		m = WORD.match(src, i)
		if m:
			yield m.group(0), line
			i = m.end()
			continue

		i += 1


def check(path):
	src = io.open(path, encoding="utf-8", newline="").read()
	stack = []
	#  `for`/`while` open with a following `do` that must not count twice, and a
	#  `repeat` closes on `until` rather than `end`.
	pending_do = 0

	for word, line in tokens(src):
		if word in ("for", "while"):
			pending_do += 1
		elif word == "do":
			if pending_do > 0:
				pending_do -= 1
				stack.append(("for/while", line))
			else:
				stack.append(("do", line))
		elif word in ("function", "if", "repeat"):
			stack.append((word, line))
		elif word == "end":
			if not stack:
				return path, -1, "`end` with nothing open at line %d" % line
			stack.pop()
		elif word == "until":
			if stack and stack[-1][0] == "repeat":
				stack.pop()

	if stack:
		kind, line = stack[-1]
		return path, len(stack), "unclosed `%s` opened at line %d" % (kind, line)
	return path, 0, "balanced"


if __name__ == "__main__":
	bad = 0
	for path in sys.argv[1:]:
		p, depth, note = check(path)
		flag = "OK " if depth == 0 else "BAD"
		if depth != 0:
			bad += 1
		print("%s %-56s %s" % (flag, p.split("/")[-1], note))
	sys.exit(1 if bad else 0)
