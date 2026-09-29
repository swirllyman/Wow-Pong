"""Writes WoWPong/Media/icon.tga: a 64x64 32-bit TGA of a Pong board (two paddles, a ball, a dashed net) for the
minimap button and the addon compartment. Run: python tools/make_icon.py"""
import os
import struct

SIZE = 64
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "WoWPong", "Media", "icon.tga")

BG, NET = (18, 18, 24, 255), (90, 90, 100, 255)
BLUE, RED, WHITE = (90, 165, 255, 255), (255, 115, 90, 255), (245, 245, 245, 255)


def main():
    px = [[BG for _ in range(SIZE)] for _ in range(SIZE)]   # px[y][x], y = 0 at the top

    def rect(x0, y0, w, h, c):
        for y in range(y0, y0 + h):
            for x in range(x0, x0 + w):
                px[y][x] = c

    for y in range(4, 60, 8):
        rect(31, y, 2, 4, NET)
    rect(8, 14, 6, 22, BLUE)
    rect(50, 28, 6, 22, RED)
    rect(38, 18, 7, 7, WHITE)
    # TGA: uncompressed true colour, 32 bpp, origin top-left (descriptor bit 5), BGRA pixels.
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 0x28)
    body = bytearray()
    for row in px:
        for r, g, b, a in row:
            body += bytes((b, g, r, a))
    with open(OUT, "wb") as fh:
        fh.write(header + body)
    print("wrote", os.path.normpath(OUT), len(header) + len(body), "bytes")


if __name__ == "__main__":
    main()
