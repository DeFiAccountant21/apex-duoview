# Beta.2 layout search (throwaway, kept for provenance). Brute-forces arrangements of 1-4 whole
# 16:9 tiles on the iPhone Duo simulator's inner screen (951 x 669, fold x 456-496; laptop turned
# 669 x 951, fold y 456-496) and ranks them by screen area. The chosen layouts and their exact
# frames are in Packages/DuoCore/Tests/MultiviewTests/Fixtures/layouts-reference.json.
# Run: python3 layout_search.py
# Fit 1-4 16:9 tiles into the Duo's screen regions; rank layouts by screen area used.
import json, itertools
A = 9/16; G = 6.0
SCREEN = 951*669
def fit(W, H):  # largest 16:9 inside W x H
    w = min(W, H/A); return w, w*A
def rect(x, y, w): return (x, y, w, w*A)

def families(X, Y, W, H, m):
    """Yield (name, rects) candidates for m tiles in region (X,Y,W,H); first rect = main."""
    out = []
    if m == 0: return [("none", [])]
    if m == 1:
        w, h = fit(W, H); out.append(("one", [rect(X+(W-w)/2, Y+(H-h)/2, w)]))
        return out
    # equal row / column
    w, h = fit((W-G*(m-1))/m, H)
    tot = m*w+G*(m-1); out.append((f"row of {m}", [rect(X+(W-tot)/2+i*(w+G), Y+(H-h)/2, w) for i in range(m)]))
    w, h = fit(W, (H-G*(m-1))/m)
    tot = m*h+G*(m-1); out.append((f"column of {m}", [rect(X+(W-w)/2, Y+(H-tot)/2+i*(h+G), w) for i in range(m)]))
    if m == 4 or m == 3:
        # 2x2 grid (m=3 leaves one spot)
        w, h = fit((W-G)/2, (H-G)/2)
        tw, th = 2*w+G, 2*h+G; x0, y0 = X+(W-tw)/2, Y+(H-th)/2
        cells = [rect(x0, y0, w), rect(x0+w+G, y0, w), rect(x0, y0+h+G, w), rect(x0+w+G, y0+h+G, w)]
        if m == 4: out.append(("2 x 2 grid", cells))
        else: out.append(("2 + 1 (pyramid)", [rect(X+(W-w)/2, y0, w) if False else cells[0], cells[1], rect(X+(W-w)/2, y0+h+G, w)]))
    # main + rest below (rest in a row), main + rest beside (rest in a column): sweep main width
    k = m-1
    for steps in range(1, 400):
        pass
    best = {}
    for i in range(1, 401):
        mw = W*i/400
        mh = mw*A
        if mh > H: break
        # below
        rh = H-mh-G
        if rh > 0:
            sw, sh = fit((W-G*(k-1))/k, rh)
            if sw > 0:
                tot = k*sw+G*(k-1); th = mh+G+sh; y0 = Y+(H-th)/2
                rs = [rect(X+(W-mw)/2, y0, mw)] + [rect(X+(W-tot)/2+j*(sw+G), y0+mh+G, sw) for j in range(k)]
                a = sum(r[2]*r[3] for r in rs)
                if a > best.get("below", (0,))[0]: best["below"] = (a, rs)
        # beside
        rw = W-mw-G
        if rw > 0:
            sw, sh = fit(rw, (H-G*(k-1))/k)
            if sw > 0:
                tot = k*sh+G*(k-1); tw = mw+G+sw; x0 = X+(W-tw)/2
                mh2 = mh; my = Y+(H-mh2)/2; sy = Y+(H-tot)/2
                rs = [rect(x0, my, mw)] + [rect(x0+mw+G, sy+j*(sh+G), sw) for j in range(k)]
                a = sum(r[2]*r[3] for r in rs)
                if a > best.get("beside", (0,))[0]: best["beside"] = (a, rs)
        # m=4: L shape: main top-left, one beside it (column of 1..2), rest below
        if m == 4 and rw > 0 and rh > 0:
            sw1, sh1 = fit(rw, mh)  # one beside
            sw, sh = fit((W-G*1)/2, rh)  # two below
            if sw1 > 0 and sw > 0:
                th = mh+G+sh
                y0 = Y+(H-th)/2
                rs = [rect(X, y0, mw), rect(X+mw+G, y0, sw1), rect(X, y0+mh+G, sw), rect(X+sw+G, y0+mh+G, sw)]
                a = sum(r[2]*r[3] for r in rs)
                if a > best.get("L", (0,))[0]: best["L"] = (a, rs)
    names = {"below": f"main + {k} below", "beside": f"main + {k} beside", "L": "main + 1 beside + 2 below"}
    for key, (a, rs) in best.items(): out.append((names[key], rs))
    return out

MIN_W = 200
def area(rs): return sum(r[2]*r[3] for r in rs) if all(r[2] >= MIN_W - 0.01 for r in rs) else 0

results = {}
# FLAT: one region
for n in range(1, 5):
    cands = [(nm, rs) for nm, rs in families(6, 6, 939, 657, n)]
    results[("flat", n)] = sorted(cands, key=lambda c: -area(c[1]))
# BOOK: halves left (6..450) and right (502..945); split counts
L, R = (6, 6, 444, 657), (502, 6, 443, 657)
for n in range(1, 5):
    cands = []
    for k in range(0, n+1):
        for (ln, lr) in families(*L, k):
            for (rn, rr) in families(*R, n-k):
                if k == 0 and n > 0 and not rr: continue
                cands.append((f"left: {ln} | right: {rn}", lr+rr))
    # across the fold: main uses the whole screen
    w, h = fit(939, 657); cands.append(("across the fold (others hidden)", [rect(6+(939-w)/2, 6+(657-h)/2, w)]))
    best = {}
    for nm, rs in cands:
        if len(rs) != n and not nm.startswith("across"): continue
        best[nm] = rs
    results[("book", n)] = sorted(best.items(), key=lambda c: -area(c[1]))
# LAPTOP: turned screen 669x951; top (6,6,657,444), bottom (6,502,657,443): main on top, rest below
for n in range(1, 5):
    cands = []
    for (tn, tr) in families(6, 6, 657, 444, 1):
        for (bn, br) in families(6, 502, 657, 443, n-1):
            cands.append((f"top: main | below: {bn}", tr+br))
    if n >= 2:
        for (tn, tr) in families(6, 6, 657, 444, 2):
            for (bn, br) in families(6, 502, 657, 443, n-2):
                cands.append((f"top: {tn} | below: {bn}", tr+br))
    results[("laptop", n)] = sorted(dict(cands).items(), key=lambda c: -area(c[1]))

summary = {}
for (p, n), cands in results.items():
    rows = []
    seen = set()
    for nm, rs in cands:
        pct = round(100*area(rs)/SCREEN, 1)
        if nm in seen or pct == 0: continue
        seen.add(nm)
        rows.append({"name": nm, "pct": pct, "main_w": round(rs[0][2], 1) if rs else 0, "rects": [[round(v, 1) for v in r] for r in rs]})
    summary[f"{p}-{n}"] = rows[:5]
    print(f"\n{p.upper()} {n} feed(s):")
    for r in rows[:5]: print(f"  {r['pct']:5.1f}%  main {r['main_w']:6.1f} wide   {r['name']}")
json.dump(summary, open("layout_search_results.json", "w"), indent=1)
