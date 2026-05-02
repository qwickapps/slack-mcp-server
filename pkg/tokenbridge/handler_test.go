package tokenbridge

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// fakeStore implements WorkspaceStore for handler-level tests without a DB.
type fakeStore struct {
	upsertCalls   int
	auditCalls    []auditCall
	upsertResult  fakeUpsertResult
	upsertErr     error
	auditErr      error
	pingErr       error
	lastUpsertArg fakeUpsertArg
}

type fakeUpsertResult struct {
	stored bool
	reason string
}

type fakeUpsertArg struct {
	teamID, teamName string
	xoxc, xoxd       []byte
	capturedAt       time.Time
}

type auditCall struct {
	teamID, event, sourceIP, userAgent string
	capturedAt                         time.Time
}

func (f *fakeStore) UpsertWorkspace(
	ctx context.Context,
	teamID, teamName string,
	xoxcEnc, xoxdEnc []byte,
	capturedAt time.Time,
) (bool, string, error) {
	f.upsertCalls++
	f.lastUpsertArg = fakeUpsertArg{teamID, teamName, xoxcEnc, xoxdEnc, capturedAt}
	if f.upsertErr != nil {
		return false, "", f.upsertErr
	}
	return f.upsertResult.stored, f.upsertResult.reason, nil
}

func (f *fakeStore) WriteAudit(
	ctx context.Context,
	teamID, event string,
	capturedAt time.Time,
	sourceIP, userAgent string,
) error {
	f.auditCalls = append(f.auditCalls, auditCall{teamID, event, sourceIP, userAgent, capturedAt})
	return f.auditErr
}

func (f *fakeStore) Ping(ctx context.Context) error { return f.pingErr }

// newTestCipher constructs a Cipher with a fixed 32-byte key for tests.
func newTestCipher(t *testing.T) *Cipher {
	t.Helper()
	key := make([]byte, EncryptionKeyBytes)
	for i := range key {
		key[i] = byte(i)
	}
	c, err := NewCipher(key)
	require.NoError(t, err)
	return c
}

// signedRequest builds a POST request to /api/tokens/refresh with a valid
// HMAC signature for the given body and matching nonce header.
func signedRequest(t *testing.T, hmacKey []byte, body []byte, nonce string) *http.Request {
	t.Helper()
	r := httptest.NewRequest(http.MethodPost, "/api/tokens/refresh", strings.NewReader(string(body)))
	r.Header.Set(SignatureHeader, ComputeSignature(hmacKey, body))
	r.Header.Set(NonceHeader, nonce)
	r.Header.Set("Content-Type", "application/json")
	return r
}

func TestRefreshHandler_Success(t *testing.T) {
	store := &fakeStore{upsertResult: fakeUpsertResult{stored: true}}
	hmacKey := []byte("test-hmac-secret")
	cipher := newTestCipher(t)
	h := RefreshHandler(store, hmacKey, cipher)

	body, _ := json.Marshal(refreshRequest{
		TeamID:     "T123",
		TeamName:   "Acme",
		Xoxc:       "xoxc-test",
		Xoxd:       "xoxd-test",
		CapturedAt: time.Now().UTC(),
		Nonce:      "n-1",
	})
	r := signedRequest(t, hmacKey, body, "n-1")
	w := httptest.NewRecorder()

	h.ServeHTTP(w, r)

	require.Equal(t, http.StatusOK, w.Code, "body: %s", w.Body.String())
	var resp refreshResponse
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &resp))
	assert.True(t, resp.Stored)
	assert.Equal(t, "T123", resp.TeamID)
	assert.Empty(t, resp.Reason)

	require.Equal(t, 1, store.upsertCalls)
	assert.Equal(t, "T123", store.lastUpsertArg.teamID)
	// stored ciphertext must NOT equal plaintext
	assert.NotEqual(t, []byte("xoxc-test"), store.lastUpsertArg.xoxc)
	// roundtrip: decrypt should yield original plaintext
	pt, err := cipher.Decrypt(store.lastUpsertArg.xoxc)
	require.NoError(t, err)
	assert.Equal(t, []byte("xoxc-test"), pt)

	require.Len(t, store.auditCalls, 1)
	assert.Equal(t, eventRefreshed, store.auditCalls[0].event)
}

