#!/usr/bin/env python3
"""生成浮点 GeoTIFF 回归样本（dem_f32_p3.tif / rgb_f32_planar.tif）。

为什么不用 libtiff 的 tiffcp 转：它会把 GeoTIFF 标签（33550/33922/34735…）整组丢掉，
而且我们需要的「浮点 + Predictor 3 + 分离平面」这套组合，tiffcp 从横条转分块时不稳。
所以这里自己按 TIFF 规范写，写完再用 libtiff 读回来验证（见 make-fixtures.sh）。

Predictor 3 的编码口径（libtiff 的 `fpDiff`，与 `fipAcc` 互为逆运算）：
1. 按行取一条记录（一条记录 = 一个块行），把每个样本按字节拆开重排成字节平面，
   小端文件把**最高位**那一片排在最前（大端相反）；
2. 在重排后的记录里做**按字节累加**：第 i 个字节加上第 i-1 个字节（不进位）。
自检里对着 libtiff 自己写出的同构文件逐字节比过（见 Sources/TileKitCheck/main.swift）。
"""

import math
import struct
import sys
import zlib

W, H = 600, 400
TILE_W, TILE_H = 256, 256


def encode_predictor3(record: bytes, samples_per_row: int, bytes_per_sample: int) -> bytes:
    """按 libtiff 的 fpDiff 编码一条记录（一个块行）。"""
    row_bytes = samples_per_row * bytes_per_sample
    assert len(record) == row_bytes, (len(record), row_bytes)
    planes = bytearray(row_bytes)
    for sample in range(samples_per_row):
        for byte in range(bytes_per_sample):
            # 小端：平面 0 = 最高位字节。
            plane = bytes_per_sample - 1 - byte
            planes[plane * samples_per_row + sample] = record[sample * bytes_per_sample + byte]
    for index in range(row_bytes - 1, 0, -1):
        planes[index] = (planes[index] - planes[index - 1]) & 0xFF
    return bytes(planes)


def encode_tile(row_major: bytes, width: int, height: int, samples_per_pixel: int) -> bytes:
    """一块（连续存放）的样本字节 → 编码后的块字节。"""
    bytes_per_sample = 4
    samples_per_row = width * samples_per_pixel
    row_bytes = samples_per_row * bytes_per_sample
    out = bytearray()
    for row in range(height):
        start = row * row_bytes
        out += encode_predictor3(row_major[start:start + row_bytes], samples_per_row, bytes_per_sample)
    return bytes(out)


def encode_plane_tile(plane_rows, tile_x: int, samples_per_pixel: int) -> bytes:
    """分离平面的一块：一行就是 tile_w 个样本。"""
    out = bytearray()
    for row in plane_rows:
        out += encode_predictor3(row, TILE_W, 4)
    return bytes(out)


