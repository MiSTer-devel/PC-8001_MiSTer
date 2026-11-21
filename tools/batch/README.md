# Batch tape testing in CSCP (headless)

Scripts used to run a whole tape pack through the Common Source Code Project emulator and sort the results
(2026-11-19, Danjuro's packs). Results and scratch output go in `runs/` (git-ignored).

- Tape pack: `refs/software/tape_pack/80` (git-ignored). Make it from `~/Downloads/80 Type-ins.zip` plus the
  `@Commercial/80` folder of `PC88 Mister Friendly 20261119.zip`. `tools/tape_db.py --pack` uses it.
- `survey.py`: lists every tape in a pack as DB (already in tools/tape_db.txt) or NEW, with the core's own hint
  (`runs/batch/survey.txt`).
- `mkcom.py SURVEY PACK OUT [REGEX]`: one CSCP script for each NEW tape in OUT/NNN/ (MON L or CLOAD + RUN, screenshots).
- `runlst.sh DIR` (PC-8001, no disk), `runmk2n80.sh DIR` (mkII N80 mode), `runn80.sh DIR`: run one OUT/NNN.
  Run many with `ls -d OUT/* | xargs -P 8 -n 1 sh runlst.sh`.
- `blk.py`: lists a tape's files (BASIC / machine-code blocks, addresses).
- Contact sheets of the screenshots: see `runs/batch/sh_*`.
- `tools/joy_keyscan.py`: the keys each tape's code reads (for tools/joy_map.md).

The scripts expect a CSCP text font at `runs/cscp_font/font/font.txt`. It was lost with the old scratchpad:
make it again with CSCP `learn-font` (see CLI.md in ~/dev2/common_source_code).
