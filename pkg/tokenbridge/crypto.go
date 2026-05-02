// Package tokenbridge implements the token-bridge sidecar service.
//
// The token-bridge ingests xoxc/xoxd Slack web client tokens captured by
// a Tampermonkey userscript, encrypts them at rest with AES-256-GCM, and
// exposes them to the multiplexer for per-team child process launches.
//
// This file contains the AES-256-GCM encryption primitives.
package tokenbridge

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
)

// EncryptionKeyBytes is the required length of the raw AES-256-GCM key in bytes.
const EncryptionKeyBytes = 32

// gcmNonceBytes is the nonce length used by AES-GCM.
const gcmNonceBytes = 12

// ErrKeyLength is returned when the supplied encryption key is not exactly
// EncryptionKeyBytes bytes after base64 decoding.
var ErrKeyLength = errors.New("token encryption key must be exactly 32 bytes")

// ErrCiphertextTooShort is returned when a ciphertext is shorter than the
// nonce length plus AES-GCM authentication tag.
var ErrCiphertextTooShort = errors.New("ciphertext too short")

// Cipher holds an initialised AES-256-GCM AEAD ready to encrypt and decrypt
// xoxc/xoxd token blobs. Cipher is safe for concurrent use.
type Cipher struct {
	aead cipher.AEAD
}

// DecodeKey parses a base64-encoded 32-byte key. It returns ErrKeyLength if
// the decoded value is not exactly 32 bytes.
func DecodeKey(b64 string) ([]byte, error) {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return nil, fmt.Errorf("base64 decode: %w", err)
	}
	if len(raw) != EncryptionKeyBytes {
		return nil, ErrKeyLength
	}
	return raw, nil
}

// NewCipher constructs a Cipher from a raw 32-byte key.
func NewCipher(key []byte) (*Cipher, error) {
	if len(key) != EncryptionKeyBytes {
		return nil, ErrKeyLength
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("aes.NewCipher: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("cipher.NewGCM: %w", err)
	}
	return &Cipher{aead: aead}, nil
}

// Encrypt encrypts plaintext under the cipher's key with a fresh random
// 12-byte nonce. The returned blob is nonce || ciphertext || tag and is
// safe to store directly in a bytea column.
func (c *Cipher) Encrypt(plaintext []byte) ([]byte, error) {
	nonce := make([]byte, gcmNonceBytes)
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, fmt.Errorf("read nonce: %w", err)
	}
	// Seal appends the ciphertext+tag to its first argument. We pass nonce
	// as the prefix so the result is self-describing and decryptable
	// without out-of-band nonce storage.
	return c.aead.Seal(nonce, nonce, plaintext, nil), nil
}

// Decrypt reverses Encrypt. The input must be the exact bytes returned by
// Encrypt (nonce || ciphertext || tag).
func (c *Cipher) Decrypt(blob []byte) ([]byte, error) {
	if len(blob) < gcmNonceBytes+c.aead.Overhead() {
		return nil, ErrCiphertextTooShort
	}
	nonce := blob[:gcmNonceBytes]
	ct := blob[gcmNonceBytes:]
	pt, err := c.aead.Open(nil, nonce, ct, nil)
	if err != nil {
		return nil, fmt.Errorf("aead.Open: %w", err)
	}
	return pt, nil
}
