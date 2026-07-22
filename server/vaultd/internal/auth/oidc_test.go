package auth

import (
	"context"
	"testing"
)

type fakeVerifier struct{ id *Identity }

func (f fakeVerifier) Verify(context.Context, string) (*Identity, error) {
	return f.id, nil
}

// The retrying wrapper must refuse verification until discovery lands, then
// delegate to the real verifier once it's set.
func TestRetryingVerifier(t *testing.T) {
	rv := &RetryingVerifier{}

	if rv.Ready() {
		t.Fatal("should not be ready before discovery")
	}
	if _, err := rv.Verify(context.Background(), "tok"); err == nil {
		t.Fatal("expected a not-ready error before discovery")
	}

	rv.set(fakeVerifier{id: &Identity{Subject: "sub-1"}})

	if !rv.Ready() {
		t.Fatal("should be ready after discovery")
	}
	got, err := rv.Verify(context.Background(), "tok")
	if err != nil {
		t.Fatalf("verify after ready: %v", err)
	}
	if got.Subject != "sub-1" {
		t.Fatalf("did not delegate to inner verifier: %v", got)
	}
}
