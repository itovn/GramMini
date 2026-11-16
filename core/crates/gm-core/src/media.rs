//! Tải media: ảnh trong tin (cỡ vừa cho bong bóng, cỡ lớn cho trình xem), ảnh đại diện. Tệp lưu đệm ở
//! `<dữ liệu>/media` và `<dữ liệu>/avatars`; tải xong mới đổi tên (không để tệp dở dang).

use grammers_client::media::{Document, Downloadable, Photo, PhotoSize, Sticker};
use grammers_client::tl;

/// Vị trí tệp + DC giữ tệp. `PhotoSize` của grammers không mang DC (tải sẽ hỏi DC chính → ảnh ở DC khác bị lỗi), nên
/// bọc lại kèm DC của ảnh.
pub struct Loc {
    pub loc: tl::enums::InputFileLocation,
    pub dc: Option<i32>,
    pub size: Option<usize>,
}

impl Downloadable for Loc {
    fn to_raw_input_location(&self) -> Option<tl::enums::InputFileLocation> {
        Some(self.loc.clone())
    }

    fn dc_id(&self) -> Option<i32> {
        self.dc
    }

    fn size(&self) -> Option<usize> {
        self.size
    }
}

fn dims(s: &PhotoSize) -> Option<(i32, i32)> {
    match s {
        PhotoSize::Size(x) => Some((x.width, x.height)),
        PhotoSize::Progressive(x) => Some((x.width, x.height)),
        _ => None,
    }
}

/// Kích thước gốc (cỡ lớn nhất) của ảnh.
pub fn photo_dims(p: &Photo) -> Option<(i32, i32)> {
    p.thumbs().iter().filter_map(dims).max_by_key(|(w, h)| w * h)
}

/// Ảnh mờ thu nhỏ đính sẵn trong tin (JPEG vài trăm byte) — hiện ngay trong lúc tải.
pub fn stripped(p: &Photo) -> Option<Vec<u8>> {
    p.thumbs().iter().find(|s| matches!(s, PhotoSize::Stripped(_))).and_then(|s| s.to_data())
}

/// Chọn cỡ để tải: cỡ vừa (bong bóng, ~320 px — «m», rồi «x») hoặc cỡ lớn (trình xem, ~1280 px — «y», «x», «w»).
pub fn pick(p: &Photo, big: bool) -> Option<Loc> {
    let sizes: Vec<PhotoSize> = p.thumbs().into_iter().filter(|s| s.to_raw_input_location().is_some()).collect();
    let order: &[&str] = if big { &["y", "x", "w", "m"] } else { &["m", "x", "s", "y"] };
    let chosen = order
        .iter()
        .find_map(|t| sizes.iter().find(|s| s.photo_type() == *t))
        .or_else(|| sizes.iter().max_by_key(|s| s.size()))?;
    Some(Loc { loc: chosen.to_raw_input_location()?, dc: p.dc_id(), size: Some(chosen.size()) })
}

/// Ảnh đại diện nhỏ (160 px) của một peer.
pub fn avatar_loc(peer: &grammers_session::types::PeerRef, photo_id: i64, dc: i32) -> Loc {
    Loc {
        loc: tl::enums::InputFileLocation::InputPeerPhotoFileLocation(tl::types::InputPeerPhotoFileLocation {
            big: false,
            peer: peer.into(),
            photo_id,
        }),
        dc: Some(dc),
        size: None,
    }
}

/// Sticker: tệp gốc (WebP tĩnh) hoặc ảnh thu nhỏ (sticker động TGS / video WebM — iOS 5 / 6 không phát được).
pub fn sticker_loc(s: &Sticker) -> Option<Loc> {
    let doc = &s.document;
    let mime = doc.mime_type().unwrap_or("");
    if mime == "image/webp" && !s.is_animated() {
        return Some(Loc { loc: doc.to_raw_input_location()?, dc: doc.dc_id(), size: doc.size() });
    }
    let thumbs: Vec<PhotoSize> = doc.thumbs().into_iter().filter(|t| t.to_raw_input_location().is_some()).collect();
    let t = thumbs.iter().max_by_key(|t| t.size())?;
    Some(Loc { loc: t.to_raw_input_location()?, dc: doc.dc_id(), size: Some(t.size()) })
}

/// Tệp của document (tin thoại, tệp…).
pub fn document_loc(d: &Document) -> Option<Loc> {
    Some(Loc { loc: d.to_raw_input_location()?, dc: d.dc_id(), size: d.size() })
}

/// Thuộc tính video (thời lượng, kích thước, tròn) của document.
pub fn video_attr(d: &Document) -> Option<tl::types::DocumentAttributeVideo> {
    let tl::enums::Document::Document(doc) = d.raw.document.as_ref()? else { return None };
    doc.attributes.iter().find_map(|a| match a {
        tl::enums::DocumentAttribute::Video(x) => Some(x.clone()),
        _ => None,
    })
}

/// Document có thuộc tính «Animated» (GIF Telegram đổi sang MP4).
pub fn is_gif(d: &Document) -> bool {
    let Some(tl::enums::Document::Document(doc)) = d.raw.document.as_ref() else { return false };
    doc.attributes.iter().any(|a| matches!(a, tl::enums::DocumentAttribute::Animated))
}

