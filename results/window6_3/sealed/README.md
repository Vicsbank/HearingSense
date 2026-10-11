# Sealed set 3 — the runs of record

Run once, on 2026-10-11 between 15:17 and 16:30, with the release build of commit `1e269b8`
(`commit.txt`: the commit, a clean working tree, the checksum of the set). Six runs, each once:

| file | run |
|---|---|
| `sealed3_baselines.json` | keyword and sentence-embedding baselines |
| `sealed3_window6_3.json` | Window 6.3 as frozen, each sentence by itself, a session per sentence |
| `sealed3_window6_3_conversation.json` | the same, each sentence with the three before it in the file |
| `sealed3_window6_3_busy.json` | Window 6.3 as frozen, as it works while sentences wait |
| `sealed3_window6_2.json` | Window 6.2, each sentence by itself |
| `sealed3_window6_2_conversation.json` | Window 6.2, each sentence with the three before it |

`sealed3_table.md` (from the JSON files, `tools/w63_tables.py`) and
`sealed3_recount_without_group_rule.txt` (`tools/w63_recount.py`) hold counts only.

## What went wrong, and what it does and does not affect

While the last run was in progress I edited `tools/run_window6_3_sealed.sh` (a comment, and the new
name `window6_3_frozen` for the frozen configuration). The shell reads a script as it goes; after the
last run it read the changed file from a shifted position and began to execute its last three
commands again:

- `sealed3_window6_3_busy`: failed at once, because the frozen build does not know the new name. It
  wrote 286 bytes over `sealed3_window6_3_busy.txt` and did not touch the JSON (16:01).
- `sealed3_window6_2`: started a second run of Window 6.2. I stopped it after about three minutes,
  before it wrote anything but an empty `sealed3_window6_2.txt`. The JSON is the first run's (16:15).
- the third was never reached.

So every JSON file is the one written by the single completed run of its configuration, and every
number in the reports comes from those files. Two text reports (`…_window6_3_busy.txt`,
`…_window6_2.txt`) were lost and have been rebuilt from their JSON files; the rebuilt ones hold the
counts but not the list of wrong decisions. No configuration of Window 6.3 was run a second time on
the sealed set. The script has been left as it now reads; it refuses to run while
`sealed3_window6_3.json` exists.
