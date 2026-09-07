#!/usr/bin/env python3
"""Transitive SystemVerilog package closure for one OpenTitan IP, in dependency order.

OpenTitan IPs are not package-self-contained: a port list may name a sibling IP's
types (hmac -> keymgr_pkg -> edn_pkg -> {entropy_src,csrng}_pkg). fusesoc resolves
this from .core files; this does it from the source, so no fusesoc is needed.

usage: pkgclosure.py <ip> [extra_seed_dir ...]      (OT_ROOT from the environment)
"""
import os, re, sys

OT = os.environ["OT_ROOT"]

# One implementation per package name. prim_generic is the synthesisable default;
# the vendor-specific prim_* trees and all DV/FPV trees are not candidates.
PREFER = ["/hw/ip/prim_generic/rtl/", "/hw/ip/prim/rtl/", "/hw/ip/tlul/rtl/",
          "/hw/top_earlgrey/rtl/autogen/", "/hw/top_earlgrey/rtl/", "/hw/ip/"]
EXCLUDE = ("/prim_xilinx", "/prim_asap7", "/top_darjeeling", "/top_englishbreakfast",
           "/dv/", "/pre_dv/", "/fpv/", "/tb/", "/ip_templates/", "/ip_autogen/",
           "/google_riscv-dv/", "/lowrisc_ibex/vendor/")

def _rank(p):
    for i, k in enumerate(PREFER):
        if k in p:
            return i
    return len(PREFER)

def index():
    best = {}
    for dp, dn, fn in os.walk(os.path.join(OT, "hw")):
        dn[:] = [d for d in dn if d != ".git"]
        for f in fn:
            if not f.endswith("_pkg.sv"):
                continue
            p = os.path.join(dp, f)
            if any(s in p for s in EXCLUDE):
                continue
            n = f[:-3]
            if n not in best or _rank(p) < _rank(best[n]):
                best[n] = p
    return best

def refs(path, names, self_name=None):
    t = open(path, errors="ignore").read()
    t = re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", "", t, flags=re.S))
    found = set(re.findall(r"\b([a-z][a-z0-9_]*_pkg)\s*::", t))
    found |= set(re.findall(r"\bimport\s+([a-z][a-z0-9_]*_pkg)\s*::", t))
    return {m for m in found if m in names and m != self_name}

def closure(ip, extra_dirs=()):
    pkgs = index()
    seed = set()
    for d in [os.path.join(OT, "hw/ip", ip, "rtl")] + list(extra_dirs):
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            if f.endswith((".sv", ".svh")):
                seed |= refs(os.path.join(d, f), pkgs)
    order, state = [], {}
    def visit(n):
        if state.get(n):
            return                      # 2 = done; 1 = on stack (cycle: first-seen order)
        state[n] = 1
        for d in sorted(refs(pkgs[n], pkgs, n)):
            visit(d)
        state[n] = 2
        order.append(n)
    for n in sorted(seed):
        visit(n)
    return [pkgs[n] for n in order]

if __name__ == "__main__":
    for p in closure(sys.argv[1], sys.argv[2:]):
        print(p)
