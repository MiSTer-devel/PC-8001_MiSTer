#!/usr/bin/env python3
"""Virtual gamepad for a MiSTer: press pad buttons from a script (testing OSD Joystick maps without a pad).

Runs on the MiSTer (python3, no modules beyond the standard library). It makes a uinput device that MiSTer Main
sees as a USB pad (VID:PID 1209:0001) and writes a button map for it into config/inputs, so the core's joystick
0 gets: dpad -> right/left/down/up, then the core's buttons in its CONF_STR J1 order (PC8001: A, B, C, Start,
Select, STOP).

  python3 mister_pad.py serve [&]        make the pad and wait for commands on the FIFO /tmp/mister_pad
  python3 mister_pad.py send CMD ...     send commands to the running pad, e.g.:
      hold right 1000      hold a button for 1000 ms
      press a              press and release (100 ms)
      down left / up left  press / release only
      wait 500             pause 500 ms
      quit                 remove the pad
  python3 mister_pad.py map              (re)write the map files only

Buttons: right left down up a b c start select stop.
From a Mac: ssh mister 'python3 /media/fat/Scripts/mister_pad.py send hold right 800 press a'
"""
import fcntl, os, struct, sys, time

FIFO = '/tmp/mister_pad'
VID, PID = 0x1209, 0x0001
NAME = b'MiSTer test pad'

EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
# dpad keys, then the core's buttons (J1 order) as gamepad buttons
BTN = {'right': 0x223, 'left': 0x222, 'down': 0x221, 'up': 0x220,
       'a': 0x130, 'b': 0x131, 'c': 0x133, 'start': 0x13b, 'select': 0x13a, 'stop': 0x134}
ORDER = ['right', 'left', 'down', 'up', 'a', 'b', 'c', 'start', 'select', 'stop']

UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_ABSBIT = 0x40045564, 0x40045565, 0x40045567
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
EVFMT = 'llHHi'     # struct input_event: timeval, type, code, value (native long: 32-bit on the DE10)


def write_map():
    # v3 map: 32 words; 0-3 directions, 4.. the core's buttons; words 24+ the analog axes (as MiSTer saves them)
    w = [0] * 32
    for i, n in enumerate(ORDER):
        w[i] = BTN[n]
    w[24:30] = [0x20000, 0x20001, 0x20003, 0x20004, 0x20000, 0x20001]
    data = struct.pack('<32I', *w)
    d = '/media/fat/config/inputs'
    os.makedirs(d, exist_ok=True)
    for f in ('input_%04x_%04x_v3.map' % (VID, PID), 'PC8001_input_%04x_%04x_v3.map' % (VID, PID)):
        with open(os.path.join(d, f), 'wb') as fh:
            fh.write(data)


def make_dev():
    fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_ABS)
    for c in BTN.values():
        fcntl.ioctl(fd, UI_SET_KEYBIT, c)
    fcntl.ioctl(fd, UI_SET_ABSBIT, 0)    # ABS_X, ABS_Y: so it reads as a joystick
    fcntl.ioctl(fd, UI_SET_ABSBIT, 1)
    # struct uinput_user_dev: name[80], id (bustype, vendor, product, version), ff_effects_max, abs max/min/fuzz/flat
    absmax = [0] * 64; absmin = [0] * 64
    absmax[0] = absmax[1] = 255
    dev = struct.pack('80sHHHHI', NAME, 0x03, VID, PID, 1, 0)
    dev += struct.pack('64i', *absmax) + struct.pack('64i', *absmin) + struct.pack('64i', *([0] * 64)) * 2
    os.write(fd, dev)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(0.5)
    for a in (0, 1):
        ev(fd, EV_ABS, a, 128)
    syn(fd)
    return fd


def ev(fd, t, c, v):
    now = time.time()
    os.write(fd, struct.pack(EVFMT, int(now), int((now % 1) * 1e6), t, c, v))


def syn(fd):
    ev(fd, EV_SYN, 0, 0)


def key(fd, name, v):
    ev(fd, EV_KEY, BTN[name], v)
    syn(fd)


def run(fd, words):
    i = 0
    while i < len(words):
        c = words[i]; i += 1
        if c == 'quit':
            return False
        if c == 'wait':
            time.sleep(int(words[i]) / 1000); i += 1
        elif c in ('hold', 'press'):
            b = words[i]; i += 1
            ms = 100
            if c == 'hold':
                ms = int(words[i]); i += 1
            key(fd, b, 1); time.sleep(ms / 1000); key(fd, b, 0); time.sleep(0.05)
        elif c in ('down', 'up') and i < len(words) and words[i] in BTN:
            key(fd, words[i], 1 if c == 'down' else 0); i += 1
        else:
            print('?', c, file=sys.stderr)
    return True


def serve():
    write_map()
    fd = make_dev()
    if not os.path.exists(FIFO):
        os.mkfifo(FIFO)
    print('pad ready', flush=True)
    go = True
    while go:
        with open(FIFO) as f:
            for line in f:
                if not run(fd, line.split()):
                    go = False
                    break
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    os.close(fd)
    os.unlink(FIFO)


if __name__ == '__main__':
    if len(sys.argv) < 2 or sys.argv[1] not in ('serve', 'send', 'map'):
        print(__doc__); sys.exit(1)
    if sys.argv[1] == 'serve':
        serve()
    elif sys.argv[1] == 'map':
        write_map()
    else:
        if not os.path.exists(FIFO):
            sys.exit('no pad: run "mister_pad.py serve" first')
        w = sys.argv[2:]
        with open(FIFO, 'w') as f:
            f.write(' '.join(w) + '\n')
        # return once the pad has done them: their total time
        t = 0
        for i, c in enumerate(w):
            if c in ('wait', 'hold') and i + 1 < len(w):
                t += int(w[i + 2 if c == 'hold' else i + 1]) + (50 if c == 'hold' else 0)
            elif c == 'press':
                t += 150
        time.sleep(t / 1000 + 0.05)
