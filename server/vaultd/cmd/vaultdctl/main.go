// Command vaultdctl administers vaultd's database directly (users, grants,
// devices). Run it where the DB lives — on the server, typically via:
//
//	docker compose exec vaultd vaultdctl user list
//
// Usage:
//
//	vaultdctl user list
//	vaultdctl user add <username> --email <email> [--admin]
//	vaultdctl user disable|enable <username>
//	vaultdctl grants <username>
//	vaultdctl grant <username> <service> <action,action,...>
//	vaultdctl grant-remove <username> <service>
//	vaultdctl device list [username]
//	vaultdctl device revoke <device-id>
//	vaultdctl music scan
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/developer180527/vault/vaultd/internal/library"
	"github.com/developer180527/vault/vaultd/internal/music"
	"github.com/developer180527/vault/vaultd/internal/store"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) < 1 {
		return usage()
	}
	root := os.Getenv("VAULT_DATA_ROOT")
	if root == "" {
		root = "/srv/vault"
	}
	ctx := context.Background()
	st, err := store.Open(ctx, filepath.Join(root, "system", "db", "vault.db"))
	if err != nil {
		return err
	}
	defer st.Close()

	switch args[0] {
	case "user":
		return userCmd(ctx, st, args[1:])
	case "grants":
		return grantsCmd(ctx, st, args[1:])
	case "grant":
		return grantCmd(ctx, st, args[1:])
	case "grant-remove":
		return grantRemoveCmd(ctx, st, args[1:])
	case "device":
		return deviceCmd(ctx, st, args[1:])
	case "music":
		return musicCmd(ctx, st, root, args[1:])
	default:
		return usage()
	}
}

func userCmd(ctx context.Context, st *store.Store, args []string) error {
	if len(args) < 1 {
		return usage()
	}
	switch args[0] {
	case "list":
		users, err := st.Read().ListUsers(ctx)
		if err != nil {
			return err
		}
		for _, u := range users {
			bound := "pending-first-login"
			if u.OIDCSubject != "" {
				bound = "bound"
			}
			fmt.Printf("%-14s %-8s %-9s %-22s %s\n",
				u.Username, u.Role, u.Status, u.Email, bound)
		}
		return nil
	case "add":
		if len(args) < 2 {
			return usage()
		}
		username := args[1]
		email, role := "", "member"
		for i := 2; i < len(args); i++ {
			switch args[i] {
			case "--email":
				i++
				if i >= len(args) {
					return usage()
				}
				email = args[i]
			case "--admin":
				role = "admin"
			default:
				return usage()
			}
		}
		if email == "" {
			return fmt.Errorf("--email is required (it binds the account on first login)")
		}
		if !library.ValidUsername(username) {
			return fmt.Errorf("invalid username %q (lowercase letters, digits, . _ -)", username)
		}
		u, err := st.Write().CreateUser(ctx, username, email, "", role, "", "")
		if err != nil {
			return err
		}
		root := os.Getenv("VAULT_DATA_ROOT")
		if root == "" {
			root = "/srv/vault"
		}
		if err := library.Ensure(root, username); err != nil {
			return err
		}
		fmt.Printf("created %s (%s, %s) — binds on first Pocket ID login with %s\n",
			u.Username, u.Role, u.ID, email)
		return nil
	case "disable", "enable":
		if len(args) < 2 {
			return usage()
		}
		u, err := st.Read().UserByUsername(ctx, args[1])
		if err != nil {
			return err
		}
		status := "disabled"
		if args[0] == "enable" {
			status = "active"
		}
		if err := st.Write().SetUserStatus(ctx, u.ID, status); err != nil {
			return err
		}
		fmt.Printf("%s is now %s\n", u.Username, status)
		return nil
	}
	return usage()
}

