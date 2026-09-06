package cloud

import "encoding/json"

// jsonUnmarshal is a thin alias kept in one place so the handler does not
// import encoding/json for a single call.
func jsonUnmarshal(data []byte, dst any) error { return json.Unmarshal(data, dst) }

// mustJSON encodes a value that is statically known to be encodable
// (string maps only). A failure would be a programming error, and an empty
// payload is a safe degradation for an event envelope, so it never panics.
func mustJSON(value any) json.RawMessage {
	raw, err := json.Marshal(value)
	if err != nil {
		return nil
	}
	return raw
}
