# Window 6.3: request descriptions that were tried. Read by w63_specs.py (names from there are in scope).

GROUP_OLD = ('Something said to "you", "we", "everyone", a group the listener is part of, or to nobody in '
             'particular about here and now concerns the listener.')
OTHERS_OLD = ('others: it only tells what happened to someone else or somewhere else, and nothing follows for the '
              'listener (a friend\'s exam, a relative\'s job, another class, team, shop, flight or town, "theirs, not '
              'ours"). A sentence that names a person but changes the listener\'s own day, class, work, home or duties '
              'is not others ("Ms. Lee is ill, so our test moves", "someone is at the door", "I\'m giving her tasks to '
              'you").')
VERDICT_OLD = ('irrelevant, or uncertain when you cannot tell whether it concerns the listener or whether it is '
               'settled.')

# --- H2: whether a sentence applies to the listener is said in the instructions.
GROUP_OWN = GROUP_OLD + (' Something said to another person by name, or to a group the listener is not in (another '
                         'team, class, table, room, bus), about their own things does not concern the listener, '
                         'unless it also changes something for everyone there.')
OTHERS_OWN = ('others: it is about someone else and nothing follows for the listener: what happened to another person '
              'or somewhere else (a friend\'s exam, a relative\'s job, another class, team, shop, flight or town, '
              '"theirs, not ours"), or something said to another person by name or to a group the listener is not in, '
              'about their own things ("Tom, your order is ready" when the listener is not Tom; "team B, you start at '
              'nine" when the listener is in team A). A sentence that names a person but changes the listener\'s own '
              'day, class, work, home or duties is not others ("Ms. Lee is ill, so our test moves", "someone is at '
              'the door", "I\'m giving her tasks to you", "Tom, the whole floor closes at six").')
VERDICT_OWN = ('irrelevant, or uncertain when you cannot tell whether it concerns the listener (it is said to a named '
               'person or group, and neither the goals nor what is known about the listener tell whether that is the '
               'listener) or whether it is settled.')
OWN = sub(sub(sub(STAGED, GROUP_OLD, GROUP_OWN), OTHERS_OLD, OTHERS_OWN), VERDICT_OLD, VERDICT_OWN)
add('own', OWN, P_ABOUT)
add('own-noabout', OWN, P_BASE)
# one change at a time
add('own-group', sub(STAGED, GROUP_OLD, GROUP_OWN), P_ABOUT)
add('own-others', sub(STAGED, OTHERS_OLD, OTHERS_OWN), P_ABOUT)

# --- H3: a field of its own for whom the sentence is for, before the kind.
FOR_TEXT = ('\n\nfor, before the kind: who the sentence is for.\n'
            'me: it is said to the listener, to everyone, to a group the listener is in, or to nobody in particular; '
            'or it is said to someone else but changes something for everyone there.\n'
            'others: it is said to another person by name or to a group the listener is not in, or it is about them, '
            'and it concerns only them.\n'
            'unknown: it is said to a named person or group, and neither the goals nor what is known about the '
            'listener tell whether that is the listener.')
FOR_FIELDS = [dict(name='for', values=['me', 'others', 'unknown'])] + KGV
add('for', STAGED + FOR_TEXT, P_ABOUT, fields=FOR_FIELDS)
add('for-last', STAGED + FOR_TEXT.replace('for, before the kind:', 'for, after the verdict:'), P_ABOUT,
    fields=KGV + [dict(name='for', values=['me', 'others', 'unknown'])])

# --- Throughput: the same answer with fewer tokens to write.
JOINED = [f'{k} {g} {v}' for k in KINDS for g in range(0, 7) for v in VERDICTS]
add('joined', STAGED, P_BASE, fields=[dict(name='answer', values=JOINED)], limit=24)
specs['joined']['bare'] = True
TEXT_TAIL = ('\n\nAnswer with three words on one line and nothing else: the kind, the goal number, the verdict. '
             'For example: change 2 relevant')
add('text', STAGED + TEXT_TAIL, P_BASE, fields=None, limit=12)
SHORT = [dict(name='k', values=KINDS), dict(name='g', range=[0, 6]), dict(name='v', values=VERDICTS)]
add('short', sub(sub(sub(STAGED, 'kind, the first that fits:', 'k is the kind, the first that fits:'),
                     'goal is the number', 'g is the number'), 'verdict: urgent', 'v is the verdict: urgent'), P_BASE, fields=SHORT)
