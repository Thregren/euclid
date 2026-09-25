# TIFF 解码的回归样本

这里的文件由 **libtiff**（经 ImageMagick 与 `tiffset`）写出，用来给自检程序当参照：
对照方是真正的 TIFF 写入方，而不是我们自己的编码器，因此能挡住「自己写自己读」的假通过。
自检会把每个文件解出来的像素与 `base.png`（用 `ImageIO` 读）逐点比对。

源图 `base.png`：32 × 32 的 RGBA 位图，四周 4 像素透明边框，内部是渐变，
另有 4 个 alpha = 128 的半透明像素（用来核对预乘 alpha 的处理）。

| 文件 | 布局 | 压缩 | 考的是 |
| --- | --- | --- | --- |
| `rgba_strip_none.tif` | 横条（每 8 行一条） | 未压缩 | 横条读取、越界补齐、RGBA |
| `rgba_tile_deflate_p2.tif` | 分块 16 × 16 | AdobeDeflate + Predictor 2 | 分块表、zlib 解压、水平差分还原 |
| `rgba_strip_lzw.tif` | 横条（每 8 行一条） | LZW + Predictor 2 | LZW 码表与位宽增长的时机 |
| `rgba_strip_packbits.tif` | 横条（每 8 行一条） | PackBits | RLE 解码 |
| `geo_utm50_deflate.tif` | 分块 16 × 16 | AdobeDeflate + Predictor 2 | GeoTIFF 标签与 EPSG:32650 的定位 |

## 复现方式

```bash
./Fixtures/TIFF/make-fixtures.sh      # 需要 magick（ImageMagick）与 python3
```

`geo_utm50_deflate.tif` 的定位点取 **UTM 50N 中央经线上的整数格点**
（东坐标 500000 = 117°E 中央经线本身、北坐标 4500000、5 cm/像素），刻意与任何真实测区无关；
脚本把定位点、像素尺度与 GeoKey（EPSG:32650）一起注入 IFD，
自检里用 PROJ 算出的四角坐标当基准。
