#!/usr/bin/env python3
"""Resolve one CAPI2 core's fileset closure into an ordered file list.

Replaces fusesoc for the one thing this harness needs: given `lowrisc:dv:<ip>_sim`,
emit the +incdir+ set and the SystemVerilog files in dependency order. Virtual
cores (lowrisc:prim:*, lowrisc:virtual_constants:*) resolve to nothing here —
their modules are found through the -y library paths build.sh passes, and their
packages come from pkgclosure.py.

usage: flist.py <core-name> [target]           (OT_ROOT from the environment)
"""
import os, sys, yaml

OT = os.environ["OT_ROOT"]

def load_cores(root):
    cores = {}
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if d not in (".git", "build", "bazel-out")]
        for f in fn:
            if not f.endswith(".core"):
                continue
            p = os.path.join(dp, f)
            txt = open(p).read()
            if not txt.startswith("CAPI=2"):
                continue
            try:
                d = yaml.safe_load(txt.split("\n", 1)[1])
            except Exception:
                continue
            if not isinstance(d, dict) or "name" not in d:
                continue
            d["_path"] = dp
            cores.setdefault(d["name"], d)
            cores.setdefault(":".join(d["name"].split(":")[:3]), d)
    return cores

def resolve(cores, name, target="default", seen=None, order=None):
    if seen is None:
        seen, order = set(), []
    key = ":".join(name.split(":")[:3])
    if key in seen:
        return order
    seen.add(key)
    core = cores.get(name) or cores.get(key)
    if core is None:
        return order                                  # virtual core: see docstring
    tgts = core.get("targets", {})
    tgt = tgts.get(target) or tgts.get("default") or {}
    fsets = tgt.get("filesets", []) or list(core.get("filesets", {}).keys())
    picked = []
    for fs in fsets:
        if "?" in fs:
            # `<flag> ? (files_x)` selects a fileset for a tool we do not use
            # (the verilator/ascentlint waiver sets); `!<flag> ? (files_x)` is
            # the everything-else case, which is ours.
            cond, rest = fs.split("?", 1)
            if cond.strip().startswith("!"):
                picked.append(rest.strip(" ()"))
        else:
            picked.append(fs)
    for fs in picked:
        spec = core.get("filesets", {}).get(fs)
        if not spec:
            continue
        for dep in spec.get("depend", []) or []:
            if isinstance(dep, str) and dep.split():
                resolve(cores, dep.split()[0], "default", seen, order)
        for f in spec.get("files", []) or []:
            fname, attrs = next(iter(f.items())) if isinstance(f, dict) else (f, {})
            order.append((os.path.join(core["_path"], fname), attrs or {}))
    return order

if __name__ == "__main__":
    cores = load_cores(os.path.join(OT, "hw"))
    top = sys.argv[1]
    tgt = sys.argv[2] if len(sys.argv) > 2 else "default"
    incdirs, files = [], []
    for path, attrs in resolve(cores, top, tgt):
        if attrs.get("is_include_file"):
            d = os.path.dirname(path)
            if d not in incdirs:
                incdirs.append(d)
        else:
            files.append(path)
    for d in incdirs:
        print("+incdir+" + d)
    for f in files:
        print(f)
