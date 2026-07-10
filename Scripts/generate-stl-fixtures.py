#!/usr/bin/env python3
"""Generates the checked-in STL parser fixtures in Tests/WireframeCoreTests/Resources/.

Deterministic output — rerunning must produce byte-identical files.
Geometry matches Fixtures.cube() (unit cube, corner at origin, outward winding).
"""

import struct
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "Tests" / "WireframeCoreTests" / "Resources"
OUT.mkdir(parents=True, exist_ok=True)

CORNERS = [
    (0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0),
    (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1),
]
TRIANGLES = [
    (0, 2, 1), (0, 3, 2),   # bottom -Z
    (4, 5, 6), (4, 6, 7),   # top    +Z
    (0, 1, 5), (0, 5, 4),   # front  -Y
    (3, 7, 6), (3, 6, 2),   # back   +Y
    (0, 4, 7), (0, 7, 3),   # left   -X
    (1, 2, 6), (1, 6, 5),   # right  +X
]


def normal(a, b, c):
    u = [b[i] - a[i] for i in range(3)]
    v = [c[i] - a[i] for i in range(3)]
    n = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]
    length = sum(x * x for x in n) ** 0.5
    return [x / length for x in n]


def binary_cube() -> bytes:
    header = b"WireframeKit binary cube fixture".ljust(80, b"\0")
    body = [header, struct.pack("<I", len(TRIANGLES))]
    for tri in TRIANGLES:
        a, b, c = (CORNERS[i] for i in tri)
        body.append(struct.pack("<12fH", *normal(a, b, c), *a, *b, *c, 0))
    return b"".join(body)


def ascii_cube() -> bytes:
    lines = ["solid cube"]
    for tri in TRIANGLES:
        a, b, c = (CORNERS[i] for i in tri)
        n = normal(a, b, c)
        lines.append(f"  facet normal {n[0]:e} {n[1]:e} {n[2]:e}")
        lines.append("    outer loop")
        for p in (a, b, c):
            lines.append(f"      vertex {p[0]:e} {p[1]:e} {p[2]:e}")
        lines.append("    endloop")
        lines.append("  endfacet")
    lines.append("endsolid cube")
    return ("\n".join(lines) + "\n").encode()


binary = binary_cube()
(OUT / "cube-binary.stl").write_bytes(binary)
(OUT / "cube-ascii.stl").write_bytes(ascii_cube())
# Header claims 12 triangles but the data stops mid-triangle 6.
(OUT / "truncated-binary.stl").write_bytes(binary[: 84 + 50 * 5 + 25])
# Not ASCII ("solid" absent), and bytes 80..84 decode to a huge triangle count.
(OUT / "garbage.stl").write_bytes(bytes((i * 37 + 11) % 251 for i in range(200)))

for f in sorted(OUT.iterdir()):
    print(f"{f.name}: {f.stat().st_size} bytes")
