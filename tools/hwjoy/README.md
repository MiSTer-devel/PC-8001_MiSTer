# Joystick checks on a MiSTer (virtual pad + KVMS)

`tools/mister_pad.py` runs on the MiSTer and makes a uinput pad (1209:0001) with a map file, so scripts can press
the core's joystick. These wrappers drive it with MiSTerKVMS (typing, screenshots, frames). Defaults: Mister 192
(`MISTER_SSH=mister`, `MISTER_IP`, `MISTER_STREAM`); output in `OUT` (default here).

1. `./setup.sh` (once per boot), and the core at `_Development/PC8001.rbf`.
2. `./mgl.sh "path/Game.t88" g01`: the tape and its MGL.
3. `./echo.sh g01`: at the BASIC prompt each pad input types its key (OSD Joystick Auto, the tape's map):
   `Q6482 ` then A/C keys, `9` (diagonals) or `86`. Exact check of the map.
4. Load: `./load.sh g01 60` (MON / L; for CLOAD titles type the hint with `./k type --hold 50`, `"` = `key shift+2`),
   then start with `./pad hold a 400` and `./rec.sh g01play 4 hold left 1000 press a hold right 1000`.

Seen 2026-11-22: the first pad press after a core load shows MiSTer's "Map (P1)" box for a few seconds;
keys pressed while BASIC prints an error are lost (press B = Return last); KVMS screenshots crop black borders.
