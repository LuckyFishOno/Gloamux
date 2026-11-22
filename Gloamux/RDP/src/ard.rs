//! Apple Remote Desktop sign-in (VNC security type 30), which macOS Screen Sharing uses for a Mac account: a
//! Diffie-Hellman exchange whose shared secret, hashed with MD5, is the AES-128 key for the account name and password.

use aes::Aes128;
use aes::cipher::{BlockCipherEncrypt, KeyInit};
use anyhow::{Result, ensure};
use md5::{Digest, Md5};
use num_bigint::BigUint;

/// The encrypted credentials and this side's public key, in the order they are sent. `filler` pads the credentials.
pub fn response(
    generator: u16,
    prime: &[u8],
    server_key: &[u8],
    private: &[u8],
    username: &str,
    password: &str,
    filler: [u8; 128],
) -> Result<([u8; 128], Vec<u8>)> {
    let size = prime.len();
    let prime = BigUint::from_bytes_be(prime);
    let server_key = BigUint::from_bytes_be(server_key);
    let one = BigUint::from(1u8);
    ensure!(generator > 1 && prime > one, "Invalid Mac sign-in request.");
    ensure!(server_key > one && server_key < &prime - &one, "Invalid Mac sign-in request.");
    let private = BigUint::from_bytes_be(private);
    let public = BigUint::from(generator).modpow(&private, &prime);
    let shared = server_key.modpow(&private, &prime);

    let mut credentials = filler;
    for (field, value) in [(0, username), (64, password)] {
        ensure!(value.len() < 64 && !value.contains('\0'), "The Mac user name or password is too long.");
        credentials[field..field + value.len()].copy_from_slice(value.as_bytes());
        credentials[field + value.len()] = 0;
    }
    let cipher = Aes128::new_from_slice(&Md5::digest(padded(&shared, size)))
        .map_err(|_| anyhow::anyhow!("Cannot prepare Mac sign-in."))?;
    for chunk in credentials.chunks_exact_mut(16) {
        let mut block = aes::Block::try_from(&*chunk).map_err(|_| anyhow::anyhow!("Cannot prepare Mac sign-in."))?;
        cipher.encrypt_block(&mut block);
        chunk.copy_from_slice(&block);
    }
    Ok((credentials, padded(&public, size)))
}

/// Big-endian, left-padded with zeros to the key length.
fn padded(value: &BigUint, size: usize) -> Vec<u8> {
    let bytes = value.to_bytes_be();
    let mut out = vec![0; size.saturating_sub(bytes.len())];
    out.extend(bytes);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use aes::cipher::BlockCipherDecrypt;

    #[test]
    fn encrypts_the_credentials_with_the_shared_secret() {
        // p = 23, g = 5; server private 15 gives public 19; ours, 6, gives public 8. Both sides share 2.
        let mut prime = [0u8; 16];
        prime[15] = 23;
        let mut server_key = [0u8; 16];
        server_key[15] = 19;
        let filler = [0xAA; 128];
        let (secret, public) = response(5, &prime, &server_key, &[6], "cipher", "pa55", filler).unwrap();
        let mut expected_public = vec![0; 15];
        expected_public.push(8);
        assert_eq!(public, expected_public);

        let mut shared = [0u8; 16];
        shared[15] = 2;
        let cipher = Aes128::new_from_slice(&Md5::digest(shared)).unwrap();
        let mut plain = secret;
        for chunk in plain.chunks_exact_mut(16) {
            let mut block = aes::Block::try_from(&*chunk).unwrap();
            cipher.decrypt_block(&mut block);
            chunk.copy_from_slice(&block);
        }
        assert_eq!(&plain[..7], b"cipher\0");
        assert_eq!(plain[7], 0xAA);
        assert_eq!(&plain[64..69], b"pa55\0");
        assert_eq!(plain[127], 0xAA);
    }

    #[test]
    fn refuses_bad_requests() {
        let prime = [0u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 23];
        let key = |value: u8| { let mut key = [0u8; 16]; key[15] = value; key };
        assert!(response(5, &prime, &key(1), &[6], "a", "b", [0; 128]).is_err(), "trivial server key");
        assert!(response(5, &prime, &key(22), &[6], "a", "b", [0; 128]).is_err(), "p - 1 server key");
        assert!(response(1, &prime, &key(19), &[6], "a", "b", [0; 128]).is_err(), "generator 1");
        assert!(response(5, &prime, &key(19), &[6], &"a".repeat(64), "b", [0; 128]).is_err(), "long user name");
    }
}