func grantsCmd(ctx context.Context, st *store.Store, args []string) error {
	if len(args) < 1 {
		return usage()
	}
	u, err := st.Read().UserByUsername(ctx, args[0])
	if err != nil {
		return err
	}
	if u.Role == "admin" {
		fmt.Println("(admin: all services, all actions)")
		return nil
	}
	grants, err := st.Read().GrantsForUser(ctx, u.ID)
	if err != nil {
		return err
	}
	for svc, actions := range grants {
		fmt.Printf("%-10s %s\n", svc, strings.Join(actions, ","))
	}
	return nil
}

func grantCmd(ctx context.Context, st *store.Store, args []string) error {
	if len(args) < 3 {
		return usage()
	}
	u, err := st.Read().UserByUsername(ctx, args[0])
	if err != nil {
		return err
	}
	svc := args[1]
	if !slices.Contains(store.KnownServices, svc) {
		return fmt.Errorf("unknown service %q (known: %s)",
			svc, strings.Join(store.KnownServices, ", "))
	}
	actions := strings.Split(args[2], ",")
	for _, a := range actions {
		if !slices.Contains(store.KnownActions, a) {
			return fmt.Errorf("unknown action %q (known: %s)",
				a, strings.Join(store.KnownActions, ", "))
		}
	}
	if err := st.Write().SetGrant(ctx, u.ID, svc, actions); err != nil {
		return err
	}
	fmt.Printf("granted %s on %s to %s\n", args[2], svc, u.Username)
	return nil
}

func grantRemoveCmd(ctx context.Context, st *store.Store, args []string) error {
	if len(args) < 2 {
		return usage()
	}
	u, err := st.Read().UserByUsername(ctx, args[0])
	if err != nil {
		return err
	}
	if err := st.Write().RemoveGrant(ctx, u.ID, args[1]); err != nil {
		return err
	}
	fmt.Printf("revoked %s from %s\n", args[1], u.Username)
	return nil
}

func deviceCmd(ctx context.Context, st *store.Store, args []string) error {
	if len(args) < 1 {
		return usage()
	}
	switch args[0] {
	case "list":
		userID := ""
		if len(args) > 1 {
			u, err := st.Read().UserByUsername(ctx, args[1])
			if err != nil {
				return err
			}
			userID = u.ID
		}
		devices, err := st.Read().ListDevices(ctx, userID)
		if err != nil {
			return err
		}
		for _, d := range devices {
			fmt.Printf("%s  %-16s %-8s last-seen %s\n",
				d.ID, d.Name, d.Platform, d.LastSeen.Format("2006-01-02 15:04"))
		}
		return nil
	case "revoke":
		if len(args) < 2 {
			return usage()
		}
		if err := st.Write().RevokeDevice(ctx, args[1]); err != nil {
			return err
		}
		fmt.Println("device revoked")
		return nil
	}
	return usage()
}

func usage() error {
	fmt.Fprint(os.Stderr, `usage:
  vaultdctl user list
  vaultdctl user add <username> --email <email> [--admin]
  vaultdctl user disable|enable <username>
  vaultdctl grants <username>
  vaultdctl grant <username> <service> <action,...>
  vaultdctl grant-remove <username> <service>
  vaultdctl device list [username]
  vaultdctl device revoke <device-id>
  vaultdctl music scan
`)
	return fmt.Errorf("invalid arguments")
}

// musicCmd: catalog administration. `music scan` indexes files the admin
// dropped into <root>/catalog/music (also reachable as POST
// /v1/music/catalog/scan with music:write).
func musicCmd(ctx context.Context, st *store.Store, root string, args []string) error {
	if len(args) < 1 || args[0] != "scan" {
		return usage()
	}
	svc := &music.Service{DataRoot: root, Store: st,
		Log: slog.New(slog.NewTextHandler(os.Stderr, nil))}
	changed, pruned, err := svc.ScanCatalog(ctx)
	if err != nil {
		return err
	}
	fmt.Printf("catalog scan: %d changed, %d pruned\n", changed, pruned)
	return nil
}
