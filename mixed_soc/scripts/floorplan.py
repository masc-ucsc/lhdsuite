#!/usr/bin/env python3
"""Generate a connected floorplan workload; no per-gate netlist or PDK needed."""
import argparse
import json
from pathlib import Path

from topology import GEMMINIS, HOST, HOST_PINS, TILES, links


def machine():
    objects, nets = [], []

    def obj(instance, module, local, cells, macro=False):
        name = instance + "." + local
        objects.append(dict(id=name, instance=instance, module=module, macro=macro, cells=cells,
                            pins=256 if macro else 3 * cells, nets=192 if macro else 2 * cells,
                            area=32768 if macro else 2 * cells, width=256 if macro else 2, height=128 if macro else 1))
        return name

    def link(a, b):
        nets.append([a, b])

    routers = [obj(f"soc.noc.r{i}", "mesh_router", "switch", 12000) for i in range(len(TILES))]
    for a, _, b, _ in links():
        link(routers[a], routers[b])
    for module, cells, colors, banks in (("Rocket", 5000000, 160, 6), ("BOOM", 18000000, 600, 16)):
        for tile, name in enumerate(TILES):
            if not name.startswith(module):
                continue
            inst = f"soc.{name}"
            nodes = [obj(inst, module, f"c{j:04}", cells // colors + (j < cells % colors)) for j in range(colors)]
            for j, node in enumerate(nodes):
                for stride in (1, 8):
                    if j >= stride:
                        link(nodes[j - stride], node)
            for j in range(banks):
                link(nodes[j * colors // banks], obj(inst, module, f"sram{j}", 1, True))
            link(routers[tile], nodes[0])
            link(nodes[-1], routers[tile])
    for acc in GEMMINIS:
        pe = []
        for i in range(64):
            inst = f"soc.{TILES[acc]}.pe{i}"
            nodes = [obj(inst, "GemminiPE", f"c{j:02}", 31250) for j in range(32)]
            for a, b in zip(nodes, nodes[1:]):
                link(a, b)
            link(nodes[-1], obj(inst, "GemminiPE", "scratch", 1, True))
            pe.append(nodes[0])
            if i % 8:
                link(pe[i - 1], pe[i])
            if i >= 8:
                link(pe[i - 8], pe[i])
        link(routers[acc], pe[0])
        link(pe[-1], routers[acc])
    return [{"class": "livehd.placement.color_graph", "design": "mixed_soc", "id": "top", "schema_version": 1,
             "core_dbu": [0, 0, 36000, 32000], "site_dbu": 1, "row_dbu": 1, "density": .6, "objects": objects, "nets": nets,
             "terminals": [{"name": name, "object": routers[HOST], "xy_dbu": xy} for name, xy in HOST_PINS.items()]}]


def validate_graph(graph):
    objects = graph["objects"]
    adjacency = {o["id"]: set() for o in objects}
    assert len(objects) == len(adjacency)
    for a, b in graph["nets"]:
        adjacency[a].add(b)
        adjacency[b].add(a)
    root = objects[0]["id"]
    seen, pending = {root}, [root]
    while pending:
        neighbors = adjacency[pending.pop()] - seen
        seen.update(neighbors)
        pending.extend(neighbors)
    assert len(seen) == len(objects), "disconnected shared machine"
    for module, copies in (("Rocket", 12), ("BOOM", 4), ("GemminiPE", 64 * len(GEMMINIS)), ("mesh_router", len(TILES))):
        assert len({o["instance"] for o in objects if o["module"] == module}) == copies
    # All 16 CPUs and all accelerators attach directly to the same fabric.
    attachments = {peer.split(".")[1] for o in objects if o["module"] == "mesh_router"
                   for peer in adjacency[o["id"]] if not peer.startswith("soc.noc.")}
    assert attachments == {TILES[i] for i in GEMMINIS} | {f"Rocket{i}" for i in range(12)} | {f"BOOM{i}" for i in range(4)}
    assert {p["name"] for p in graph["terminals"] if p["object"] == f"soc.noc.r{HOST}.switch"} == set(HOST_PINS)
    for tile, name in enumerate(TILES):
        peers = {p.split(".")[1] for p in adjacency[f"soc.noc.r{tile}.switch"] if not p.startswith("soc.noc.")}
        assert peers == (set() if tile == HOST else {name}), (tile, peers)
    assert sum(o["cells"] for o in objects if not o["macro"]) == 132000000 + 64000000 * len(GEMMINIS) + 12000 * len(TILES)
    assert sum(o["macro"] for o in objects) == 136 + 64 * len(GEMMINIS)


def validate_plan(graph, plan, budget_bytes):
    objects = {o["id"]: o for o in graph["objects"]}
    templates, homes, edges = {}, {}, []
    area = 0
    x0, y0, x1, y1 = graph["core_dbu"]
    for chunk in plan["chunks"]:
        x, y, r, t = chunk["box_dbu"]
        assert x0 <= x < r <= x1 and y0 <= y < t <= y1
        area += (r - x) * (t - y)
        edges.extend(((x, 1, y, t), (r, 0, y, t)))
        assert chunk["estimated_bytes"] <= budget_bytes
        for member in chunk["members"]:
            name = member["id"]
            assert name not in homes
            homes[name] = (chunk["id"], (x + r) / 2, (y + t) / 2)
            o = objects[name]
            key = (o["module"], name.removeprefix(o["instance"] + "."))
            assert templates.setdefault(key, chunk["partition"]) == chunk["partition"], "replica mismatch"
    host_contacts = {}
    for pin in graph["terminals"]:
        owner = homes[pin["object"]][0]
        contacts = [(c, p["xy_dbu"]) for c in plan["chunks"] for p in c["ports"] if p["net"] == pin["name"]]
        assert len(contacts) == 1 and contacts[0][0]["id"] == owner, ("missing/misplaced external contact", pin)
        chunk, (px, py) = contacts[0]
        host_contacts[pin["name"]] = dict(chunk=owner, chunk_xy_dbu=[px, py], block_xy_dbu=pin["xy_dbu"])
        l, b, r, t = chunk["box_dbu"]
        assert l <= px <= r and b <= py <= t and (px in (l, r) or py in (b, t))
    assert homes.keys() == objects.keys() and area == (x1 - x0) * (y1 - y0)
    from bisect import bisect_left, insort
    active = []
    for _, add, lo, hi in sorted(edges):
        if not add:
            active.remove((lo, hi))
        else:
            i = bisect_left(active, (lo, hi))
            assert (i == 0 or active[i - 1][1] <= lo) and (i == len(active) or hi <= active[i][0]), "overlap"
            insort(active, (lo, hi))
    # A placement-quality proxy available before any downstream solver runs.
    wire, crossing = 0, 0
    for a, b in graph["nets"]:
        aid, ax, ay = homes[a]
        bid, bx, by = homes[b]
        if aid != bid:
            crossing += 1
            wire += abs(ax - bx) + abs(ay - by)
    return dict(crossing_chunk_nets=crossing, crossing_center_hpwl_dbu=wire, external_contacts=host_contacts)



if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--graph", type=Path, help="write the color graph as standard LiveHD metadata")
    parser.add_argument("--planner", type=Path, help="fp_plan_summary binary; run five independent planner processes")
    parser.add_argument("--out", type=Path, default=Path("mixed_soc_runs"))
    args = parser.parse_args()
    bundle = machine()
    validate_graph(bundle[0])
    if args.graph:
        args.graph.write_text(json.dumps(bundle, separators=(",", ":")) + "\n")
    if args.planner:
        import subprocess
        args.out.mkdir(parents=True, exist_ok=True)
        src = args.out / "color_graph.json"
        src.write_text(json.dumps(bundle, separators=(",", ":")) + "\n")
        results, previous = [], None
        for budget in (1, 2, 4, 8, 16):
            target = args.out / f"{budget}gb.json"
            run = subprocess.run([args.planner.resolve(), src, "mixed_soc", str(budget), target],
                                 text=True, check=True, capture_output=True)
            result = json.loads(run.stdout)
            record = next(r for r in json.loads(target.read_text()) if r["class"] == "livehd.placement.chunk_plan")
            result.update(validate_plan(bundle[0], record, budget * 10**9))
            assert previous is None or result["chunks"] <= previous
            previous = result["chunks"]
            results.append(result)
            print(json.dumps(result), flush=True)
        (args.out / "sweep.json").write_text(json.dumps(results, indent=2) + "\n")
