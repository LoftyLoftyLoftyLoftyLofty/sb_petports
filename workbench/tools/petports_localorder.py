import re,sys
src=open(sys.argv[1]).read().split("\n")
# definitions: local function NAME / local NAME = / NAME = function (assignment to forward-declared)
defs={}   # name -> first line where it becomes a *usable* value
fwd={}    # name -> line of forward declaration (local NAME = nil)
for i,l in enumerate(src,1):
    m=re.match(r'\s*local function ([A-Za-z_]\w*)',l)
    if m and m.group(1) not in defs: defs[m.group(1)]=i
    m=re.match(r'\s*local ([A-Za-z_]\w*)\s*=\s*nil',l)
    if m: fwd[m.group(1)]=i
    m=re.match(r'\s*local ([A-Za-z_][\w]*)\s*=',l)
    if m and m.group(1) not in defs and m.group(1) not in fwd: defs[m.group(1)]=i
    m=re.match(r'^([A-Za-z_]\w*)\s*=\s*function',l)
    if m and m.group(1) in fwd and m.group(1) not in defs: defs[m.group(1)]=i
names=set(defs)|set(fwd)
bad=[]
for i,l in enumerate(src,1):
    if l.strip().startswith("--"): continue
    for name in re.findall(r'\b([A-Za-z_]\w*)\s*\(',l):
        if name in names and name not in fwd:
            if i<defs.get(name,0):
                # used before definition and not forward-declared: only a bug if the use is inside a function body that runs before def... flag all
                bad.append((i,name,defs[name]))
for i,n,d in bad: print(f"line {i}: {n}() used before local definition at {d}")
