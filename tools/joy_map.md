# Joystick map per game (draft, 2026-11-20)

What each tape's game reads from the keyboard, for a future OSD Joystick "Auto" (the tape table would carry the map).
Directions: **Numpad** = 8 2 4 6 (pad), **Cursor** = the cursor keys. **Fire** = the keys to put on buttons A / B / C.
Source: **screen** = the game's own instruction / title screen (CSCP, mkII N80); **scan** = tools/joy_keyscan.py: the
Z80 code's keyboard-port reads (IN A,(0-9) then BIT / AND), which also hits data bytes and reads every key a
game uses (menus, pause), so a scan row is a guess until a screen or a play confirms it.
Keys not in today's button list (Space, Return, SHIFT, Z, X, pad 0, pad 5) are marked **new key**.

## Commercial (@Commercial/80)

| Game | Directions | Fire | Other keys | Source |
|---|---|---|---|---|
| Arale no Jump Up | Numpad | Space | Return | scan |
| Bakuso! 5000 Mile | Numpad 4 / 6 steer | pad + accelerate, pad = brake (**new key**) | Return start | screen |
| Cannon Ball | Numpad 4 / 6 | Space | | screen |
| Champion Prowres Special | Numpad (+1 *) | Z, C (**new key**) | | scan |
| Dish Carrier | Numpad | Space | | screen |
| Door Door | Numpad 8 2 4 6 | A: Space (jump; user on Mister 11), B: Z / 1 (set), C: X / 3 (reset) | Return start (pad Start; Space does not start it: sim 2026-11-22) | screen + play |
| Field Wars | Numpad | Space, X | | scan |
| Fireball | Numpad | Space | | screen + scan |
| Flappy | Numpad | Space | | scan |
| Flicky | Numpad | Space | ESC, Return | scan |
| Harvest | Numpad 8 2 4 6 | Space (trigger) | | screen |
| Help! | Numpad | Space | | screen + scan |
| Itasundorious | Numpad, diagonals 7 9 1 3 | Space | | screen |
| Kaeru Shooter | Numpad 1-9 (diagonals 7 9 1 3 on its title screen) | Space (fire, start; pad 5 does not fire: Mister 192, 2026-11-22) | | screen + play |
| Kareina Kaito | Numpad | Space? | Return | scan |
| Killer Station | Numpad 4 / 6 | Space (missile) | | screen |
| Lode Runner | Numpad | ? (dig keys unclear) | many | scan: needs a look |
| Mag Force | Numpad (8 2 4 6 on screen) | Space | SHIFT | screen |
| Magnetic Field | ? | ? | | none: needs a look |
| Mister Butterfly, Gunman, Gyoza Panic, Anata wa Meikameraman | Numpad or Cursor (reads both) | Space? | | scan (shared Hudson input code) |
| MJ-05 | Numpad | Space? | | scan |
| Mystery Mountain | Numpad | Space | ESC (music on/off) | screen |
| Nintendo Tennis | Numpad | ? | | scan: needs a look |
| Pac-Man | Numpad | — | Space start | screen + scan |
| Power Fail | Numpad 8 / 2 | Space | | scan |
| Punch Ball Mario Bros. | top-row digits (**new keys**) | ? | | scan: needs a look |
| Radar Snaky | Numpad 8 / 2 | Space | Return start | screen + scan |
| Rolling Shooter | Numpad 4 / 6 | Space (beam) | ESC pause | screen |
| Saver Part-1 | top-row digits? | | | scan: needs a look |
| Sky Diver | Numpad 8 2 4 6 (+1 9) | Space | | screen |
| Star Stream | Numpad 4 / 6 | Space | | screen |
| Super Doors | top-row digits? | | | scan: needs a look |
| Vegetable Crush | Numpad 4 / 6 | Space | | screen |
| YL3 | Numpad 8 2 4 6 | Space | ESC | scan |
| Zero Fighter | Numpad 8 2 4 6 | Space | | screen |

No joystick: Geimu Kyojin no Uchu Ryoko, Star Fleet, Super Golf, Yumeno Pro Yakyu, Tomato-hime, Yonin Mahjong
(menus, typed commands, adventures). Slalom, Moon Patrol, Puckn Boy: no data yet.

## Type-ins (Danjuro's pack, machine code: scan only)

BASIC type-ins read INKEY$ (no port reads to scan); most use 2 4 6 8 and Space (their CLOAD text shows them).

