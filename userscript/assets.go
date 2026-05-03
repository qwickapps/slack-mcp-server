// Package userscript exposes the Tampermonkey userscript source as an
// embedded Go string. The content contains __BRIDGE_URL__ and
// __BRIDGE_HMAC_KEY__ placeholders that the /setup service substitutes at
// request time; the file must never contain hardcoded deployment values.
package userscript

import _ "embed"

// Source is the raw content of the userscript template file.
//
//go:embed qwickapps-slack-bridge.user.js
var Source string
