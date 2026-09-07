#!/usr/bin/env python3
"""Parse an OpenTitan IP top's module header: imports and port declarations.

Shared by mkstub.py and mkshim.py so the parser exists once.
"""
import re, sys

DECL = re.compile(r"""^\s*(?P<dir>input|output|inout)\s+
                       (?P<type>.*?)\s*
                       (?P<name>[A-Za-z_][A-Za-z_0-9]*)\s*
                       (?P<dim>(\[[^\]]*\]\s*)*)$""", re.X)

def _strip(t):
    return re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", "", t, flags=re.S))

def header(path, mod):
    """-> (imports, ports); ports is [(dir, type, name, dim), ...] in order."""
    text = open(path).read()
    m = re.search(r"^module\s+%s\b" % re.escape(mod), text, re.M)
    if not m:
        sys.exit("module %s not found in %s" % (mod, path))
    head = re.search(r"^module\s+%s\b(.*?)(?=^\s*[#(])" % re.escape(mod),
                     text, re.M | re.S)
    imports = [" ".join(i.split())
               for i in re.findall(r"import\s+[^;]+;", head.group(1) if head else "")]
    # the port list is the last balanced (...) before the body; a parameter list,
    # if present, is the one preceded by '#'
    i, depth, start = m.end(), 0, None
    while i < len(text):
        c = text[i]
        if c == "(":
            if depth == 0 and start is None:
                start = i
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                inner = text[start + 1:i]
                if "#" in text[m.end():start] and re.match(r"\s*\(", text[i + 1:i + 40]):
                    start, depth = None, 0
                    i += 1
                    continue
                ports = []
                for raw in _strip(inner).split(","):
                    s = " ".join(raw.split())
                    if not s:
                        continue
                    d = DECL.match(s)
                    if not d:
                        sys.exit("unparsed port declaration: %r" % s)
                    g = d.groupdict()
                    ports.append((g["dir"], g["type"].strip(),
                                  g["name"], g["dim"].strip()))
                return imports, ports
        i += 1
    sys.exit("unbalanced port list in %s" % path)
