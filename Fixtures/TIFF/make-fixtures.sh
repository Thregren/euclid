#!/bin/bash
# 重新生成 TIFF 回归样本（需要 ImageMagick 的 magick 与 python3）。
#
# 样本必须由第三方写入方产出：这样自检比对的是「真实世界写出来的 TIFF」，
# 而不是我们自己写自己读。改完样本请重新跑一遍自检。
set -euo pipefail

cd "$(dirname "$0")"

# 1) 源图：32 × 32 RGBA，四周透明边框 + 内部渐变 + 4 个半透明像素。
python3 - <<'PY'
import binascii, struct, zlib

W = H = 32
pixels = bytearray()
for y in range(H):
    for x in range(W):
        if x < 4 or y < 4 or x >= W - 4 or y >= H - 4:
            pixels += bytes((0, 0, 0, 0))
        else:
            alpha = 128 if (x, y) in ((10, 10), (11, 10), (12, 10), (16, 16)) else 255
            pixels += bytes(((x * 8) & 255, (y * 8) & 255, ((x + y) * 4) & 255, alpha))

def chunk(kind, payload):
    return (struct.pack(">I", len(payload)) + kind + payload
            + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFFFFFF))

raw = b"".join(b"\x00" + bytes(pixels[y * W * 4:(y + 1) * W * 4]) for y in range(H))
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
open("base.png", "wb").write(png)
print("base.png", len(png), "字节")
PY

common=(-colorspace sRGB -type TrueColorAlpha)
magick base.png "${common[@]}" -compress None   -define tiff:rows-per-strip=8 rgba_strip_none.tif
magick base.png "${common[@]}" -compress Zip    -define tiff:predictor=2 -define tiff:tile-geometry=16x16 rgba_tile_deflate_p2.tif
magick base.png "${common[@]}" -compress LZW    -define tiff:rows-per-strip=8 rgba_strip_lzw.tif
magick base.png "${common[@]}" -compress RLE    -define tiff:rows-per-strip=8 rgba_strip_packbits.tif

# 2) 给分块 Deflate 那份注入 GeoTIFF 标签（EPSG:32650，定位点取自真实 ODM 正射影像）。
python3 - <<'PY'
import struct

source = open("rgba_tile_deflate_p2.tif", "rb").read()
assert source[:2] == b"II"
ifd_offset = struct.unpack("<I", source[4:8])[0]
count = struct.unpack("<H", source[ifd_offset:ifd_offset + 2])[0]
entries = []
for index in range(count):
    base = ifd_offset + 2 + index * 12
    tag, kind, number = struct.unpack("<HHI", source[base:base + 8])
    entries.append((tag, kind, number, source[base + 8:base + 12]))

scale = struct.pack("<3d", 0.049995, 0.049995, 0.0)
tiepoint = struct.pack("<6d", 0, 0, 0, 500000, 3000000, 0.0)
keys = [1, 1, 0, 6,
        1024, 0, 1, 1,        # GTModelTypeGeoKey：投影坐标
        1025, 0, 1, 1,        # GTRasterTypeGeoKey：PixelIsArea
        2048, 0, 1, 4326,     # GeographicTypeGeoKey：WGS 84
        2054, 0, 1, 9102,     # GeogAngularUnitsGeoKey：度
        3072, 0, 1, 32650,    # ProjectedCSTypeGeoKey：WGS 84 / UTM zone 50N
        3076, 0, 1, 9001]     # ProjLinearUnitsGeoKey：米
key_directory = struct.pack("<%dH" % len(keys), *keys)

output = bytearray(source)
def append(blob):
    offset = len(output)
    output.extend(blob)
    return offset

new_entries = list(entries) + [
    (33550, 12, 3, struct.pack("<I", append(scale))),
    (33922, 12, 6, struct.pack("<I", append(tiepoint))),
    (34735, 3, len(keys), struct.pack("<I", append(key_directory))),
]
new_entries.sort(key=lambda item: item[0])
new_ifd = len(output)
output += struct.pack("<H", len(new_entries))
for tag, kind, number, raw in new_entries:
    output += struct.pack("<HHI", tag, kind, number) + raw
output += struct.pack("<I", 0)
struct.pack_into("<I", output, 4, new_ifd)
open("geo_utm50_deflate.tif", "wb").write(bytes(output))
print("geo_utm50_deflate.tif", len(output), "字节")
PY