def write_tiff(path: str, width: int, height: int, samples_per_pixel: int, planar: int,
               photometric: int, tiles: list, geotags: bool):
    """按块写出一个 Deflate + Predictor 3 的浮点 TIFF。"""
    compressed = [zlib.compress(blob, 6) for blob in tiles]
    tile_count = len(compressed)

    # 布局：文件头 → 块数据 → 外部值 → IFD（IFD 放最后，偏移写回文件头）。
    data_offset = 8
    offsets = []
    cursor = data_offset
    for blob in compressed:
        offsets.append(cursor)
        cursor += len(blob)
        if cursor % 2:
            cursor += 1
    blocks_end = cursor

    def external(payload: bytes) -> int:
        nonlocal blocks_end
        offset = blocks_end
        blocks_end += len(payload) + (len(payload) % 2)
        return offset

    bits = struct.pack("<%dH" % samples_per_pixel, *([32] * samples_per_pixel))
    formats = struct.pack("<%dH" % samples_per_pixel, *([3] * samples_per_pixel))
    scale = struct.pack("<3d", 0.5, 0.5, 0.0)
    tiepoint = struct.pack("<6d", 0, 0, 0, 500_000.0, 2_800_000.0, 0.0)
    keys = [1, 1, 0, 6,
            1024, 0, 1, 1,       # GTModelTypeGeoKey：投影坐标
            1025, 0, 1, 1,       # GTRasterTypeGeoKey：PixelIsArea
            2048, 0, 1, 4326,    # GeographicTypeGeoKey：WGS 84
            2054, 0, 1, 9102,    # GeogAngularUnitsGeoKey：度
            3072, 0, 1, 32650,   # ProjectedCSTypeGeoKey：WGS 84 / UTM zone 50N
            3076, 0, 1, 9001]    # ProjLinearUnitsGeoKey：米
    key_directory = struct.pack("<%dH" % len(keys), *keys)
    ascii_tags = b"WGS 84 / UTM zone 50N|\x00"

    # tag → (类型, 个数, 值字节)；值超过 4 字节的排到外部值区。
    fields = {
        256: (4, 1, struct.pack("<I", width)),
        257: (4, 1, struct.pack("<I", height)),
        258: (3, samples_per_pixel, bits),
        259: (3, 1, struct.pack("<H", 8)),
        262: (3, 1, struct.pack("<H", photometric)),
        274: (3, 1, struct.pack("<H", 1)),
        277: (3, 1, struct.pack("<H", samples_per_pixel)),
        284: (3, 1, struct.pack("<H", planar)),
        317: (3, 1, struct.pack("<H", 3)),
        322: (3, 1, struct.pack("<H", TILE_W)),
        323: (3, 1, struct.pack("<H", TILE_H)),
        324: (4, tile_count, struct.pack("<%dI" % tile_count, *offsets)),
        325: (4, tile_count, struct.pack("<%dI" % tile_count, *[len(b) for b in compressed])),
        339: (3, samples_per_pixel, formats),
    }
    if geotags:
        fields[33550] = (12, 3, scale)
        fields[33922] = (12, 6, tiepoint)
        fields[34735] = (3, len(keys), key_directory)
        fields[34737] = (2, len(ascii_tags), ascii_tags)

    inline = {}
    payloads = {}
    for tag, (kind, count, payload) in fields.items():
        if len(payload) <= 4:
            inline[tag] = (kind, count, payload.ljust(4, b"\x00"))
        else:
            offset = external(payload)
            inline[tag] = (kind, count, struct.pack("<I", offset))
            payloads[offset] = payload

    tags = sorted(inline)
    ifd_size = 2 + len(tags) * 12 + 4
    ifd_offset = blocks_end
    output = bytearray(b"II" + struct.pack("<HI", 42, ifd_offset))
    for blob in compressed:
        output += blob
        if len(output) % 2:
            output += b"\x00"
    for offset in sorted(payloads):
        if len(output) > offset:
            raise AssertionError("外部值区重叠")
        if len(output) < offset:
            output += b"\x00" * (offset - len(output))
        output += payloads[offset]
        if len(output) % 2:
            output += b"\x00"
    if len(output) > ifd_offset:
        raise AssertionError("IFD 位置算出错了")
    output += b"\x00" * (ifd_offset - len(output))
    output += struct.pack("<H", len(tags))
    for tag in tags:
        kind, count, raw = inline[tag]
        output += struct.pack("<HHI", tag, kind, count) + raw
    output += struct.pack("<I", 0)
    assert len(output) == ifd_offset + ifd_size, (len(output), ifd_offset + ifd_size)
    with open(path, "wb") as handle:
        handle.write(bytes(output))
    print("%s：%d × %d，%d 块，%d 字节" % (path, width, height, tile_count, len(output)))


def dem_elevation(x: int, y: int) -> float:
    """自检里用的解析式；文件第 0 行对应 y = H。"""
    dx, dy = x - 300.0, y - 200.0
    bump = 200.0 * math.exp(-(dx * dx + dy * dy) / (2 * 60 * 60))
    return 100.0 + 50.0 * math.sin(x / 80.0) * math.cos(y / 60.0) + bump


def build_dem(path: str):
    across = (W + TILE_W - 1) // TILE_W
    down = (H + TILE_H - 1) // TILE_H
    values = [[dem_elevation(x, H - row) for x in range(W)] for row in range(H)]
    tiles = []
    for tile_y in range(down):
        for tile_x in range(across):
            buffer = bytearray(TILE_W * TILE_H * 4)
            for row in range(TILE_H):
                y = tile_y * TILE_H + row
                if y >= H:
                    break
                for column in range(TILE_W):
                    x = tile_x * TILE_W + column
                    if x >= W:
                        continue
                    struct.pack_into("<f", buffer, (row * TILE_W + column) * 4, values[y][x])
            tiles.append(encode_tile(bytes(buffer), TILE_W, TILE_H, 1))
    write_tiff(path, W, H, 1, 1, 1, tiles, geotags=True)


def build_planar(path: str):
    across = (W + TILE_W - 1) // TILE_W
    down = (H + TILE_H - 1) // TILE_H
    bands = [
        [[0.10 + 0.30 * (x / W) for x in range(W)] for _ in range(H)],
        [[0.20 + 0.30 * (row / H) for _ in range(W)] for row in range(H)],
        [[0.50 + 0.20 * math.sin(x / 50.0) for x in range(W)] for _ in range(H)],
    ]
    tiles = []
    for band in bands:
        for tile_y in range(down):
            for tile_x in range(across):
                rows = []
                for row in range(TILE_H):
                    y = tile_y * TILE_H + row
                    line = bytearray(TILE_W * 4)
                    if y < H:
                        for column in range(TILE_W):
                            x = tile_x * TILE_W + column
                            if x < W:
                                struct.pack_into("<f", line, column * 4, band[y][x])
                    rows.append(bytes(line))
                tiles.append(encode_plane_tile(rows, tile_x, 1))
    write_tiff(path, W, H, 3, 2, 2, tiles, geotags=True)


if __name__ == "__main__":
    base = sys.argv[1] if len(sys.argv) > 1 else "."
    build_dem(base + "/dem_f32_p3.tif")
    build_planar(base + "/rgb_f32_planar.tif")
