-- Browser sessions for the tailnet-only admin panel (docs/backend/ADMIN.md).
-- Same discipline as device tokens: the cookie holds an opaque random token,
-- only its sha256 lands here. 12h absolute expiry; revocation = row delete.
CREATE TABLE admin_sessions (
    id         TEXT PRIMARY KEY,              -- uuid
    user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);
CREATE INDEX idx_admin_sessions_user ON admin_sessions(user_id);
