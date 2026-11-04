import json
import sys


def load(path):
    return {
        (str(x['datasetId']) + '|' + x['query'][:20], x['mode']): x
        for x in json.load(open(path))
        if x['strategy'] == 'hybrid'
    }


def rank(x):
    for i, t in enumerate(x['all']):
        if t in x['relevant']:
            return i + 1
    return None


r = load(sys.argv[1])
for mode in ('baseline', 'translation'):
    xs = [v for k, v in r.items() if k[1] == mode]
    n = len(xs)
    print(mode, 'n', n, 'top1', sum(v['top1'] for v in xs), 'hit3',
          sum(v['hit3'] for v in xs), 'P@3 %.3f' % (sum(v['hits'] for v in xs) / (3 * n)),
          'hitAll', sum(v['hitAll'] for v in xs))
print({k[0].split('|')[0]: rank(v) for k, v in r.items() if k[1] == 'baseline'})