func TestRefreshHandler_StaleReturnsStoredFalse(t *testing.T) {
	store := &fakeStore{upsertResult: fakeUpsertResult{stored: false, reason: ReasonStale}}
	hmacKey := []byte("k")
	h := RefreshHandler(store, hmacKey, newTestCipher(t))

	body, _ := json.Marshal(refreshRequest{
		TeamID: "T1", TeamName: "A", Xoxc: "x", Xoxd: "d",
		CapturedAt: time.Now().UTC(), Nonce: "n",
	})
	r := signedRequest(t, hmacKey, body, "n")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)

	require.Equal(t, http.StatusOK, w.Code)
	var resp refreshResponse
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &resp))
	assert.False(t, resp.Stored)
	assert.Equal(t, ReasonStale, resp.Reason)

	require.Len(t, store.auditCalls, 1)
	assert.Equal(t, eventSkippedStale, store.auditCalls[0].event)
}

func TestRefreshHandler_TamperedBodyRejected(t *testing.T) {
	store := &fakeStore{upsertResult: fakeUpsertResult{stored: true}}
	hmacKey := []byte("k")
	h := RefreshHandler(store, hmacKey, newTestCipher(t))

	original, _ := json.Marshal(refreshRequest{
		TeamID: "T1", TeamName: "A", Xoxc: "x", Xoxd: "d",
		CapturedAt: time.Now().UTC(), Nonce: "n",
	})
	tampered, _ := json.Marshal(refreshRequest{
		TeamID: "T2", TeamName: "A", Xoxc: "x", Xoxd: "d",
		CapturedAt: time.Now().UTC(), Nonce: "n",
	})

	// signature is over `original`, but we send `tampered`
	r := httptest.NewRequest(http.MethodPost, "/api/tokens/refresh", strings.NewReader(string(tampered)))
	r.Header.Set(SignatureHeader, ComputeSignature(hmacKey, original))
	r.Header.Set(NonceHeader, "n")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)

	assert.Equal(t, http.StatusUnauthorized, w.Code)
	assert.Zero(t, store.upsertCalls)
}

func TestRefreshHandler_MissingSignatureRejected(t *testing.T) {
	h := RefreshHandler(&fakeStore{}, []byte("k"), newTestCipher(t))

	body := []byte(`{"team_id":"T1"}`)
	r := httptest.NewRequest(http.MethodPost, "/api/tokens/refresh", strings.NewReader(string(body)))
	r.Header.Set(NonceHeader, "n")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)

	assert.Equal(t, http.StatusUnauthorized, w.Code)
}

func TestRefreshHandler_NonceMismatchRejected(t *testing.T) {
	store := &fakeStore{upsertResult: fakeUpsertResult{stored: true}}
	hmacKey := []byte("k")
	h := RefreshHandler(store, hmacKey, newTestCipher(t))

	body, _ := json.Marshal(refreshRequest{
		TeamID: "T1", TeamName: "A", Xoxc: "x", Xoxd: "d",
		CapturedAt: time.Now().UTC(), Nonce: "body-nonce",
	})
	r := httptest.NewRequest(http.MethodPost, "/api/tokens/refresh", strings.NewReader(string(body)))
	r.Header.Set(SignatureHeader, ComputeSignature(hmacKey, body))
	r.Header.Set(NonceHeader, "header-nonce")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)

	assert.Equal(t, http.StatusUnauthorized, w.Code)
	assert.Zero(t, store.upsertCalls)
}

func TestRefreshHandler_StaleCapturedAtRejected(t *testing.T) {
	store := &fakeStore{upsertResult: fakeUpsertResult{stored: true}}
	hmacKey := []byte("k")
	h := RefreshHandler(store, hmacKey, newTestCipher(t))

	body, _ := json.Marshal(refreshRequest{
		TeamID: "T1", TeamName: "A", Xoxc: "x", Xoxd: "d",
		CapturedAt: time.Now().UTC().Add(-10 * time.Minute),
		Nonce:      "n",
	})
	r := signedRequest(t, hmacKey, body, "n")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)

	assert.Equal(t, http.StatusBadRequest, w.Code)
	assert.Zero(t, store.upsertCalls)
}