/// Ảnh xem trước của document (video, tệp ảnh): cỡ lớn nhất tải được.
pub fn doc_thumb_loc(d: &Document) -> Option<Loc> {
    let thumbs: Vec<PhotoSize> = d.thumbs().into_iter().filter(|t| t.to_raw_input_location().is_some()).collect();
    let t = thumbs.iter().max_by_key(|t| t.size())?;
    Some(Loc { loc: t.to_raw_input_location()?, dc: d.dc_id(), size: Some(t.size()) })
}

/// Ảnh mờ thu nhỏ đính sẵn trong document.
pub fn doc_stripped(d: &Document) -> Option<Vec<u8>> {
    d.thumbs().iter().find(|s| matches!(s, PhotoSize::Stripped(_))).and_then(|s| s.to_data())
}

/// Đuôi tệp an toàn để lưu đệm (theo tên tệp, không thì theo mime).
pub fn file_ext(d: &Document) -> String {
    let from_name = d
        .name()
        .and_then(|n| n.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()))
        .filter(|e| !e.is_empty() && e.len() <= 8 && e.chars().all(|c| c.is_ascii_alphanumeric()));
    from_name.unwrap_or_else(|| {
        match d.mime_type().unwrap_or("") {
            "video/mp4" => "mp4",
            "video/quicktime" => "mov",
            "audio/mpeg" => "mp3",
            "audio/mp4" | "audio/x-m4a" => "m4a",
            "application/pdf" => "pdf",
            "image/jpeg" => "jpg",
            "image/png" => "png",
            "text/plain" => "txt",
            _ => "bin",
        }
        .to_string()
    })
}

/// Thuộc tính âm thanh (thời lượng, dạng sóng) của document.
pub fn audio_attr(d: &Document) -> Option<tl::types::DocumentAttributeAudio> {
    let tl::enums::Document::Document(doc) = d.raw.document.as_ref()? else { return None };
    doc.attributes.iter().find_map(|a| match a {
        tl::enums::DocumentAttribute::Audio(x) => Some(x.clone()),
        _ => None,
    })
}

/// Dạng sóng Telegram: các giá trị 5 bit (0–31) xếp sát nhau (bit thấp trước).
pub fn unpack_waveform(b: &[u8]) -> Vec<u8> {
    let n = b.len() * 8 / 5;
    (0..n)
        .map(|i| {
            let bit = i * 5;
            let (byte, shift) = (bit / 8, bit % 8);
            let v = b[byte] as u16 | (*b.get(byte + 1).unwrap_or(&0) as u16) << 8;
            ((v >> shift) & 31) as u8
        })
        .collect()
}

/// Đổi ảnh WebP (sticker) sang PNG; tệp không phải WebP (ảnh thu nhỏ JPEG…) thì chép nguyên.
pub fn to_png(data: &[u8], out: &std::path::Path) -> std::io::Result<()> {
    let bad = |e: String| std::io::Error::new(std::io::ErrorKind::InvalidData, e);
    if data.len() < 12 || &data[..4] != b"RIFF" || &data[8..12] != b"WEBP" {
        return std::fs::write(out, data);
    }
    let mut dec = image_webp::WebPDecoder::new(std::io::Cursor::new(data)).map_err(|e| bad(e.to_string()))?;
    let (w, h) = dec.dimensions();
    let alpha = dec.has_alpha();
    let mut buf = vec![0u8; dec.output_buffer_size().ok_or_else(|| bad("WebP quá lớn".into()))?];
    dec.read_image(&mut buf).map_err(|e| bad(e.to_string()))?;
    let f = std::io::BufWriter::new(std::fs::File::create(out)?);
    let mut enc = png::Encoder::new(f, w, h);
    enc.set_color(if alpha { png::ColorType::Rgba } else { png::ColorType::Rgb });
    enc.set_depth(png::BitDepth::Eight);
    enc.set_compression(png::Compression::Fast);
    let mut wr = enc.write_header().map_err(|e| bad(e.to_string()))?;
    wr.write_image_data(&buf).map_err(|e| bad(e.to_string()))?;
    Ok(())
}

/// base64 (cho ảnh mờ thu nhỏ trong JSON).
pub fn base64(b: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(b.len().div_ceil(3) * 4);
    for c in b.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if c.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if c.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    out
}

#[cfg(test)]
mod tests {
    #[test]
    fn base64_known() {
        assert_eq!(super::base64(b""), "");
        assert_eq!(super::base64(b"f"), "Zg==");
        assert_eq!(super::base64(b"fo"), "Zm8=");
        assert_eq!(super::base64(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn waveform_unpack() {
        // 0b00001_00010 … : giá trị 1, 2, 3, 31 xếp 5 bit
        let vals = [1u8, 2, 3, 31];
        let mut bits: u32 = 0;
        for (i, v) in vals.iter().enumerate() {
            bits |= (*v as u32) << (i * 5);
        }
        let bytes = bits.to_le_bytes();
        assert_eq!(&super::unpack_waveform(&bytes[..3])[..4], &vals);
    }
}
