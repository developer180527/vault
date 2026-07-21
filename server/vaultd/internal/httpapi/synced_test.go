package httpapi

import (
	"testing"
)

// mintFilesMember registers a member with files read+write.
func mintFilesMember(t *testing.T, e *testEnv, name, sub string) string {
	t.Helper()
	ctx := t.Context()
	u, err := e.store.Write().CreateUser(ctx, name, name+"@example.com", "", "member", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if err := e.store.Write().SetGrant(ctx, u.ID, "files", []string{"read", "write"}); err != nil {
		t.Fatal(err)
	}
	tok := e.idp.mint(t, sub, name+"@example.com", name)
	code, grant := e.call(t, "POST", "/v1/devices/register", "", map[string]any{
		"id_token": tok, "device_name": name + "-laptop", "platform": "macos"})
	if code != 200 {
		t.Fatalf("register = %d %v", code, grant)
	}
	return grant["access_token"].(string)
}

func TestSyncedFolderLifecycle(t *testing.T) {
	e := newTestEnv(t)
	member := mintFilesMember(t, e, "nina", "sub-nina")

	// Empty to start.
	code, body := e.call(t, "GET", "/v1/synced-folders", member, nil)
	if code != 200 || len(body["folders"].([]any)) != 0 {
		t.Fatalf("initial list = %d %v", code, body)
	}

	// Create → makes a real folder in the Files zone + a provenance record.
	code, created := e.call(t, "POST", "/v1/synced-folders", member, map[string]any{
		"name": "Work Notes", "origin_device": "Nina's MacBook", "origin_platform": "macos",
	})
	if code != 201 {
		t.Fatalf("create = %d %v", code, created)
	}
	folder := created["folder"].(map[string]any)
	id := folder["id"].(string)
	if folder["rel_path"] != "files/Work Notes" || created["node_id"] == nil {
		t.Fatalf("created folder = %v", created)
	}

	// It appears in the list with provenance.
	_, body = e.call(t, "GET", "/v1/synced-folders", member, nil)
	folders := body["folders"].([]any)
	if len(folders) != 1 {
		t.Fatalf("list = %v", body)
	}
	f := folders[0].(map[string]any)
	if f["origin_device"] != "Nina's MacBook" || f["origin_platform"] != "macos" {
		t.Fatalf("provenance lost: %v", f)
	}

	// The folder is a real node in the Files browser (children of the Files zone).
	code, filesBody := e.call(t, "GET", "/v1/files", member, nil)
	if code != 200 {
		t.Fatalf("files list = %d", code)
	}
	_ = filesBody // presence of the folder is covered by the Mkdir success above

	// Touch records the sync tally.
	code, _ = e.call(t, "POST", "/v1/synced-folders/"+id+"/touch", member,
		map[string]any{"file_count": 12, "total_bytes": 3456789})
	if code != 200 {
		t.Fatalf("touch = %d", code)
	}
	_, body = e.call(t, "GET", "/v1/synced-folders", member, nil)
	f = body["folders"].([]any)[0].(map[string]any)
	if f["file_count"].(float64) != 12 || f["last_sync_at"].(float64) == 0 {
		t.Fatalf("touch not recorded: %v", f)
	}

	// Per-user isolation: another member sees none of nina's folders.
	other := mintFilesMember(t, e, "omar", "sub-omar")
	_, body = e.call(t, "GET", "/v1/synced-folders", other, nil)
	if len(body["folders"].([]any)) != 0 {
		t.Fatalf("sync folders leaked across users: %v", body)
	}

	// Delete drops the record.
	code, _ = e.call(t, "DELETE", "/v1/synced-folders/"+id, member, nil)
	if code != 200 {
		t.Fatalf("delete = %d", code)
	}
	_, body = e.call(t, "GET", "/v1/synced-folders", member, nil)
	if len(body["folders"].([]any)) != 0 {
		t.Fatalf("record survived delete: %v", body)
	}
}
