package cloud

import (
	"context"
	"time"
)

// SyncObserver implements sync.PushObserver: it writes the conflict-audit
// trail and wakes the user's other devices over the hub.
//
// It is attached with `syncHandler.SetObserver(cloud.NewSyncObserver(...))`,
// which is the only coupling between the two packages — and it points from
// the wiring code into both, so neither imports the other.
type SyncObserver struct {
	hub     *Hub
	storage SyncStorage
	// logAll records rejected pushes too. Rejections are the interesting
	// half of a conflict investigation, so it defaults on; deployments with
	// very chatty clients can turn it off to bound log growth.
	logAll bool
}

// NewSyncObserver builds the bridge. storage may be nil (events only).
func NewSyncObserver(hub *Hub, storage SyncStorage) *SyncObserver {
	return &SyncObserver{hub: hub, storage: storage, logAll: true}
}

// SetLogRejections controls whether losing pushes are recorded.
func (o *SyncObserver) SetLogRejections(enabled bool) { o.logAll = enabled }

// ObservePush records one record's resolution.
func (o *SyncObserver) ObservePush(
	ctx context.Context,
	userID, deviceID, scope, recordID string,
	revision int64,
	accepted, deleted bool,
	at time.Time,
) {
	if o.storage == nil {
		return
	}
	if !accepted && !o.logAll {
		return
	}

	resolution := ResolutionRejected
	switch {
	case accepted && deleted:
		resolution = ResolutionTombstone
	case accepted:
		resolution = ResolutionAccepted
	}

	// The audit trail is strictly diagnostic: a failure to write it must
	// never turn a successful sync into an error for the user.
	_ = o.storage.AppendSyncLog(ctx, SyncLogRow{
		UserID:     userID,
		DeviceID:   deviceID,
		Scope:      scope,
		RecordID:   recordID,
		Resolution: resolution,
		Revision:   revision,
		At:         at,
	})
}

// ObserveScopeAdvanced broadcasts the new watermark. The pushing device is
// the event Origin, so the hub suppresses its own echo.
func (o *SyncObserver) ObserveScopeAdvanced(
	ctx context.Context,
	userID, deviceID, scope string,
	revision int64,
	at time.Time,
) {
	if o.hub == nil {
		return
	}
	o.hub.Broadcast(ctx, userID, NewSyncEvent(scope, revision, deviceID, at))
}
