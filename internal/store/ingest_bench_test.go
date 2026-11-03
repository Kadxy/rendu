package store

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"testing"
	"time"
)

// One app batch: 20k heart-rate samples shaped like the iOS serializer's.
func heartRateBatch(offset int) []json.RawMessage {
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.FixedZone("", 8*3600))
	out := make([]json.RawMessage, 20000)
	for i := range out {
		t := base.Add(time.Duration(offset+i) * time.Minute).Format(time.RFC3339)
		out[i] = json.RawMessage(fmt.Sprintf(`{"uuid":"%08X-0000-4000-8000-%012X","kind":"quantity","type":"HKQuantityTypeIdentifierHeartRate",`+
			`"startDate":"%s","endDate":"%s","quantity":{"value":%d,"unit":"count/min"},`+
			`"sourceRevision":{"source":{"name":"Apple Watch","bundleIdentifier":"com.apple.health.ABC"},"version":"27.1","productType":"Watch7,5"},`+
			`"device":{"name":"Apple Watch","manufacturer":"Apple Inc.","model":"Watch","hardwareVersion":"Watch7,5","softwareVersion":"27.1"},`+
			`"metadata":{"HKMetadataKeyHeartRateMotionContext":0}}`, offset+i, offset+i, t, t, 60+i%40))
	}
	return out
}

func BenchmarkIngest20k(b *testing.B) {
	s, err := Open(filepath.Join(b.TempDir(), "bench.db"))
	if err != nil {
		b.Fatal(err)
	}
	defer s.Close()
	batches := make([][]json.RawMessage, b.N)
	for i := range batches {
		batches[i] = heartRateBatch(i * 20000)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := s.Ingest(context.Background(), batches[i], nil); err != nil {
			b.Fatal(err)
		}
	}
	b.ReportMetric(float64(b.N*20000)/b.Elapsed().Seconds(), "samples/s")
}

// Re-delivery of unchanged samples: what a re-import (or a reinstalled app)
// sends for the whole history.
func BenchmarkIngest20kDuplicate(b *testing.B) {
	s, err := Open(filepath.Join(b.TempDir(), "bench.db"))
	if err != nil {
		b.Fatal(err)
	}
	defer s.Close()
	batch := heartRateBatch(0)
	if _, err := s.Ingest(context.Background(), batch, nil); err != nil {
		b.Fatal(err)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		res, err := s.Ingest(context.Background(), batch, nil)
		if err != nil || res.New != 0 {
			b.Fatal(err, res)
		}
	}
	b.ReportMetric(float64(b.N*20000)/b.Elapsed().Seconds(), "samples/s")
}
