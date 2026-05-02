package tokenbridge

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"time"
)

// SignatureHeader is the HTTP header that carries the hex-encoded
// HMAC-SHA256 of the raw request body.
const SignatureHeader = "X-Bridge-Signature"

// NonceHeader is the HTTP header that carries the request nonce, which
// must equal the body's `nonce` field. This is defence-in-depth so a
// reused signature on a different transport cannot be replayed silently.
const NonceHeader = "X-Bridge-Nonce"

// DefaultReplayWindow is the maximum age allowed for a refresh request,
// based on the captured_at timestamp the userscript reports.
const DefaultReplayWindow = 5 * time.Minute

// ErrInvalidSignature is returned when an HMAC signature fails verification.
var ErrInvalidSignature = errors.New("invalid HMAC signature")

// ErrNonceMismatch is returned when the X-Bridge-Nonce header doesn't
// match the body's nonce field.
var ErrNonceMismatch = errors.New("nonce header does not match body")

// ErrReplay is returned when captured_at is too far in the past or future.
var ErrReplay = errors.New("captured_at outside replay window")

// ComputeSignature returns the hex-encoded HMAC-SHA256 of body under key.
func ComputeSignature(key, body []byte) string {
	mac := hmac.New(sha256.New, key)
	mac.Write(body)
	return hex.EncodeToString(mac.Sum(nil))
}

// VerifySignature returns nil iff providedHex is a valid hex-encoded
// HMAC-SHA256 of body under key. Comparison is constant-time.
func VerifySignature(key, body []byte, providedHex string) error {
	provided, err := hex.DecodeString(providedHex)
	if err != nil {
		return ErrInvalidSignature
	}
	mac := hmac.New(sha256.New, key)
	mac.Write(body)
	expected := mac.Sum(nil)
	if !hmac.Equal(expected, provided) {
		return ErrInvalidSignature
	}
	return nil
}

// CheckReplayWindow returns nil iff capturedAt is within window of now in
// either direction. Clock skew of a few seconds is tolerated by virtue of
// the window being asymmetric only relative to "too old" — but we also
// reject far-future timestamps to limit pre-signed payloads.
func CheckReplayWindow(capturedAt, now time.Time, window time.Duration) error {
	if capturedAt.IsZero() {
		return ErrReplay
	}
	delta := now.Sub(capturedAt)
	if delta < 0 {
		delta = -delta
	}
	if delta > window {
		return ErrReplay
	}
	return nil
}
