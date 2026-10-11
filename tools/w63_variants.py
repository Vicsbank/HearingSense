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

# --- A focused second request on a sentence the first answer called relevant: who is it for?
WHO = ('A sentence was said near a person, the listener. Using what the listener wrote about themselves, say who '
       'the sentence is meant for.\n\n'
       'me: it is said to the listener (by their name, or as "you" with no other name in it), or to a group, team, '
       'class, room, table or vehicle the listener is in.\n'
       'all: it is said to everyone or to nobody in particular (an announcement, a rule, a warning, a remark), or it '
       'is said to one person but is about something everyone there shares.\n'
       'notMe: it is said to another person by name, or to a group the listener is not in, or it is about them, and '
       'it is their own business.\n'
       'unknown: it is said to a named person or group, and what the listener wrote does not tell whether that is '
       'the listener.\n\n'
       'When the sentence leans on what was said just before ("it", "that", "he"), read the two together: it is for '
       'whoever the earlier sentence was about.')
WHO4 = [dict(name='who', values=['me', 'all', 'notMe', 'unknown'])]
P_WHO = "What the listener wrote:\n{goals}\n?{about}\n?Said just before: {context}\nSentence: {sentence}"
P_WHO_ABOUT = "?About the listener: {about}\n?Said just before: {context}\nSentence: {sentence}"
add('who', WHO, P_WHO, fields=WHO4, limit=12)
specs['who']['bare'] = True
add('who-about', WHO, P_WHO_ABOUT, fields=WHO4, limit=12)
specs['who-about']['bare'] = True
add('who-schema', WHO, P_WHO, fields=WHO4, limit=16, schema=True)

# --- The second look with one more thing it can say: the sentence is cut off.
CUT = sub(CONFIRM, '\n\nMost plain announcements', '\ncutOff: the sentence stops before it has said what happens, what '
          'is wanted or what changes ("so the new time is going to be", "and then you all need to").\n\nMost plain '
          'announcements')
add('look-cut', CUT + REPETITION, P_CHECK, fields=[dict(name='about', values=ABOUT7[:6] + ['cutOff', 'saidBefore'])], limit=16,
    schema=True)
add('look-bare', CONFIRM + REPETITION, P_CHECK, fields=[dict(name='about', values=ABOUT7)], limit=12)
specs['look-bare']['bare'] = True

# --- Who is it for, grounded: first copy from the sentence whom it concerns, then compare with the listener.
WHOM = ('A sentence was said near a person, the listener. You are told what the listener wrote about themselves.\n\n'
        'whom: who has to know or do something because of the sentence, or whose things it is about. Copy the name '
        'or the group from the sentence ("Tom", "team B", "table four", "the night shift", "the staff", "my '
        'brother"). Write "you" when it speaks to someone without naming them. Write "everyone" when it is an '
        'announcement, a rule, a warning or news for whoever is there, or about something all of them share (the '
        'building, the room, the bus, the machine, the closing time).\n\n'
        'listener: is the listener that person, or one of that group?\n'
        'yes: it is "you" or "everyone"; or it is the listener\'s own name; or it is a group, team, class, room, '
        'table or vehicle the listener says they are in.\n'
        'no: it is another person\'s name, or a group other than the one the listener says they are in (another '
        'team, room, table, bus, class), or people the listener is plainly not one of.\n'
        'cannotTell: it is a name or a group, and nothing the listener wrote says whether that is them.\n\n'
        'When the sentence leans on what was said just before ("it", "that", "he"), it concerns whoever the earlier '
        'sentence was about.')
WHOM_FIELDS = [dict(name='whom', type='string'), dict(name='listener', values=['yes', 'no', 'cannotTell'])]
add('whom', WHOM, P_WHO, fields=WHOM_FIELDS, limit=32, schema=True)

# --- A sentence that calls another person by name: is it that person's own business, or news for all?
SHARED = ('A sentence was said to one person, who is called by name in it. Other people were near and heard it. '
          'Decide what it is about.\n\n'
          'theirs: it concerns that person only: their own things, their turn, their visitor, their booking, their '
          'task, a question or a request to them, a remark about them.\n'
          'everyones: it tells that person something that holds for everybody who is there: a shared room, floor, '
          'building, machine or vehicle, a time or a rule for all, a danger.')
add('shared', SHARED, "Sentence: {sentence}", fields=[dict(name='about', values=['theirs', 'everyones'])], limit=16, schema=True)
add('shared-ctx', SHARED, "?Said just before: {context}\nSentence: {sentence}", fields=[dict(name='about', values=['theirs', 'everyones'])], limit=16, schema=True)

# --- The second look reads a sentence that leans on the one before together with it.
P_CHECK_JOINED = "?Already said a moment ago: {earlier}\nSaid: {passage}"
add('look-joined', CONFIRM + REPETITION, P_CHECK_JOINED, fields=[dict(name='about', values=ABOUT7)], limit=16, schema=True)

# --- Narrow yes/no checks on a sentence the first answer called relevant.
NEWS = ('A sentence was said near a person. Decide what it does.\n\n'
        'news: it tells that something is new, different, cancelled, moved, required, forbidden, ready, waiting or '
        'about to happen; or it asks someone something, asks them to do something, or warns them.\n'
        'noNews: it says that things are as they were, that nothing has changed, that something is not happening '
        'after all, or it takes back a rumour ("still at nine", "same place as before", "no, it is not closing").\n\n'
        'A "no longer", "not allowed" or "cancelled" that changes what people must do is news.')
add('news', NEWS, "?Said just before: {context}\nSentence: {sentence}", fields=[dict(name='does', values=['news', 'noNews'])],
    limit=16, schema=True)
LITERAL = ('A sentence was said near a person. Decide how it is meant.\n\n'
           'plain: the speaker means it as it stands, about something real, now or coming.\n'
           'figure: a figure of speech, an exaggeration, a joke, sarcasm (meaning the opposite), a saying, or words '
           'quoted or retold from a film, a book, a show, a game or somebody else\'s story.')
add('literal', LITERAL, "Sentence: {passage}", fields=[dict(name='meant', values=['plain', 'figure'])], limit=16, schema=True)