func TestRefreshHandler_FutureCapturedAtRejected(t *testing.T) {
	store := &fakeStore{upsertResult: fakeUpsertResult{stored: true}}
	hmacKey := []byte("k")
	h := RefreshHandler(store, hmacKey, newTestCipher(t))

	body, _ := json.Marshal(refreshRequest{
		TeamID: "T1", TeamName: "A", Xoxc: "x", Xoxd: "d",
		CapturedAt: time.Now().UTC().Add(5 * time.Minute),
		Nonce:      "n",
	})
	r := signedRequest(t, hmacKey, body, "n")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)

	assert.Equal(t, http.StatusBadRequest, w.Code)
	assert.Zero(t, store.upsertCalls)
}

func TestRefreshHandler_MalformedJSONRejected(t *testing.T) {
	hmacKey := []byte("k")
	h := RefreshHandler(&fakeStore{}, hmacKey, newTestCipher(t))

	body := []byte(`{not json`)
	r := httptest.NewRequest(http.MethodPost, "/api/tokens/refresh", strings.NewReader(string(body)))
	r.Header.Set(SignatureHeader, ComputeSignature(hmacKey, body))
	r.Header.Set(NonceHeader, "n")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)

	assert.Equal(t, http.StatusBadRequest, w.Code)
}

func TestRefreshHandler_MissingFieldsRejected(t *testing.T) {
	hmacKey := []byte("k")
	h := RefreshHandler(&fakeStore{}, hmacKey, newTestCipher(t))

	body, _ := json.Marshal(refreshRequest{
		TeamID:     "",
		Xoxc:       "x",
		Xoxd:       "d",
		CapturedAt: time.Now().UTC(),
		Nonce:      "n",
	})
	r := signedRequest(t, hmacKey, body, "n")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)

	assert.Equal(t, http.StatusBadRequest, w.Code)
}

func TestRefreshHandler_WrongMethodRejected(t *testing.T) {
	h := RefreshHandler(&fakeStore{}, []byte("k"), newTestCipher(t))

	r := httptest.NewRequest(http.MethodGet, "/api/tokens/refresh", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)

	assert.Equal(t, http.StatusMethodNotAllowed, w.Code)
	assert.Equal(t, http.MethodPost, w.Header().Get("Allow"))
}

func TestRefreshHandler_AuditFailureDoesNotFailRequest(t *testing.T) {
	store := &fakeStore{
		upsertResult: fakeUpsertResult{stored: true},
		auditErr:     errors.New("audit broken"),
	}
	hmacKey := []byte("k")
	h := RefreshHandler(store, hmacKey, newTestCipher(t))

	body, _ := json.Marshal(refreshRequest{
		TeamID: "T1", TeamName: "A", Xoxc: "x", Xoxd: "d",
		CapturedAt: time.Now().UTC(), Nonce: "n",
	})
	r := signedRequest(t, hmacKey, body, "n")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)

	assert.Equal(t, http.StatusOK, w.Code)
}

func TestHealthHandler_OK(t *testing.T) {
	h := HealthHandler(&fakeStore{})

	r := httptest.NewRequest(http.MethodGet, "/_health", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)

	assert.Equal(t, http.StatusOK, w.Code)
	body, _ := io.ReadAll(w.Body)
	assert.Contains(t, string(body), `"ok"`)
}

func TestHealthHandler_Unhealthy(t *testing.T) {
	h := HealthHandler(&fakeStore{pingErr: errors.New("db down")})

	r := httptest.NewRequest(http.MethodGet, "/_health", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)

	assert.Equal(t, http.StatusServiceUnavailable, w.Code)
	body, _ := io.ReadAll(w.Body)
	assert.Contains(t, string(body), `"unhealthy"`)
}

func TestHealthHandler_WrongMethodRejected(t *testing.T) {
	h := HealthHandler(&fakeStore{})

	r := httptest.NewRequest(http.MethodPost, "/_health", nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)

	assert.Equal(t, http.StatusMethodNotAllowed, w.Code)
}
