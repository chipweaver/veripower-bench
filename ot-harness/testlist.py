#!/usr/bin/env python3
"""Expand one OpenTitan *_sim_cfg.hjson (plus its imported common test cfgs)
into `name<TAB>uvm_test_seq<TAB>run_opts`."""
import hjson, os, re, sys

OT = os.environ["OT_ROOT"]

def load(p):
    with open(p) as f:
        return hjson.load(f)

def subst(s, ctx):
    prev = None
    while prev != s:
        prev = s
        s = re.sub(r"\{(\w+)\}", lambda m: str(ctx.get(m.group(1), m.group(0))), s)
    return s

def gather(cfg_path):
    cfg = load(cfg_path)
    ctx = {"name": cfg["name"], "proj_root": OT,
           "dut": cfg.get("dut", cfg["name"]), "tb": cfg.get("tb", "tb")}
    default_seq = cfg.get("uvm_test_seq", ctx["name"] + "_base_vseq")
    tests, seen, modes = [], set(), {}
    def collect_modes(d):
        for m in d.get("run_modes", []) or []:
            modes[subst(m["name"], ctx)] = m
    def take(d):
        for t in d.get("tests", []) or []:
            n = subst(t["name"], ctx)
            if n in seen:
                continue
            seen.add(n)
            seq, opts = None, []
            for mn in t.get("en_run_modes", []) or []:      # run_modes supply seq + opts
                m = modes.get(subst(mn, ctx))
                if not m:
                    continue
                if m.get("uvm_test_seq"):
                    seq = subst(m["uvm_test_seq"], ctx)
                opts += [subst(o, ctx) for o in (m.get("run_opts") or [])]
            seq = subst(t.get("uvm_test_seq", seq or default_seq), ctx)
            opts += [subst(o, ctx) for o in (t.get("run_opts") or [])]
            tests.append((n, seq, opts))
    imported = []
    for imp in cfg.get("import_cfgs", []) or []:
        q = subst(imp, ctx)
        if os.path.exists(q):
            imported.append(load(q))
    for d in imported + [cfg]:
        collect_modes(d)
    for d in imported + [cfg]:
        take(d)
    common = [subst(o, ctx) for o in (cfg.get("run_opts") or [])]
    return cfg, ctx, common, tests

if __name__ == "__main__":
    cfg, ctx, common, tests = gather(sys.argv[1])
    print("#" + cfg.get("uvm_test", ctx["name"] + "_base_test"))
    for n, s, o in tests:
        print(n + "\t" + s + "\t" + " ".join(common + o))
