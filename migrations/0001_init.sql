-- token-bridge schema (P2)
--
-- workspaces holds the latest encrypted xoxc/xoxd pair per Slack team.
-- Both ciphertexts include their AES-GCM nonce as a 12-byte prefix.
--
-- audit_log records every refresh attempt (stored, skipped, or rejected)
-- so we can answer "when did this team's tokens last rotate" without
-- decrypting anything.

CREATE TABLE IF NOT EXISTS workspaces (
  team_id           text PRIMARY KEY,
  team_name         text NOT NULL,
  xoxc_enc          bytea NOT NULL,
  xoxd_enc          bytea NOT NULL,
  last_refreshed_at timestamptz NOT NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS audit_log (
  id          bigserial PRIMARY KEY,
  team_id     text NOT NULL,
  event       text NOT NULL,
  captured_at timestamptz,
  source_ip   inet,
  user_agent  text,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS audit_log_team_id_idx ON audit_log(team_id, created_at DESC);
