#!/usr/bin/env python3
"""Convert an Overlord Activity OA1 web export (`/oa export web`) to the dashboard's
data format (schema "overlord-activity/1", see data/schema.json).

    python3 tools/oa1_to_json.py export.txt data/activity.json [--sample] [--keep-character-names]

Privacy: the week's top player name (W record field topName) is never written, and your own
character names become "Character 1", "Character 2", ... unless --keep-character-names is given.
"""
import argparse, json, sys

def checksum(text):
    c = 0
    for b in text.encode("utf-8"):
        c = (c * 31 + b) % 16777213
    return c

def _int(s):
    return int(s) if s != "" else None

def convert(text, sample=False, keep_names=False):
    text = text.replace("\r\n", "\n").strip()
    lines = text.split("\n")
    end = lines[-1].split(",")
    if end[0] != "END":
        raise ValueError("missing END line (export truncated?)")
    if int(end[1]) != len(lines) - 1:
        raise ValueError("line count mismatch")
    if int(end[2]) != checksum("\n".join(lines[:-1]) + "\n"):
        raise ValueError("checksum mismatch (export altered or truncated)")
    head = lines[0].split(",")
    if head[0] != "OA1" or head[1] != "1":
        raise ValueError("not an OA1 version 1 export")
    generated, base, step = int(head[2]), int(head[3]), int(head[4])
    Z, C = {}, {}
    fights, zones, points = {}, {}, {}
    chars, char_idx = [], {}
    buckets, sessions = [], []
    weeks, factions, guilds, front_last = [], [], [], []
    me = victory = None
    has_weekly = False

    def fight(zi):
        z = Z[zi]
        fights.setdefault(z["key"], {"kind": z["kind"], "name": z["name"]})
        return z["key"]

    def char(ci):
        name = C[ci]
        if name not in char_idx:
            char_idx[name] = len(chars)
            chars.append(name)
        return char_idx[name]

    def pairs(field):
        return [[int(x) for x in p.split(":")] for p in field.split(";") if p]

    for ln in lines[1:-1]:
        f = ln.split(",")
        tag = f[0]
        if tag == "Z":
            Z[int(f[1])] = {"kind": f[2], "key": f[3], "name": f[4]}
        elif tag == "C":
            C[int(f[1])] = f[2]
        elif tag in ("B", "H"):
            b = {"t": base + int(f[1]) * step, "d": 900 if tag == "B" else 3600, "n": int(f[2])}
            fr = {}
            for zi, s, mx, cp in pairs(f[6]):
                fr[fight(zi)] = [s, mx, cp]
            pz = {}
            for zi, n in pairs(f[7]):
                z = Z[zi]; zones.setdefault(z["key"], z["name"]); pz[z["key"]] = n
            cps = {}
            for zi, n in pairs(f[8]):
                z = Z[zi]; points.setdefault(z["key"], z["name"]); cps[z["key"]] = n
            b["ch"] = char(int(f[3])) if f[3] else None
            b["ff"] = fight(int(f[4])) if f[4] else None
            b["hk"] = _int(f[5])
            b["f"], b["pz"], b["cp"] = fr, pz, cps
            buckets.append(b)
        elif tag == "S":
            sessions.append({"s": base + int(f[1]), "e": base + int(f[2]), "ch": char(int(f[3]))})
        elif tag == "W":
            has_weekly = True
            src = f[2]
            weeks.append({"cs": int(f[1]), "src": src, "total": int(f[3]), "players": int(f[4]),
                          "cap": None if src == "live" else int(f[5] or 0), "zones": _int(f[6]),
                          "alli": int(f[7]), "horde": int(f[8]), "topKills": int(f[9])})
            # f[10] = topName: deliberately dropped (privacy)
        elif tag == "F":
            has_weekly = True
            factions.append({"t": int(f[1]), "src": f[2], "a": int(f[3]), "h": int(f[4]), "u": _int(f[5]), "n": _int(f[6])})
        elif tag == "G":
            has_weekly = True
            guilds.append({"cs": int(f[1]), "rank": int(f[2]), "kills": int(f[3]), "faction": f[4], "name": f[5]})
        elif tag == "M":
            has_weekly = True
            me = {"cs": int(f[1]), "rank": int(f[2]), "kills": int(f[3]), "kb": _int(f[4]), "players": int(f[5])}
        elif tag == "L":
            has_weekly = True
            front_last.append({"front": fight(int(f[1])), "t": int(f[2])})
        elif tag == "V":
            has_weekly = True
            victory = {"front": fight(int(f[1])), "ally": int(f[2]), "enemy": int(f[3]), "total": int(f[4]), "faction": f[5]}
        # unknown tags are skipped (forward compatible)

    buckets.sort(key=lambda b: (b["d"] == 900, b["t"]))
    out_chars, n = [], 0
    for c in chars:
        if keep_names or c in ("multiple", "?"):
            out_chars.append(c)
        else:
            n += 1
            out_chars.append(f"Character {n}")
    weekly = None
    if has_weekly:
        weekly = {"weeks": sorted(weeks, key=lambda w: w["cs"]), "factions": factions, "guilds": guilds,
                  "me": me, "frontLast": front_last, "victory": victory}
    return {"schema": "overlord-activity/1", "sample": bool(sample), "source": "oa1", "generated": generated,
            "step": step, "names": {"fights": fights, "zones": zones, "points": points}, "chars": out_chars,
            "buckets": buckets, "sessions": sessions, "weekly": weekly}

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("export"); ap.add_argument("out")
    ap.add_argument("--sample", action="store_true", help="mark the file as sample data")
    ap.add_argument("--keep-character-names", action="store_true")
    a = ap.parse_args()
    with open(a.export, encoding="utf-8") as fh:
        data = convert(fh.read(), sample=a.sample, keep_names=a.keep_character_names)
    with open(a.out, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(data, fh, ensure_ascii=False, separators=(",", ":"))
    print(f"{a.out}: {len(data['buckets'])} buckets, {len(data['sessions'])} sessions")

if __name__ == "__main__":
    main()
