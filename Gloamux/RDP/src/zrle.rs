//! VNC image encodings beyond Raw: CopyRect and ZRLE (RFC 6143 7.7.2 and 7.7.6). Pixels are 32-bit RGBX, and ZRLE's
//! compressed pixels are the three colour bytes.

use anyhow::{Result, bail, ensure};
use flate2::{Decompress, FlushDecompress, Status};

pub struct Image {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u8>,
}

impl Image {
    pub fn new(width: usize, height: usize) -> Self {
        Image { width, height, pixels: vec![0; width * height * 4] }
    }

    pub fn fits(&self, x: usize, y: usize, w: usize, h: usize) -> bool {
        x + w <= self.width && y + h <= self.height
    }

    /// CopyRect: the server says which part of the current image to copy. The areas may overlap.
    pub fn copy(&mut self, from_x: usize, from_y: usize, x: usize, y: usize, w: usize, h: usize) -> Result<()> {
        ensure!(self.fits(from_x, from_y, w, h) && self.fits(x, y, w, h), "Invalid VNC rectangle.");
        let mut rows = Vec::with_capacity(w * h * 4);
        for row in from_y..from_y + h {
            let start = (row * self.width + from_x) * 4;
            rows.extend_from_slice(&self.pixels[start..start + w * 4]);
        }
        for (index, row) in (y..y + h).enumerate() {
            let start = (row * self.width + x) * 4;
            self.pixels[start..start + w * 4].copy_from_slice(&rows[index * w * 4..(index + 1) * w * 4]);
        }
        Ok(())
    }

    fn put(&mut self, x: usize, y: usize, colour: [u8; 3]) {
        let start = (y * self.width + x) * 4;
        self.pixels[start..start + 3].copy_from_slice(&colour);
        self.pixels[start + 3] = 255;
    }
}

/// One zlib stream for the whole connection, as ZRLE requires.
pub struct Zrle {
    stream: Decompress,
}

impl Default for Zrle {
    fn default() -> Self {
        Zrle { stream: Decompress::new(true) }
    }
}

impl Zrle {
    /// Inflates one rectangle's data. The output is bounded by what the rectangle can hold.
    pub fn inflate(&mut self, data: &[u8], w: usize, h: usize) -> Result<Vec<u8>> {
        let tiles = w.div_ceil(64) * h.div_ceil(64);
        // Raw tiles are the largest legal form: a subencoding byte and three bytes a pixel.
        let limit = tiles + w * h * 3 + 1024;
        let mut out = Vec::with_capacity((w * h * 3 + tiles).clamp(64, limit));
        let mut consumed = 0;
        loop {
            if out.len() == out.capacity() {
                ensure!(out.capacity() < limit, "Invalid VNC compressed image.");
                out.reserve_exact(out.capacity().min(limit - out.capacity()).max(1));
            }
            let (before_in, before_out) = (self.stream.total_in(), out.len());
            let status = self
                .stream
                .decompress_vec(&data[consumed..], &mut out, FlushDecompress::Sync)
                .map_err(|_| anyhow::anyhow!("Invalid VNC compressed image."))?;
            let used = (self.stream.total_in() - before_in) as usize;
            consumed += used;
            if consumed >= data.len() && out.len() < out.capacity() {
                return Ok(out);
            }
            ensure!(status != Status::StreamEnd, "Invalid VNC compressed image.");
            // Without progress and with room left, zlib needs input the rectangle does not have.
            ensure!(used > 0 || out.len() > before_out || out.len() == out.capacity(), "Invalid VNC compressed image.");
        }
    }

    pub fn decode(&mut self, data: &[u8], image: &mut Image, x: usize, y: usize, w: usize, h: usize) -> Result<()> {
        ensure!(image.fits(x, y, w, h), "Invalid VNC rectangle.");
        let bytes = self.inflate(data, w, h)?;
        decode_tiles(&bytes, image, x, y, w, h)
    }
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Reader<'_> {
    fn byte(&mut self) -> Result<u8> {
        let value = *self.bytes.get(self.at).ok_or_else(|| anyhow::anyhow!("Invalid VNC compressed image."))?;
        self.at += 1;
        Ok(value)
    }

