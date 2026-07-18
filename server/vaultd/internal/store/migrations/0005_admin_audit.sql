-- Admin audit log (ADMIN.md §4): every admin mutation writes exactly one
-- append-only row — who, what, which target, from where, when. Security
-- forensics AND the panel's Activity feed. Summaries are redacted by the
-- writers; secret values never land here.

CREATE TABLE admin_audit (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    actor_user  TEXT NOT NULL,             -- username at time of action
    action      TEXT NOT NULL,             -- e.g. 'user.invite', 'track.delete'
    target_kind TEXT NOT NULL DEFAULT '',  -- 'user' | 'track' | 'device' | ...
    target_id   TEXT NOT NULL DEFAULT '',
    summary     TEXT NOT NULL DEFAULT '',
    request_id  TEXT NOT NULL DEFAULT '',
    remote_addr TEXT NOT NULL DEFAULT '',
    created_at  INTEGER NOT NULL           -- unix seconds
);
CREATE INDEX idx_audit_created ON admin_audit(created_at DESC);
