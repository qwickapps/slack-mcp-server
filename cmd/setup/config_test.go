package main

import (
	"strings"
	"testing"
)

// TestValidateBridgeURL covers FU1 (validate at startup) and FU2
// (TrimRight slash) from the qwickapps/slack-mcp-server#9 review.
func TestValidateBridgeURL(t *testing.T) {
	cases := []struct {
		name      string
		raw       string
		want      string
		wantErr   bool
		errSubstr string
	}{
		{
			name: "https no slash",
			raw:  "https://bridge.example.com",
			want: "https://bridge.example.com",
		},
		{
			name: "http with port no slash",
			raw:  "http://bridge.tail.ts.net:13082",
			want: "http://bridge.tail.ts.net:13082",
		},
		{
			name: "trailing slash trimmed (FU2)",
			raw:  "https://bridge.example.com/",
			want: "https://bridge.example.com",
		},
		{
			name: "multiple trailing slashes trimmed",
			raw:  "https://bridge.example.com////",
			want: "https://bridge.example.com",
		},
		{
			name: "empty rejected",
			raw:  "",
			// loadConfig rejects empty BRIDGE_URL before reaching the
			// validator, but exercising the validator directly here
			// proves it doesn't silently accept "" — scheme check fires.
			wantErr:   true,
			errSubstr: "scheme",
		},
		{
			name:      "no scheme rejected",
			raw:       "bridge.example.com",
			wantErr:   true,
			errSubstr: "scheme",
		},
		{
			name:      "wrong scheme rejected",
			raw:       "ftp://bridge.example.com",
			wantErr:   true,
			errSubstr: "scheme",
		},
		{
			name:      "scheme only rejected",
			raw:       "https://",
			wantErr:   true,
			errSubstr: "host",
		},
		{
			name:      "junk rejected",
			raw:       "://nope",
			wantErr:   true,
			errSubstr: "valid URL",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := validateBridgeURL(tc.raw)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error containing %q, got nil (returned %q)", tc.errSubstr, got)
				}
				if tc.errSubstr != "" && !strings.Contains(err.Error(), tc.errSubstr) {
					t.Errorf("error = %v, want substring %q", err, tc.errSubstr)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

// Regression test for the FU2 motivating bug: BRIDGE_URL with a
// trailing slash produced "https://host//api/tokens/refresh" when
// concatenated in the userscript. The validator must strip the slash
// so the concat in qwickapps-slack-bridge.user.js is unambiguous.
func TestValidateBridgeURL_NoDoubleSlashAfterConcat(t *testing.T) {
	got, err := validateBridgeURL("https://bridge.example.com/")
	if err != nil {
		t.Fatalf("validateBridgeURL: %v", err)
	}
	full := got + "/api/tokens/refresh"
	if strings.Contains(full, "//api") {
		t.Errorf("double slash after concat: %q", full)
	}
}