    fn colour(&mut self) -> Result<[u8; 3]> {
        Ok([self.byte()?, self.byte()?, self.byte()?])
    }

    fn run(&mut self) -> Result<usize> {
        let mut length = 1;
        loop {
            let part = self.byte()?;
            length += usize::from(part);
            if part != 255 {
                return Ok(length);
            }
        }
    }
}

pub fn decode_tiles(bytes: &[u8], image: &mut Image, x: usize, y: usize, w: usize, h: usize) -> Result<()> {
    let mut reader = Reader { bytes, at: 0 };
    for tile_y in (y..y + h).step_by(64) {
        let th = 64.min(y + h - tile_y);
        for tile_x in (x..x + w).step_by(64) {
            let tw = 64.min(x + w - tile_x);
            let kind = reader.byte()?;
            let at = |index: usize| (tile_x + index % tw, tile_y + index / tw);
            match kind {
                0 => {
                    for index in 0..tw * th {
                        let colour = reader.colour()?;
                        let (px, py) = at(index);
                        image.put(px, py, colour);
                    }
                }
                1 => {
                    let colour = reader.colour()?;
                    for index in 0..tw * th {
                        let (px, py) = at(index);
                        image.put(px, py, colour);
                    }
                }
                2..=16 => {
                    let palette = (0..kind).map(|_| reader.colour()).collect::<Result<Vec<_>>>()?;
                    let bits = match kind { 2 => 1, 3..=4 => 2, _ => 4 };
                    for row in 0..th {
                        let (mut byte, mut left) = (0u8, 0);
                        for column in 0..tw {
                            if left == 0 {
                                byte = reader.byte()?;
                                left = 8;
                            }
                            left -= bits;
                            let index = usize::from((byte >> left) & ((1 << bits) - 1));
                            let colour = *palette.get(index).ok_or_else(|| anyhow::anyhow!("Invalid VNC compressed image."))?;
                            image.put(tile_x + column, tile_y + row, colour);
                        }
                    }
                }
                128 => {
                    let mut index = 0;
                    while index < tw * th {
                        let colour = reader.colour()?;
                        let run = reader.run()?;
                        ensure!(index + run <= tw * th, "Invalid VNC compressed image.");
                        for offset in index..index + run {
                            let (px, py) = at(offset);
                            image.put(px, py, colour);
                        }
                        index += run;
                    }
                }
                130..=255 => {
                    let palette = (0..kind - 128).map(|_| reader.colour()).collect::<Result<Vec<_>>>()?;
                    let mut index = 0;
                    while index < tw * th {
                        let entry = reader.byte()?;
                        let run = if entry & 0x80 != 0 { reader.run()? } else { 1 };
                        let colour = *palette.get(usize::from(entry & 0x7F)).ok_or_else(|| anyhow::anyhow!("Invalid VNC compressed image."))?;
                        ensure!(index + run <= tw * th, "Invalid VNC compressed image.");
                        for offset in index..index + run {
                            let (px, py) = at(offset);
                            image.put(px, py, colour);
                        }
                        index += run;
                    }
                }
                _ => bail!("Invalid VNC compressed image."),
            }
        }
    }
    ensure!(reader.at == bytes.len(), "Invalid VNC compressed image.");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::{Compress, Compression, FlushCompress};

    fn deflate(stream: &mut Compress, data: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(data.len() + 64);
        stream.compress_vec(data, &mut out, FlushCompress::Sync).unwrap();
        out
    }

    #[test]
    fn decodes_every_tile_kind() {
        let mut image = Image::new(70, 3);
        // Two tiles across: 64×3 then 6×3.
        let mut tiles = vec![1, 10, 20, 30]; // Solid.
        tiles.extend([2, 1, 1, 1, 2, 2, 2]); // Two-colour palette, one bit a pixel, rows padded to a byte.
        tiles.extend([0b1010_1000, 0b0101_0000, 0b1111_1100]);
        let mut decoded = Image::new(70, 3);
        decode_tiles(&tiles, &mut decoded, 0, 0, 70, 3).unwrap();
        assert_eq!(&decoded.pixels[0..4], &[10, 20, 30, 255]);
        let pixel = |image: &Image, x: usize, y: usize| image.pixels[(y * 70 + x) * 4];
        assert_eq!((pixel(&decoded, 64, 0), pixel(&decoded, 65, 0), pixel(&decoded, 66, 0)), (2, 1, 2));
        assert_eq!((pixel(&decoded, 64, 1), pixel(&decoded, 65, 1)), (1, 2));
        assert_eq!(pixel(&decoded, 69, 2), 2);

        // Plain RLE over a 4×2 tile: 3 red, then 5 blue (a run byte of 4 means 5).
        let mut small = Image::new(4, 2);
        decode_tiles(&[128, 9, 0, 0, 2, 0, 0, 9, 4], &mut small, 0, 0, 4, 2).unwrap();
        assert_eq!(small.pixels[8], 9);
        assert_eq!(small.pixels[12 + 2], 9);
        // Palette RLE: index 1 for one pixel, then index 0 repeated seven times.
        decode_tiles(&[130, 5, 5, 5, 7, 7, 7, 1, 0x80, 6], &mut small, 0, 0, 4, 2).unwrap();
        assert_eq!((small.pixels[0], small.pixels[4], small.pixels[28]), (7, 5, 5));
        // Raw.
        decode_tiles(&[0, 1, 2, 3, 4, 5, 6], &mut image, 0, 0, 2, 1).unwrap();
        assert_eq!(&image.pixels[4..8], &[4, 5, 6, 255]);
        let _ = &mut image;
    }

    #[test]
    fn refuses_bad_data() {
        let mut image = Image::new(4, 4);
        assert!(decode_tiles(&[1, 0, 0], &mut image, 0, 0, 4, 4).is_err(), "truncated colour");
        assert!(decode_tiles(&[1, 0, 0, 0, 9], &mut image, 0, 0, 4, 4).is_err(), "trailing bytes");
        assert!(decode_tiles(&[50], &mut image, 0, 0, 4, 4).is_err(), "unused subencoding");
        assert!(decode_tiles(&[128, 1, 1, 1, 255, 255], &mut image, 0, 0, 4, 4).is_err(), "run past the tile");
        assert!(decode_tiles(&[130, 1, 1, 1, 2, 2, 2, 5], &mut image, 0, 0, 4, 4).is_err(), "index past the palette");
        assert!(image.copy(2, 2, 0, 0, 3, 3).is_err(), "copy from outside");
    }

    #[test]
    fn keeps_one_zlib_stream_across_rectangles() {
        let mut compressor = Compress::new(Compression::default(), true);
        let mut zrle = Zrle::default();
        let mut image = Image::new(8, 8);
        zrle.decode(&deflate(&mut compressor, &[1, 1, 2, 3]), &mut image, 0, 0, 8, 8).unwrap();
        zrle.decode(&deflate(&mut compressor, &[1, 4, 5, 6]), &mut image, 4, 4, 4, 4).unwrap();
        assert_eq!(&image.pixels[0..4], &[1, 2, 3, 255]);
        assert_eq!(&image.pixels[(7 * 8 + 7) * 4..], &[4, 5, 6, 255]);
        assert!(zrle.decode(&[1, 2, 3], &mut image, 0, 0, 8, 8).is_err());
    }

    #[test]
    fn copy_handles_overlap() {
        let mut image = Image::new(4, 1);
        for x in 0..4 { image.put(x, 0, [x as u8, 0, 0]); }
        image.copy(0, 0, 1, 0, 3, 1).unwrap();
        let reds: Vec<u8> = (0..4).map(|x| image.pixels[x * 4]).collect();
        assert_eq!(reds, vec![0, 0, 1, 2]);
    }
}
