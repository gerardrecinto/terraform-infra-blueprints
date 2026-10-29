import json, os, re, sys
root, dest = sys.argv[1], sys.argv[2]
os.makedirs(dest, exist_ok=True)
import shutil
shutil.copyfile(os.path.join(root, 'site', 'index.html'), os.path.join(dest, 'index.html'))
shutil.copyfile(os.path.join(root, 'site', 'og.png'), os.path.join(dest, 'og.png'))
out = os.path.join(dest, 'catalog.json')
def blocks(text, kw):
    """yield (labels, body) for top-level `kw "a" "b" {` blocks using brace matching"""
    for m in re.finditer(r'^' + kw + r'\s+((?:"[^"]*"\s*)+)\{', text, re.M):
        labels = re.findall(r'"([^"]*)"', m.group(1)); i = m.end(); depth = 1
        while i < len(text) and depth:
            c = text[i]
            if c == '"':
                i += 1
                while i < len(text) and text[i] != '"':
                    i += 2 if text[i] == '\\' else 1
            elif c == '{': depth += 1
            elif c == '}': depth -= 1
            i += 1
        yield labels, text[m.end():i - 1]
def clean(s): return re.sub(r'\s+', ' ', s).strip()
mods = []
for cloud in sorted(os.listdir(root)):
    cp = os.path.join(root, cloud)
    if not os.path.isdir(cp) or cloud.startswith('.') or cloud in ('docs', 'live', 'Pulumi'): continue
    for kind in ('modules', 'workflows'):
        kp = os.path.join(cp, kind)
        if not os.path.isdir(kp): continue
        for name in sorted(os.listdir(kp)):
            mp = os.path.join(kp, name)
            if not os.path.isdir(mp): continue
            tf = ''
            for f in sorted(os.listdir(mp)):
                if f.endswith('.tf'): tf += open(os.path.join(mp, f)).read() + '\n'
            if not tf: continue
            vars_ = []
            for (lab,), body in blocks(tf, 'variable'):
                d = re.search(r'description\s*=\s*"((?:[^"\\]|\\.)*)"', body) or re.search(r'description\s*=\s*<<-?(\w+)\n(.*?)\n\s*\1', body, re.S)
                t = re.search(r'^\s*type\s*=\s*(.+)$', body, re.M)
                vars_.append({'name': lab, 'desc': clean(d.group(d.lastindex if d.re.groups == 1 else 2)) if d else '', 'type': clean(t.group(1))[:40] if t else '',
                              'required': not re.search(r'^\s*default\s*=', body, re.M), 'validated': bool(re.search(r'^\s*validation\s*\{', body, re.M))})
            res = sorted({l[0] for l, _ in blocks(tf, 'resource')})
            outs = [l[0] for l, _ in blocks(tf, 'output')]
            mods.append({'cloud': cloud, 'kind': kind[:-1], 'name': name, 'path': f'{cloud}/{kind}/{name}', 'variables': vars_,
                         'resources': res, 'outputs': outs})
live = []
lp = os.path.join(root, 'live')
for dp, _, fs in os.walk(lp):
    if 'terragrunt.hcl' in fs: live.append(os.path.relpath(dp, lp))
json.dump({'modules': mods, 'live': sorted(live)}, open(out, 'w'))
v = sum(len(m['variables']) for m in mods)
print(len(mods), 'modules/workflows,', v, 'variables,', sum(x['validated'] for m in mods for x in m['variables']), 'validated,', sum(1 for m in mods for x in m['variables'] if not x['desc']), 'without description,', len(live), 'live units')
