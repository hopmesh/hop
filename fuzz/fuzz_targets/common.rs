#![allow(dead_code)]

pub fn bounded_bytes(input: &[u8], max: usize) -> Vec<u8> {
    if let Some(encoded) = input.strip_prefix(b"hex:") {
        let digits: Vec<u8> = encoded
            .iter()
            .copied()
            .filter(|byte| !byte.is_ascii_whitespace())
            .take(max.saturating_mul(2))
            .collect();
        let mut out = Vec::with_capacity(digits.len() / 2);
        for pair in digits.chunks_exact(2) {
            let (Some(high), Some(low)) = (nibble(pair[0]), nibble(pair[1])) else {
                break;
            };
            out.push((high << 4) | low);
        }
        out
    } else {
        input[..input.len().min(max)].to_vec()
    }
}

fn nibble(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

pub fn u64_prefix(input: &[u8]) -> u64 {
    let mut bytes = [0u8; 8];
    let count = input.len().min(bytes.len());
    bytes[..count].copy_from_slice(&input[..count]);
    u64::from_le_bytes(bytes)
}
