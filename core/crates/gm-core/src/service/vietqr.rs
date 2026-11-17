//! Mã VietQR (chuẩn EMVCo của NAPAS) để chuyển khoản: ngân hàng (mã BIN) + số tài khoản (+ số tiền, nội dung). App ngân hàng nào
//! ở Việt Nam cũng quét được. Lõi dựng chuỗi mã và ma trận QR; app tự vẽ thẻ (tên ngân hàng, số tài khoản, số tiền) quanh mã rồi
//! gửi như ảnh. Chuyển từ Roza (`rz-core/src/vietqr.rs`).

use super::*;
use qrcode::{Color, EcLevel, QrCode};

/// Chuỗi VietQR. `amount` = 0 → mã tĩnh (người chuyển tự nhập số tiền).
pub(crate) fn payload(bin: &str, account: &str, amount: u64, note: &str) -> String {
    let bene = tlv("00", bin) + &tlv("01", account);
    let merchant = tlv("00", "A000000727") + &tlv("01", &bene) + &tlv("02", "QRIBFTTA");
    let mut s = tlv("00", "01") + &tlv("01", if amount > 0 { "12" } else { "11" }) + &tlv("38", &merchant) + &tlv("53", "704");
    if amount > 0 {
        s += &tlv("54", &amount.to_string());
    }
    s += &tlv("58", "VN");
    let note = clean_note(note);
    if !note.is_empty() {
        s += &tlv("62", &tlv("08", &note));
    }
    s += "6304";
    let crc = crc16(s.as_bytes());
    s + &format!("{crc:04X}")
}

/// Ma trận QR của `data`: `{size, bits}` — `bits` là chuỗi '1' (ô đen) / '0', hàng nối hàng.
pub(crate) fn matrix(data: &str) -> Option<Value> {
    let code = QrCode::with_error_correction_level(data.as_bytes(), EcLevel::M).ok()?;
    let bits: String = code.to_colors().iter().map(|c| if *c == Color::Dark { '1' } else { '0' }).collect();
    Some(json!({"size": code.width(), "bits": bits}))
}

/// Số tài khoản hợp lệ: 4–19 chữ / số (VietQR nhận cả tài khoản số đẹp có chữ).
pub(crate) fn valid_account(a: &str) -> bool {
    (4..=19).contains(&a.len()) && a.chars().all(|c| c.is_ascii_alphanumeric())
}

/// Bỏ dấu tiếng Việt (đ → d).
fn fold_vi(s: &str) -> String {
    const FROM: &str = "àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ";
    const TO: &str = "aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd";
    s.chars()
        .map(|c| {
            let lower = c.to_lowercase().next().unwrap_or(c);
            match FROM.chars().position(|f| f == lower) {
                Some(i) => {
                    let t = TO.chars().nth(i).unwrap_or(c);
                    if c.is_uppercase() { t.to_ascii_uppercase() } else { t }
                }
                None => c,
            }
        })
        .collect()
}

/// Nội dung chuyển khoản: bỏ dấu, chỉ chữ / số / khoảng trắng, tối đa 50 ký tự (ngân hàng không nhận ký tự lạ).
fn clean_note(note: &str) -> String {
    let s: String = fold_vi(note).chars().map(|c| if c.is_ascii_alphanumeric() { c } else { ' ' }).collect();
    s.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(50).collect()
}

fn tlv(id: &str, v: &str) -> String {
    format!("{id}{:02}{v}", v.len())
}

/// CRC-16/CCITT-FALSE (đa thức 0x1021, khởi đầu 0xFFFF) — trường 63 của EMVCo.
fn crc16(data: &[u8]) -> u16 {
    let mut crc: u16 = 0xFFFF;
    for &b in data {
        crc ^= (b as u16) << 8;
        for _ in 0..8 {
            crc = if crc & 0x8000 != 0 { (crc << 1) ^ 0x1021 } else { crc << 1 };
        }
    }
    crc
}

impl Core {
    /// `vietqr.make` {bin, account, amount?, note?} → `{payload, size, bits}`.
    pub(super) fn vietqr_make(&self, a: &Value) -> Res {
        let bin = arg_str(a, "bin")?.trim();
        let account: String = arg_str(a, "account")?.chars().filter(|c| !c.is_whitespace()).collect();
        if bin.len() != 6 || !bin.chars().all(|c| c.is_ascii_digit()) {
            return Err(CoreError::new("BAD_ARGS", "Chọn ngân hàng."));
        }
        if !valid_account(&account) {
            return Err(CoreError::new("BAD_ARGS", "Số tài khoản cần 4–19 chữ số."));
        }
        let amount = a.get("amount").and_then(Value::as_u64).unwrap_or(0);
        let note = a.get("note").and_then(Value::as_str).unwrap_or("");
        let p = payload(bin, &account, amount, note);
        let mut m = matrix(&p).ok_or_else(|| CoreError::new("QR", "Không tạo được mã QR."))?;
        m["payload"] = json!(p);
        Ok(m)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crc_check_value() {
        assert_eq!(crc16(b"123456789"), 0x29B1);
    }

    #[test]
    fn static_and_dynamic() {
        let s = payload("970436", "0011001234567", 0, "");
        assert!(s.starts_with("000201010211"));
        assert!(s.contains("0010A000000727"));
        assert!(s.contains("0006970436"));
        assert!(s.contains("01130011001234567"));
        assert!(s.contains("0208QRIBFTTA"));
        assert!(s.contains("5303704") && s.contains("5802VN"));
        let (body, crc) = s.split_at(s.len() - 4);
        assert_eq!(format!("{:04X}", crc16(body.as_bytes())), crc);

        let d = payload("970436", "0011001234567", 150000, "Trả tiền ăn trưa!");
        assert!(d.starts_with("000201010212"));
        assert!(d.contains("5406150000"));
        assert!(d.contains("0816Tra tien an trua"));
    }

    #[test]
    fn folds_vietnamese() {
        assert_eq!(fold_vi("Đặng Thị Ánh"), "Dang Thi Anh");
        assert_eq!(clean_note("Chuyển tiền — tháng 11/2026"), "Chuyen tien thang 11 2026");
    }

    #[test]
    fn qr_matrix() {
        let m = matrix(&payload("970436", "0011001234567", 0, "")).unwrap();
        let n = m["size"].as_u64().unwrap() as usize;
        assert!(n >= 21);
        assert_eq!(m["bits"].as_str().unwrap().len(), n * n);
    }
}
