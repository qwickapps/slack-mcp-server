// ==UserScript==
// @name         QwickApps Slack Bridge
// @namespace    https://qwickapps.com
// @version      1.0.0
// @description  Captures xoxc/xoxd tokens from the Slack web client and forwards them to the QwickApps token-bridge (P2) via HMAC-signed POST requests. Silent — no DOM modification.
// @author       QwickApps
// @match        https://app.slack.com/*
// @match        https://*.slack.com/messages/*
// @match        https://*.slack.com/archives/*
// @match        https://*.slack.com/client/*
// @exclude      https://slack.com/intl/*
// @exclude      https://slack.com/help/*
// @exclude      https://slack.com/blog/*
// @exclude      https://slack.com/resources/*
// @grant        GM_xmlhttpRequest
// @grant        GM_cookie
// @grant        GM_setValue
// @grant        GM_getValue
// @grant        unsafeWindow
// @connect      __BRIDGE_HOST__
// @run-at       document-idle
// ==/UserScript==

(function () {
  'use strict';

  // === QwickApps Slack Bridge config (templated by /setup) ===
  const BRIDGE_URL = '__BRIDGE_URL__';
  const BRIDGE_HMAC_KEY = '__BRIDGE_HMAC_KEY__';
  // ===========================================================

  const POLL_INTERVAL_MS = 5 * 60 * 1000; // 5 minutes

  // generateUUID returns a version-4 UUID using the browser's crypto API.
  function generateUUID() {
    return ([1e7] + -1e3 + -4e3 + -8e3 + -1e11).replace(/[018]/g, function (c) {
      return (c ^ (crypto.getRandomValues(new Uint8Array(1))[0] & (15 >> (c / 4)))).toString(16);
    });
  }

  // hmacSHA256Hex computes an HMAC-SHA256 over body (string) using
  // key (string). Returns a Promise<string> of the hex-encoded digest.
  async function hmacSHA256Hex(keyStr, body) {
    const enc = new TextEncoder();
    const keyMaterial = await crypto.subtle.importKey(
      'raw',
      enc.encode(keyStr),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    );
    const sig = await crypto.subtle.sign('HMAC', keyMaterial, enc.encode(body));
    return Array.from(new Uint8Array(sig))
      .map(function (b) { return b.toString(16).padStart(2, '0'); })
      .join('');
  }

  // extractFromGlobals attempts to read xoxc, team_id, and team_name from
  // the Slack boot_data global injected by the web client.
  function extractFromGlobals() {
    try {
      var ts = unsafeWindow.TS;
      if (!ts || !ts.boot_data) {
        return null;
      }
      var bd = ts.boot_data;
      var xoxc = bd.api_token || '';
      if (!xoxc.startsWith('xoxc-')) {
        return null;
      }
      return {
        xoxc: xoxc,
        team_id: bd.team_id || '',
        team_name: (bd.team && bd.team.name) ? bd.team.name : (bd.team_name || ''),
      };
    } catch (e) {
      return null;
    }
  }

  // getCookieD retrieves the Slack 'd' cookie (xoxd token) via GM_cookie.
  // The 'd' cookie is HttpOnly so document.cookie does not expose it.
  function getCookieD() {
    return new Promise(function (resolve) {
      if (typeof GM_cookie === 'undefined' || typeof GM_cookie.list !== 'function') {
        resolve('');
        return;
      }
      GM_cookie.list({ domain: '.slack.com', name: 'd' }, function (cookies, error) {
        if (error || !cookies || cookies.length === 0) {
          resolve('');
          return;
        }
        resolve(cookies[0].value || '');
      });
    });
  }

  // sendRefresh signs and POSTs a token refresh to the bridge.
  async function sendRefresh(teamID, teamName, xoxc, xoxd) {
    var nonce = generateUUID();
    var capturedAt = new Date().toISOString();

    var payload = JSON.stringify({
      team_id: teamID,
      team_name: teamName,
      xoxc: xoxc,
      xoxd: xoxd,
      captured_at: capturedAt,
      nonce: nonce,
    });

    var sig;
    try {
      sig = await hmacSHA256Hex(BRIDGE_HMAC_KEY, payload);
    } catch (e) {
      console.error('qwickapps-slack-bridge: hmac sign failed:', e);
      return;
    }

    GM_xmlhttpRequest({
      method: 'POST',
      url: BRIDGE_URL + '/api/tokens/refresh',
      headers: {
        'Content-Type': 'application/json',
        'X-Bridge-Signature': sig,
        'X-Bridge-Nonce': nonce,
      },
      data: payload,
      onload: function (resp) {
        if (resp.status === 200) {
          GM_setValue('lastSent.' + teamID, JSON.stringify({ xoxc: xoxc, xoxd: xoxd }));
          console.log('qwickapps-slack-bridge: refreshed team=' + teamID);
        } else {
          var body = (resp.responseText || '').substring(0, 200);
          console.warn('qwickapps-slack-bridge: refresh failed status=' + resp.status + ' body=' + body);
        }
      },
      onerror: function (resp) {
        console.error('qwickapps-slack-bridge: request error team=' + teamID + ' error=' + (resp && resp.error) + ' status=' + (resp && resp.statusText));
      },
    });
  }

  // tryCapture extracts tokens and posts a refresh if any field changed.
  async function tryCapture() {
    var globals = extractFromGlobals();
    if (!globals) {
      // boot_data not yet ready; next tick will retry.
      return;
    }

    var teamID = globals.team_id;
    var teamName = globals.team_name;
    var xoxc = globals.xoxc;

    if (!teamID || !xoxc) {
      return;
    }

    var xoxd = await getCookieD();
    if (!xoxd) {
      // xoxd not available yet; the bridge requires both tokens.
      return;
    }

    var lastSentRaw = GM_getValue('lastSent.' + teamID, '');
    if (lastSentRaw) {
      try {
        var last = JSON.parse(lastSentRaw);
        if (last.xoxc === xoxc && last.xoxd === xoxd) {
          // Nothing changed; skip the POST.
          return;
        }
      } catch (e) {
        // Corrupt stored value — fall through and resend.
      }
    }

    await sendRefresh(teamID, teamName, xoxc, xoxd);
  }

  // Initial capture on page load.
  tryCapture();

  // Periodic capture every 5 minutes.
  setInterval(tryCapture, POLL_INTERVAL_MS);
})();
