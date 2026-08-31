#!/usr/bin/env python3
"""Generate the cochlea brand marks.

The mark is a logarithmic spiral because that is literally what a cochlea is —
the spiral cavity of the inner ear. It also reads as a decaying waveform, which
is the other half of what this app does.

The geometry is computed rather than drawn so it can be regenerated at any size
and so the taper, the coil spacing and the optical centring are derived instead
of eyeballed.
"""

import math
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "Resources" / "logo"

TURNS = 2.05        # enough coils to read as a cochlea, few enough to stay open
DECAY = 1.62        # how tightly it winds inward
THICKNESS = 0.38    # ribbon width as a fraction of the local radius
STEPS = 720


def _spiral_points(radius, thickness, turns, decay, steps, start_angle):
    theta_max = turns * 2 * math.pi
    outer, inner = [], []
    for i in range(steps + 1):
        s = i / steps
        r = radius * math.exp(-decay * theta_max * s / theta_max * 1.0) \
            if False else radius * math.exp(-decay * s)
        w = thickness * r * (1.0 - s) ** 0.35   # taper only near the apex
        a = start_angle + theta_max * s
        nx, ny = math.cos(a), math.sin(a)
        outer.append((nx * (r + w / 2), ny * (r + w / 2)))
        inner.append((nx * (r - w / 2), ny * (r - w / 2)))
    return outer, inner


def coil_gap(turns=TURNS, decay=DECAY, thickness=THICKNESS):
    """Gap between adjacent coils, as a fraction of local radius.

    The pitch of a logarithmic spiral is itself proportional to radius, so a
    ribbon whose width is a fixed fraction of radius keeps a constant visual
    gap. If this ever goes negative the coils merge into a blob.
    """
    pitch = 1.0 - math.exp(-decay * 2 * math.pi / (turns * 2 * math.pi))
    return pitch - thickness


def ribbon(cx, cy, extent, *, thickness=THICKNESS, turns=TURNS, decay=DECAY,
           steps=STEPS, start_angle=-math.pi / 2):
    """A tapered spiral ribbon, optically centred, fitted to `extent`.

    A spiral winds inward, so its mass sits off the geometric centre of its
    own coordinate system. The path is fitted to its bounding box and then
    centred on (cx, cy), which is what stops the mark looking as though it has
    slipped in the frame.
    """
    if coil_gap(turns, decay, thickness) <= 0:
        raise ValueError(
            f"coils would merge: gap={coil_gap(turns, decay, thickness):.3f}; "
            "reduce thickness or turns")

    outer, inner = _spiral_points(1.0, thickness, turns, decay, steps, start_angle)
    pts = outer + inner
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    minx, maxx, miny, maxy = min(xs), max(xs), min(ys), max(ys)
    scale = (2 * extent) / max(maxx - minx, maxy - miny)
    ox = (minx + maxx) / 2 * scale
    oy = (miny + maxy) / 2 * scale

    def place(p):
        return (cx + p[0] * scale - ox, cy + p[1] * scale - oy)

    O = [place(p) for p in outer]
    I = [place(p) for p in inner]
    cap_radius = math.hypot(O[0][0] - I[0][0], O[0][1] - I[0][1]) / 2
    head = f"M {I[0][0]:.2f} {I[0][1]:.2f}"
    cap = f"A {cap_radius:.2f} {cap_radius:.2f} 0 0 0 {O[0][0]:.2f} {O[0][1]:.2f}"
    fwd = " ".join(f"L {x:.2f} {y:.2f}" for x, y in O[1:])
    back = " ".join(f"L {x:.2f} {y:.2f}" for x, y in reversed(I[1:]))
    return f"{head} {cap} {fwd} {back} Z"


def write(name: str, svg: str) -> Path:
    path = OUT / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(svg.strip() + "\n")
    return path


# --- the bare mark, monochrome -----------------------------------------------
# macOS menu bar icons must be template images: solid shapes plus alpha, which
# the system tints for light, dark and the highlighted state. Any colour here
# would be discarded, so there is none.
write("mark.svg", f"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" role="img" aria-label="cochlea">
  <title>cochlea</title>
  <path d="{ribbon(32, 32, 29)}" fill="currentColor"/>
</svg>
""")

# --- the app icon ------------------------------------------------------------
# 1024 canvas with a 228 corner radius is the macOS Big Sur+ squircle
# proportion; the mark occupies ~80% of the canvas, which is the icon grid's
# guidance for a circular motif.
write("icon.svg", f"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="cochlea">
  <title>cochlea</title>
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#1B2534"/>
      <stop offset="1" stop-color="#090D13"/>
    </linearGradient>
    <linearGradient id="spiral" x1="0.1" y1="0.05" x2="0.8" y2="1">
      <stop offset="0" stop-color="#FFFFFF"/>
      <stop offset="0.5" stop-color="#CDEBFB"/>
      <stop offset="1" stop-color="#6FC9F5"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" rx="228" ry="228" fill="url(#bg)"/>
  <path d="{ribbon(512, 512, 408)}" fill="url(#spiral)"/>
</svg>
""")

# --- wordmark, for the README ------------------------------------------------
write("wordmark.svg", f"""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 470 116" role="img" aria-label="cochlea">
  <title>cochlea</title>
  <path d="{ribbon(58, 58, 46)}" fill="currentColor"/>
  <text x="134" y="77" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', Inter, Helvetica, Arial, sans-serif"
        font-size="64" font-weight="600" letter-spacing="-2" fill="currentColor">cochlea</text>
</svg>
""")

print(f"coil gap: {coil_gap():.3f} of local radius (must be > 0)")
print("wrote:", ", ".join(sorted(p.name for p in OUT.glob("*.svg"))))
