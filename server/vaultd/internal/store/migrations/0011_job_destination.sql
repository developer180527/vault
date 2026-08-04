-- Where a finished download should be filed.
--
-- Until now every job landed in the owner's personal downloads/ zone. That
-- made adding a movie to the SHARED catalog absurd: qBittorrent already had
-- the file on the server, but an admin had to pull those bytes down to a
-- laptop and push the identical bytes back up through the upload API.
--
-- '' keeps the old behaviour (personal library), so existing rows and any
-- client that doesn't send a destination are unaffected.
ALTER TABLE jobs ADD COLUMN dest TEXT NOT NULL DEFAULT '';
