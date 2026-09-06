package cloud

import (
	"errors"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

func TestSchemaIsEmbeddedAndComplete(t *testing.T) {
	schema := Schema()
	if strings.TrimSpace(schema) == "" {
		t.Fatal("schema.sql was not embedded")
	}
	// Every table the storage ports touch must exist in the DDL, or a
	// deployment migrates cleanly and then fails on first write.
	for _, table := range []string{
		"cloud_users", "cloud_devices", "cloud_refresh_tokens",
		"cloud_records", "cloud_scope_watermarks", "cloud_sync_log",
		"cloud_continuity",
	} {
		if !strings.Contains(schema, table) {
			t.Errorf("schema is missing table %q", table)
		}
	}
	// The delta-sync index is the one that makes incremental pull viable.
	if !strings.Contains(schema, "cloud_records_delta_idx") {
		t.Error("schema is missing the delta-sync index")
	}
}

func TestSchemaIsIdempotent(t *testing.T) {
	// Migrate() runs on every boot of every replica, so every statement
	// must tolerate already existing.
	schema := Schema()
	for _, statement := range strings.Split(schema, ";") {
		trimmed := strings.TrimSpace(statement)
		if trimmed == "" || strings.HasPrefix(trimmed, "--") {
			continue
		}
		// Strip leading comment lines.
		var meaningful []string
		for _, line := range strings.Split(trimmed, "\n") {
			if s := strings.TrimSpace(line); s != "" && !strings.HasPrefix(s, "--") {
				meaningful = append(meaningful, s)
			}
		}
		if len(meaningful) == 0 {
			continue
		}
		head := strings.ToUpper(meaningful[0])
		if strings.HasPrefix(head, "CREATE") && !strings.Contains(head, "IF NOT EXISTS") {
			t.Errorf("non-idempotent statement: %s", meaningful[0])
		}
	}
}

func TestIsUniqueViolationRecognisesDriverSpellings(t *testing.T) {
	// The module has no driver dependency, so the SQLSTATE is matched in
	// the rendered text; cover the spellings the common drivers produce.
	for _, message := range []string{
		`ERROR: duplicate key value violates unique constraint "cloud_users_email_key" (SQLSTATE 23505)`,
		`pq: duplicate key value violates unique constraint`,
		`UNIQUE constraint failed: cloud_users.email`,
	} {
		if !isUniqueViolation(errors.New(message)) {
			t.Errorf("not recognised as a unique violation: %s", message)
		}
	}
	if isUniqueViolation(nil) {
		t.Error("nil must not be a unique violation")
	}
	if isUniqueViolation(errors.New("connection refused")) {
		t.Error("an unrelated error must not be a unique violation")
	}
}

func TestNonZeroTimeFallsBack(t *testing.T) {
	fallback := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	if got := nonZeroTime(time.Time{}, fallback); !got.Equal(fallback) {
		t.Fatalf("zero value did not fall back: %s", got)
	}
	value := time.Date(2026, 5, 5, 0, 0, 0, 0, time.UTC)
	if got := nonZeroTime(value, fallback); !got.Equal(value) {
		t.Fatalf("non-zero value was replaced: %s", got)
	}
}

func TestNullableTime(t *testing.T) {
	if nullableTime(time.Time{}) != nil {
		t.Fatal("a zero time must map to SQL NULL")
	}
	if nullableTime(time.Now()) == nil {
		t.Fatal("a real time must not map to NULL")
	}
}

func TestOrEmptyHelpersNeverReturnNil(t *testing.T) {
	// JSONB columns are NOT NULL with a default; encoding a nil Go value
	// would write the literal `null` and violate that.
	if orEmptyMap(nil) == nil {
		t.Fatal("orEmptyMap returned nil")
	}
	if orEmptySlice(nil) == nil {
		t.Fatal("orEmptySlice returned nil")
	}
	payload := map[string]any{"a": 1}
	if got := orEmptyMap(payload); len(got) != 1 {
		t.Fatalf("orEmptyMap altered a real payload: %v", got)
	}
}

func TestTruncateRespectsRuneBoundaries(t *testing.T) {
	if got := truncate("hello", 100); got != "hello" {
		t.Fatalf("short strings must pass through: %q", got)
	}
	if got := truncate("hello", 3); got != "hel" {
		t.Fatalf("ASCII truncation: %q", got)
	}
	// "é" is two bytes: a limit of 3 must not split the second one.
	got := truncate("éé", 3)
	for _, r := range got {
		if r == '\uFFFD' {
			t.Fatalf("truncate split a rune: %q", got)
		}
	}
}

func TestTruncateAlwaysYieldsValidUTF8(t *testing.T) {
	// Sweep every cut point across mixed-width text: each result must be
	// valid UTF-8 and no longer than the limit.
	for _, input := range []string{"ééé", "あいう", "a😀b", "naïve café"} {
		for limit := 0; limit <= len(input)+2; limit++ {
			got := truncate(input, limit)
			if !utf8.ValidString(got) {
				t.Fatalf("truncate(%q, %d) = %q, which is not valid UTF-8", input, limit, got)
			}
			if len(got) > limit && len(input) > limit {
				t.Fatalf("truncate(%q, %d) = %q exceeds the limit", input, limit, got)
			}
		}
	}
}

func TestMustJSONEncodesAndDegrades(t *testing.T) {
	if got := string(mustJSON(map[string]string{"a": "b"})); got != `{"a":"b"}` {
		t.Fatalf("got %s", got)
	}
	// An unencodable value degrades to nil rather than panicking: an empty
	// event payload is recoverable, a panic in the fan-out path is not.
	if mustJSON(make(chan int)) != nil {
		t.Fatal("expected nil for an unencodable value")
	}
}

func TestJSONUnmarshalHelper(t *testing.T) {
	var state ContinuityState
	if err := jsonUnmarshal([]byte(`{"trackId":"t1","positionMs":42}`), &state); err != nil {
		t.Fatal(err)
	}
	if state.TrackID != "t1" || state.PositionMs != 42 {
		t.Fatalf("decoded %+v", state)
	}
	if err := jsonUnmarshal([]byte("not json"), &state); err == nil {
		t.Fatal("expected a decode error")
	}
}

func TestOpenPostgresRejectsNilDB(t *testing.T) {
	if _, err := OpenPostgres(t.Context(), nil, time.Now); err == nil {
		t.Fatal("expected an error for a nil *sql.DB")
	}
}

func TestConfigFromEnvDefaults(t *testing.T) {
	t.Setenv("SPOTIFLAC_POSTGRES_DSN", "")
	t.Setenv("SPOTIFLAC_REDIS_ADDR", "")
	t.Setenv("SPOTIFLAC_POSTGRES_DRIVER", "")

	cfg := ConfigFromEnv()
	// The zero-config default must stay "single process, in-memory": that
	// is the behaviour the repository shipped before this milestone.
	if cfg.PostgresDSN != "" || cfg.RedisAddr != "" {
		t.Fatalf("unexpected defaults: %+v", cfg)
	}
	if cfg.DriverName != "pgx" {
		t.Fatalf("driver default = %q", cfg.DriverName)
	}
	if cfg.MaxOpenConns <= 0 || cfg.ConnLifetime <= 0 {
		t.Fatalf("pool defaults are unset: %+v", cfg)
	}
}

func TestConfigFromEnvReadsValues(t *testing.T) {
	t.Setenv("SPOTIFLAC_POSTGRES_DSN", "  postgres://localhost/db  ")
	t.Setenv("SPOTIFLAC_REDIS_ADDR", "redis:6379")
	t.Setenv("SPOTIFLAC_POSTGRES_DRIVER", "pgx5")

	cfg := ConfigFromEnv()
	if cfg.PostgresDSN != "postgres://localhost/db" {
		t.Fatalf("DSN not trimmed: %q", cfg.PostgresDSN)
	}
	if cfg.RedisAddr != "redis:6379" || cfg.DriverName != "pgx5" {
		t.Fatalf("unexpected config: %+v", cfg)
	}
}

func TestBuildWithEmptyConfigIsInMemory(t *testing.T) {
	runtime, err := Build(t.Context(), Config{}, time.Now)
	if err != nil {
		t.Fatalf("empty config must succeed: %v", err)
	}
	defer func() { _ = runtime.Close() }()

	if runtime.Hub == nil {
		t.Fatal("the hub must exist even with no external dependencies")
	}
	if runtime.Storage != nil || runtime.Postgres != nil || runtime.Redis != nil {
		t.Fatal("no external dependency should have been created")
	}
}

func TestBuildFailsFastOnUnreachableRedis(t *testing.T) {
	// Silently degrading to in-memory would look healthy while discarding
	// user data; the deployment must crash-loop instead.
	_, err := Build(t.Context(), Config{RedisAddr: "127.0.0.1:1"}, time.Now)
	if err == nil {
		t.Fatal("expected a fatal error for an unreachable Redis")
	}
}

func TestRuntimeCloseIsNilSafeAndIdempotent(t *testing.T) {
	var nilRuntime *Runtime
	if err := nilRuntime.Close(); err != nil {
		t.Fatalf("nil receiver: %v", err)
	}
	runtime, err := Build(t.Context(), Config{}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := runtime.Close(); err != nil {
		t.Fatal(err)
	}
	if err := runtime.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}
}

func TestHubDeliverLocalDoesNotRepublish(t *testing.T) {
	publisher := &recordingPublisher{}
	hub := NewHub(publisher, time.Now)
	defer hub.Close()

	sub := hub.Subscribe("usr_1", "local")
	defer sub.Close()

	// Events arriving *from* Redis must not be published back to Redis, or
	// two processes would ping-pong the same event forever.
	hub.DeliverLocal("usr_1", NewSyncEvent("history", 1, "remote", time.Now()))

	select {
	case <-sub.Events():
	case <-time.After(time.Second):
		t.Fatal("DeliverLocal did not deliver")
	}
	if publisher.count() != 0 {
		t.Fatalf("DeliverLocal republished %d events", publisher.count())
	}
}
