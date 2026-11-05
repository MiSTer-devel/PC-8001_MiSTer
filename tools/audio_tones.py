#!/usr/bin/env python3
# Tone levels in a WAV (sim --wav, CSCP --wav, or misterkvms-cli record x.wav), to compare the mix balance:
#   tools/audio_tones.py FILE.wav START END [FREQ ...]    (seconds; default tones: 261.6 879 2400 Hz)
# Prints the rms and, per tone, the amplitude of its fundamental (FFT bins within 3%), then each tone over the last.
# The SR test tones (tools/opn_tone.txt typed in N80SR mode, then "beep 1"): FM ch 1 at 261 Hz, SSG A at 879 Hz,
# beep 2400 Hz. CSCP: FM/beep 0.80, SSG/beep 0.68.
import sys, wave
import numpy as np
p, a, b = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
freqs = [float(x) for x in sys.argv[4:]] or [261.6, 879.0, 2400.0]
w = wave.open(p); r = w.getframerate()
d = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, w.getnchannels())[:, 0].astype(float)
d = d[int(a * r):int(b * r)]; d -= d.mean()
f = np.abs(np.fft.rfft(d)) * 2 / len(d); fr = np.fft.rfftfreq(len(d), 1 / r)
amp = [np.sqrt((f[(fr > q * 0.97) & (fr < q * 1.03)] ** 2).sum()) for q in freqs]
print(f"rms {np.sqrt((d ** 2).mean()):.0f}  " + "  ".join(f"{q:.0f}Hz {x:.0f}" for q, x in zip(freqs, amp)) +
      "  ratios to last: " + " ".join(f"{x / max(amp[-1], 1e-9):.2f}" for x in amp[:-1]))
