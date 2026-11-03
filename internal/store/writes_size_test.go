package store

import (
	"context"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

// Large objects are handed out a few at a time, never none.
func TestPendingWritesCapsTheirSize(t *testing.T) {
	ctx := context.Background()
	st, err := Open(filepath.Join(t.TempDir(), "rendu.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	note := strings.Repeat("x", 6<<20)
	for range 4 {
		obj, _ := json.Marshal(map[string]any{
			"kind": "quantity", "type": "HKQuantityTypeIdentifierBodyMass", "quantity": map[string]any{"value": 70, "unit": "kg"},
			"startDate": "2026-11-01T08:00:00+08:00", "endDate": "2026-11-01T08:00:00+08:00", "metadata": map[string]any{"note": note},
		})
		if _, err := st.SubmitWrite(ctx, WriteRequest{Op: OpSave, Object: obj}, Submitter{}); err != nil {
			t.Fatal(err)
		}
	}
	pending, err := st.PendingWrites(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(pending) != 2 {
		t.Fatalf("got %d pending writes, want 2 (16 MB of 6 MB objects)", len(pending))
	}
}
