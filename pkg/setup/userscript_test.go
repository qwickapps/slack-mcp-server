package setup_test

import (
	"os"
	"strings"
	"testing"
)

// TestUserscriptPlaceholders reads the userscript source file directly and
// asserts both template placeholders are present. This catches accidental
// hardcoding of deployment-specific values into the committed file.
func TestUserscriptPlaceholders(t *testing.T) {
	const scriptPath = "../../userscript/qwickapps-slack-bridge.user.js"

	data, err := os.ReadFile(scriptPath)
	if err != nil {
		t.Fatalf("reading userscript: %v", err)
	}
	content := string(data)

	placeholders := []string{
		"__BRIDGE_URL__",
		"__BRIDGE_HMAC_KEY__",
	}
	for _, p := range placeholders {
		if !strings.Contains(content, p) {
			t.Errorf("userscript missing placeholder %q — hardcoding is not allowed", p)
		}
	}
}