| Game | Directions | Fire | Other keys | Source |
|---|---|---|---|---|
| 3D Battle Maze (PiO) | Numpad | RET SPC |  | scan |
| 60 Second Game (PiO) | ? | ? |  | scan |
| Alien Planet (PiO) | ? (+p1) | ? | GRPH | scan |
| Amoeba Attack (Technopolis) | Numpad | RET SPC | C Y N | scan |
| Armada (PiO) | Numpad | ? |  | scan |
| Asteroid Outlaw (PiO) | ? (+p1) | ? | GRPH | scan |
| Beggar Snake (I-O) | Numpad | ? |  | scan |
| Blue Fighter (Login) | Numpad | RET SPC | p* 1 2 3 4 5 | scan |
| Blue Venus (PiO) | Numpad | SPC | p* p+ p, | scan |
| Bon Bon (Konputa) (I-O) | Numpad | ? |  | scan |
| Chako Nyan (1985)(Pio)(Toshiyuki Araki) | Numpad | RET SPC SHIFT | KANA Y N | scan |
| Dot Eater | Numpad | ? |  | scan |
| Drive My PC (Popcom) | Numpad | RET SPC |  | scan |
| Dust Spurt | ? (+p7) | ? |  | scan |
| Fireman (PC Game Kessaku Senshu) | Numpad | ? |  | scan |
| Fireman II (PC Game Kessaku Senshu) | Numpad | ? |  | scan |
| Flag World (PiO) | Numpad | ? |  | scan |
| Galaxy Fly | Numpad | ? |  | scan |
| Game of Miss Ryoko (PiO) | ? | ? |  | scan |
| Ghost Gather (1984)(Pio)(Mr. Mk) | Numpad | SPC | C | scan |
| Ghost Land (PiO) | Numpad | SPC RET | S Q | scan |
| Hander (PiO) | Numpad | ? |  | scan |
| Haunted Cave (Mycomp) | Numpad | RET SPC p0 |  | scan |
| Jack Tigher (IO) | Numpad (+p1) | p0 | F1 P | scan |
| Kumo Vader (MyComp BASIC) | Numpad | ? |  | scan |
| Marine War (Bugfixed) (PiO) | Numpad | RET X SPC | A D W K L N Y | scan |
| Mikawashima Alien (PiO) | Numpad | SPC |  | scan |
| Monster House (Konputa) (I-O) | Numpad | SPC |  | scan |
| Multifighter (Popcom) | Numpad | ? |  | scan |
| Octopus (PC Game Kessaku Senshu) | Numpad | ? |  | scan |
| Othello | Numpad | ? |  | scan |
| Rocket Bomb (Konputa) | Numpad | SPC |  | scan |
| Shinsetsu Natsunojin Random Walker Fireman (PC Gam | Numpad | ? |  | scan |
| Space Alien (MyComp BASIC) | Numpad | ? |  | scan |
| Space Fighter | Numpad | SPC |  | scan |
| Stack Invader (MyComp BASIC) | ? | ? |  | scan |
| Submarine | Numpad | ? |  | scan |
| Urusei Yatsura - Only You | Numpad | ? |  | scan |
| Urusei Yatsura - Realtime Adventure | Numpad (+p1 p3) | p5 |  | scan |
| Urusei Yatsura - Typhoons are fun | Numpad | ? |  | scan |
| Warp Alien (PiO) | Numpad | X | CTRL C S | scan |
| Yurusan - YL3 (Kazutaka Nagase) | Numpad | SPC |  | scan |
| Fightan (PiO)/Fightan Data | Numpad | SPC |  | scan |
| PCG Urusei Yatsura Game (PiO)/PCG Urusei Yatsura D | Numpad (+p1 p3) | p0 p5 SPC | GRPH | scan |
| Death Fight (PiO)/Death Fight Data | ? | SHIFT SPC Z | W A D @ / ; ] | scan |
| The Prize (I-O)/The Prize Data | Numpad (+p1) | RET Z X SPC | INS | scan |
| The Prize (I-O)/The Prize Loader | Numpad | ? |  | scan |
| PCG Alien Town (PiO)/PCG Alien Town Data | Numpad | ? |  | scan |
| Tank (Technopolis)/Tank Data | Numpad | SPC |  | scan |
| Double Density (PiO)/Double Density Data | Numpad (+p1) | Z X |  | scan |
| PC-Comp (PiO)/PC-Comp Data | Numpad | SPC |  | scan |
| PC-Comp (PiO)/PC-Comp Loader | Numpad | ? |  | scan |
| Parish (PiO)/Parish Data | Numpad | RET p0 SPC | GRPH | scan |
| Galaxian (I-O)/Galaxian Data | Numpad | ? |  | scan |
| Candy Candy II (PiO)/Candy Candy II Data | Numpad | ? |  | scan |
| Urusei Yatsura Game (PiO)/Urusei Yatsura Data | Numpad (+p1 p3) | p0 p5 SPC | GRPH | scan |
| Lunar Rescue (Technopolis)/Lunar Rescue Data | ? (+p1 p3) | ? | GRPH | scan |
| Marine Alien (I-O)/Marine Data | Numpad | p0 |  | scan |
| Snake World (I-O)/Snake World Data | Numpad | X |  | scan |
| Puck Man (I-O)/Puck Man Data | Numpad | ? |  | scan |
| PCG Galaxian (I-O)/PCG Galaxian Data | Numpad | ? |  | scan |
| Attack Z80 (PiO)/Attack Z80 Data | Numpad | SPC |  | scan |
| Alien Town (PiO)/Alien Town Data | Numpad | ? |  | scan |
| Jumping Mouse (PiO)/JumpMouse Data | Numpad | SPC | S | scan |
| Star Fire (I-O)/Star Fire Data | Numpad | X SHIFT Z | F1 V | scan |
| Jigoku no Mokushiroku (I-O)/Jigoku Data | Numpad | ? |  | scan |
| Monster Revenge (PiO)/Monster Revenge Data | Numpad | SPC p5 |  | scan |
| PCG Lunar City SOS (I-O)/PCG Lunar Data | Numpad (+p1 p7) | p5 |  | scan |

## What this means for the core

- Most games: **Numpad + Space** (the OSD defaults). An Auto mode mainly has to flag the exceptions: diagonals
  (Itasundorious), Z / X (Door Door), cursor keys.
- New keys some games need on a button: pad +, pad =, C, top-row digits.
- Done: OSD Joystick Auto; tape_db.txt `joy:` lines for the 16 screen-confirmed titles above (Auto falls back
  to Numpad + the OSD buttons for the rest).
- Next: confirm the "needs a look" and scan rows by playing in CSCP, then a map field in tape_db.txt.
