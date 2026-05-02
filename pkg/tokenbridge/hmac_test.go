package tokenbridge

import (
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestComputeSignature_Stable(t *testing.T) {
	key := []byte("super-secret")
	body := []byte(`{"team_id":"T1"}`)

	a := ComputeSignature(key, body)
	b := ComputeSignature(key, body)
	assert.Equal(t, a, b, "signature must be deterministic")
	assert.Len(t, a, 64, "hex-encoded SHA-256 is 64 chars")
}

func TestVerifySignature_Accepts(t *testing.T) {
	key := []byte("super-secret")
	body := []byte(`{"team_id":"T1","captured_at":"2026-01-01T00:00:00Z"}`)
	sig := ComputeSignature(key, body)

	require.NoError(t, VerifySignature(key, body, sig))
}

func TestVerifySignature_RejectsTamperedBody(t *testing.T) {
	key := []byte("super-secret")
	body := []byte(`{"team_id":"T1"}`)
	sig := ComputeSignature(key, body)

	tampered := []byte(`{"team_id":"T2"}`)
	err := VerifySignature(key, tampered, sig)
	assert.ErrorIs(t, err, ErrInvalidSignature)
}

func TestVerifySignature_RejectsWrongKey(t *testing.T) {
	body := []byte(`{"team_id":"T1"}`)
	sig := ComputeSignature([]byte("real-key"), body)

	err := VerifySignature([]byte("wrong-key"), body, sig)
	assert.ErrorIs(t, err, ErrInvalidSignature)
}

func TestVerifySignature_RejectsNonHex(t *testing.T) {
	err := VerifySignature([]byte("k"), []byte("body"), "this-is-not-hex")
	assert.ErrorIs(t, err, ErrInvalidSignature)
}

func TestVerifySignature_RejectsTruncatedSignature(t *testing.T) {
	key := []byte("k")
	body := []byte("body")
	sig := ComputeSignature(key, body)
	// drop trailing characters but keep valid hex
	truncated := sig[:60]

	err := VerifySignature(key, body, truncated)
	assert.ErrorIs(t, err, ErrInvalidSignature)
}

func TestCheckReplayWindow(t *testing.T) {
	now := time.Date(2026, 5, 1, 12, 0, 0, 0, time.UTC)

	cases := []struct {
		name       string
		capturedAt time.Time
		wantErr    bool
	}{
		{"now", now, false},
		{"30s ago", now.Add(-30 * time.Second), false},
		{"4m59s ago", now.Add(-(4*time.Minute + 59*time.Second)), false},
		{"5m ago (boundary)", now.Add(-5 * time.Minute), false},
		{"6m ago", now.Add(-6 * time.Minute), true},
		{"1h ago (replay)", now.Add(-time.Hour), true},
		{"6m in future", now.Add(6 * time.Minute), true},
		{"zero", time.Time{}, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := CheckReplayWindow(tc.capturedAt, now, DefaultReplayWindow)
			if tc.wantErr {
				assert.ErrorIs(t, err, ErrReplay)
			} else {
				assert.NoError(t, err)
			}
		})
	}
}
