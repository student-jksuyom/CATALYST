"""Fast offline lab for fusion experiments (host only). Not shipped in the app.

Signals: e5 dense for several query variants, BM25 over article text, and
neighbour smoothing (statutes keep related provisions adjacent).
"""
import json, math, re, sys
from collections import Counter, defaultdict
import numpy as np

D = "tool/retrieval_lab"
arts = json.load(open("assets/data/legal_articles.json", encoding="utf-8"))
ids = [f"{a['Law'].lower()}:{a['Article']}" for a in arts]
laws = [a["Law"] for a in arts]
M = {m: dict(P=np.load(f"{D}/out/passages_{m}.npy"), C=np.load(f"{D}/out/chunks_{m}.npy"), Q=json.load(open(f"{D}/out/queries_{m}.json"))) for m in ("e5", "minilm")}
AN = json.load(open(f"{D}/out/analyses.json"))
OWN = np.array(json.load(open(f"{D}/out/chunk_owner.json")))
cases = json.load(open("tool/offline_eval/cases.json", encoding="utf-8"))

STOP = set("a an the and or of to in on at by for with from as is are was were be been being it its this that these those which who whom shall may can could would should will has have had do does did if but than then so such any all his her their our my your he she they we you i me us them him not no nor upon into under over between other only also article art ang ng sa na mga ko mo yung ay pa po ba lang naman kasi pero kahit si ni kay din rin daw raw mayroon".split())


def stem(w):
    if len(w) > 4 and w.endswith("ies"): return w[:-3] + "y"
    if len(w) > 5 and w.endswith("ing"): return w[:-3]
    if len(w) > 4 and w.endswith("ed"): return w[:-2]
    if len(w) > 4 and w.endswith("es"): return w[:-2]
    if len(w) > 3 and w.endswith("s") and not w.endswith("ss"): return w[:-1]
    return w


def terms(text):
    return [stem(t) for t in re.findall(r"[a-z0-9]+(?:['-][a-z0-9]+)*", text.lower()) if len(t) > 1 and t not in STOP]


class BM25:
    def __init__(self, docs, k1=1.2, b=0.75):
        self.k1, self.b = k1, b
        self.tf = [Counter(terms(d)) for d in docs]
        self.len = np.array([sum(c.values()) for c in self.tf], dtype=float)
        self.avg = self.len.mean()
        df = Counter()
        for c in self.tf: df.update(c.keys())
        n = len(docs)
        self.idf = {t: math.log(1 + (n - d + .5) / (d + .5)) for t, d in df.items()}
        self.post = defaultdict(list)
        for i, c in enumerate(self.tf):
            for t, f in c.items(): self.post[t].append((i, f))
        self.n = n

    def scores(self, query):
        s = np.zeros(self.n)
        for t in set(terms(query)):
            for i, f in self.post.get(t, ()):
                s[i] += self.idf[t] * f * (self.k1 + 1) / (f + self.k1 * (1 - self.b + self.b * self.len[i] / self.avg))
        return s


bm = BM25([a["Article Text"] for a in arts])


def chunk_scores(m, qv):
    cs = M[m]["C"] @ qv
    out = np.full(len(arts), -1.0)
    np.maximum.at(out, OWN, cs)
    return out


def rank_of(score):
    order = np.lexsort((np.arange(len(score)), -score))
    return order


def rrf(score_list, k=60, pool=50, weights=None):
    out = np.zeros(len(arts))
    for j, s in enumerate(score_list):
        w = 1.0 if weights is None else weights[j]
        for r, i in enumerate(rank_of(s)[:pool]):
            out[i] += w / (k + r + 1)
    return out


def smooth(score, radius=4, lam=0.5):
    """Add a share of the best neighbouring score (same law, adjacent rows)."""
    out = score.copy()
    for i in range(len(score)):
        lo, hi = max(0, i - radius), min(len(score), i + radius + 1)
        nb = [score[j] for j in range(lo, hi) if j != i and laws[j] == laws[i]]
        if nb: out[i] += lam * max(nb)
    return out


def dedupe(order, n):
    seen, out = set(), []
    for i in order:
        if ids[i] in seen: continue
        seen.add(ids[i]); out.append(ids[i])
        if len(out) == n: break
    return out


def pipeline(c, mode, cfg):
    q = c["query"]
    an = AN[q]
    translated = c["recordedProcessedQuery"] if mode == "translation" else q
    variants = [an["normalized"]]
    if translated != q and cfg.get("dense_translated", True): variants.append(translated)
    if an["glossary"]: variants.append(" ".join(an["glossary"]))
    sig = []
    if cfg.get("dense", True):
        for m in cfg.get("models", ["e5"]):
            for v in variants:
                qv = np.array(M[m]["Q"][v], dtype=np.float32)
                sig.append(chunk_scores(m, qv) if cfg.get("chunks") else M[m]["P"] @ qv)
    if cfg.get("bm25", True):
        sig.append(bm.scores(" ".join([q, translated] + an["glossary"])))
    w = [1.0] * len(sig)
    if cfg.get("bm25_weight") and cfg.get("bm25", True): w[-1] = cfg["bm25_weight"]
    f = rrf(sig, k=cfg.get("k", 60), pool=cfg.get("pool", 50), weights=w)
    if cfg.get("smooth"): f = smooth(f, cfg.get("radius", 4), cfg["smooth"])
    return dedupe(rank_of(f), 25)


def evaluate(cfg, verbose=False):
    res = {}
    for mode in ("baseline", "translation"):
        t1 = h3 = h10 = h25 = 0; mrr = 0.0
        for c in cases:
            rel = set(c["reviewedRelevantArticleIds"])
            r = pipeline(c, mode, cfg)
            t1 += r[0] in rel; h3 += any(x in rel for x in r[:3]); h10 += any(x in rel for x in r[:10]); h25 += any(x in rel for x in r)
            pos = [i for i, x in enumerate(r) if x in rel]
            mrr += 1 / (pos[0] + 1) if pos else 0
            if verbose: print(mode[:4], c["datasetId"], r[:5], "REL", sorted(rel), "firstrank", (pos[0] + 1) if pos else None)
        res[mode] = dict(top1=t1, hit3=h3, hit10=h10, hit25=h25, mrr=round(mrr / len(cases), 3))
    return res


if __name__ == "__main__":
    configs = {
        "e5 chunks+bm25 (all variants)": dict(chunks=True),
        "  dense w/o translation": dict(chunks=True, dense_translated=False),
        "  w/o translation, cosine order": dict(chunks=True, dense_translated=False, order_by_cosine=True),
        "  all variants, cosine order": dict(chunks=True, order_by_cosine=True),
        "  w/o translation, bm25 w2": dict(chunks=True, dense_translated=False, bm25_weight=2.0),
        "  w/o translation, k=20": dict(chunks=True, dense_translated=False, k=20),
        "  w/o translation, pool 100": dict(chunks=True, dense_translated=False, pool=100),
    }
    for name, cfg in configs.items():
        print(f"{name:34}", evaluate(cfg))
