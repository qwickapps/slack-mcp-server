package tokenbridge

import (
	"crypto/rand"
	"encoding/base64"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func newTestKey(t *testing.T) []byte {
	t.Helper()
	key := make([]byte, EncryptionKeyBytes)
	_, err := rand.Read(key)
	require.NoError(t, err)
	return key
}

func TestDecodeKey_RejectsWrongLength(t *testing.T) {
	short := base64.StdEncoding.EncodeToString(make([]byte, 16))
	_, err := DecodeKey(short)
	assert.ErrorIs(t, err, ErrKeyLength)

	long := base64.StdEncoding.EncodeToString(make([]byte, 64))
	_, err = DecodeKey(long)
	assert.ErrorIs(t, err, ErrKeyLength)
}

func TestDecodeKey_RejectsInvalidBase64(t *testing.T) {
	_, err := DecodeKey("not!valid!base64!!!")
	assert.Error(t, err)
}

func TestDecodeKey_AcceptsValid32Bytes(t *testing.T) {
	raw := newTestKey(t)
	b64 := base64.StdEncoding.EncodeToString(raw)
	out, err := DecodeKey(b64)
	require.NoError(t, err)
	assert.Equal(t, raw, out)
}

func TestNewCipher_RejectsWrongKeyLength(t *testing.T) {
	_, err := NewCipher(make([]byte, 16))
	assert.ErrorIs(t, err, ErrKeyLength)
}

func TestCipher_RoundTrip(t *testing.T) {
	c, err := NewCipher(newTestKey(t))
	require.NoError(t, err)

	plaintext := []byte("xoxc-1234567890-abcdefghijklmnopqrstuvwxyz")
	ct, err := c.Encrypt(plaintext)
	require.NoError(t, err)
	assert.NotEqual(t, plaintext, ct, "ciphertext should not equal plaintext")

	pt, err := c.Decrypt(ct)
	require.NoError(t, err)
	assert.Equal(t, plaintext, pt)
}

func TestCipher_NonceIsUniquePerEncryption(t *testing.T) {
	c, err := NewCipher(newTestKey(t))
	require.NoError(t, err)

	plaintext := []byte("same-input")
	a, err := c.Encrypt(plaintext)
	require.NoError(t, err)
	b, err := c.Encrypt(plaintext)
	require.NoError(t, err)

	// AES-GCM with random nonce must produce different ciphertexts for
	// identical plaintexts. Otherwise the nonce isn't actually random.
	assert.NotEqual(t, a, b, "two encryptions of the same plaintext must differ")

	// Also confirm the leading nonces are not equal.
	assert.NotEqual(t, a[:gcmNonceBytes], b[:gcmNonceBytes])
}

func TestCipher_TamperedCiphertextFails(t *testing.T) {
	c, err := NewCipher(newTestKey(t))
	require.NoError(t, err)

	ct, err := c.Encrypt([]byte("payload"))
	require.NoError(t, err)

	// Flip a bit in the body (past the nonce).
	ct[len(ct)-1] ^= 0x01
	_, err = c.Decrypt(ct)
	assert.Error(t, err, "GCM auth tag should reject tampered ciphertext")
}

func TestCipher_DecryptWithDifferentKeyFails(t *testing.T) {
	c1, err := NewCipher(newTestKey(t))
	require.NoError(t, err)
	c2, err := NewCipher(newTestKey(t))
	require.NoError(t, err)

	ct, err := c1.Encrypt([]byte("hello"))
	require.NoError(t, err)

	_, err = c2.Decrypt(ct)
	assert.Error(t, err, "decryption under a different key must fail")
}

func TestCipher_DecryptShortInput(t *testing.T) {
	c, err := NewCipher(newTestKey(t))
	require.NoError(t, err)

	_, err = c.Decrypt([]byte{0x01, 0x02})
	assert.ErrorIs(t, err, ErrCiphertextTooShort)
}
