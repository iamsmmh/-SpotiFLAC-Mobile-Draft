package sync

import (
	"context"
	"time"
)

// PushObserver is notified after a push is applied, so the realtime layer
// can wake the user's other devices without `sync` importing `cloud` (which
// would be an import cycle once `cloud` grows a sync-log writer).
//
// It is an optional hook: a Handler with no observer behaves exactly as
// before, which is what keeps the existing tests and the in-memory
// deployment unchanged.
type PushObserver interface {
	// ObservePush reports one record's outcome. `revision` is the
	// authoritative server revision after the push.
	ObservePush(ctx context.Context, userID, deviceID, scope, recordID string, revision int64, accepted, deleted bool, at time.Time)

	// ObserveScopeAdvanced reports the new scope watermark once per push
	// that changed anything, so the fan-out is one event per push rather
	// than one per record.
	ObserveScopeAdvanced(ctx context.Context, userID, deviceID, scope string, revision int64, at time.Time)
}

// SetObserver attaches a push observer. Passing nil detaches it.
//
// This must be called during wiring, before the handler serves traffic:
// the field is read without a lock on the (hot) push path, and adding a
// mutex there to support reconfiguration at runtime would be a real cost
// for a capability nothing needs.
func (h *Handler) SetObserver(observer PushObserver) { h.observer = observer }

// DeviceHeader is the request header carrying the calling installation's id.
// Duplicated from the cloud package (rather than imported) to keep the
// dependency direction one-way.
const DeviceHeader = "X-Device-Id"
