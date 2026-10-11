#!/usr/bin/env python3
"""Window 6.3: writes the request descriptions (JSON) used by `hs-semantic-eval probe2`.

  tools/w63_specs.py [output directory]

Each description changes one thing against another one; the comments say what and why.
The production texts are read from the Swift source, so "base" is what Window 6.2 ships.
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'results/window6_3/specs')
SRC = open(os.path.join(ROOT, 'packages/HearingSenseKit/Sources/SemanticAttention/FoundationModelRelevanceReasoner.swift')).read()

def swift_text(name):
    m = re.search(r'static let ' + name + r' = """\n(.*?)\n    """', SRC, re.S)
    lines = [l[4:] if l.startswith('    ') else l for l in m.group(1).split('\n')]
    return re.sub(r' ?\\\n', ' ', '\n'.join(lines))

STAGED = swift_text('stagedInstructions')
CONFIRM = swift_text('confirmInstructions')
REPETITION = swift_text('repetitionInstructions')

KINDS = ['others', 'past', 'reported', 'hypothetical', 'noChange', 'warning', 'request', 'change', 'other']
VERDICTS = ['irrelevant', 'uncertain', 'relevant', 'urgent']
KGV = [dict(name='kind', values=KINDS), dict(name='goal', range=[0, 6]), dict(name='verdict', values=VERDICTS)]
ABOUT7 = ['hereAndNow', 'someoneElse', 'past', 'story', 'wish', 'nothingChanges', 'saidBefore']

P_BASE = "The listener's goals:\n{goals}\n?Said just before, for context only: {context}\nUtterance: {sentence}"
P_ABOUT = "The listener's goals:\n{goals}\n?About the listener: {about}\n?Said just before, for context only: {context}\nUtterance: {sentence}"
P_CHECK = "?Already said a moment ago: {earlier}\n?Said just before, for context only: {context}\nSentence: {sentence}"

specs = {}
def add(name, instructions, prompt, fields=KGV, limit=48, schema=False, prefix=None):
    specs[name] = dict(name=name, instructions=instructions, prompt=prompt, fields=fields, limit=limit,
                       schemaInPrompt=schema, prefix=prefix)

def sub(text, old, new):
    assert old in text, old[:40]
    return text.replace(old, new)

# --- Window 6.2 as shipped
add('base', STAGED, P_BASE, prefix="The listener's goals:\n{goals}\n")
add('look', CONFIRM + REPETITION, P_CHECK, fields=[dict(name='about', values=ABOUT7)], limit=16, schema=True)

# --- H1: the listener's own line is shown; nothing else changes.
add('about', STAGED, P_ABOUT)

exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'w63_variants.py')).read()) if os.path.exists(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), 'w63_variants.py')) else None

os.makedirs(OUT, exist_ok=True)
for name, spec in specs.items():
    json.dump(spec, open(os.path.join(OUT, name + '.json'), 'w'), indent=1)
print(len(specs), 'descriptions in', OUT)
