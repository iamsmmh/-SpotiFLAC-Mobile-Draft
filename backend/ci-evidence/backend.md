# SpotiFLAC Cloud backend (vet & test) — evidence
- run: https://github.com/iamsmmh/-SpotiFLAC-Mobile-Draft/actions/runs/34404092675
- sha: 661ec0a97170f8a96626ca82d0a64c7ed3a518c1

## Steps
- success: Set up job
- success: Checkout repository
- success: Setup Go
- success: Check formatting
- success: Vet
- success: Staticcheck
- success: Run tests
- success: Run tests (race)
- : Record evidence (dispatch only)
- : Post Setup Go
- : Post Checkout repository

## gofmt
clean

## staticcheck

## go test
ok  	github.com/zarz/spotiflac_android/backend	0.346s	coverage: 13.6% of statements
ok  	github.com/zarz/spotiflac_android/backend/auth	0.662s	coverage: 58.6% of statements
ok  	github.com/zarz/spotiflac_android/backend/cloud	0.544s	coverage: 56.5% of statements
ok  	github.com/zarz/spotiflac_android/backend/collaboration	0.004s	coverage: 12.6% of statements
ok  	github.com/zarz/spotiflac_android/backend/devices	0.004s	coverage: 11.0% of statements
ok  	github.com/zarz/spotiflac_android/backend/history	0.004s	coverage: 58.0% of statements
	github.com/zarz/spotiflac_android/backend/internal/httpx		coverage: 0.0% of statements
	github.com/zarz/spotiflac_android/backend/marketplace		coverage: 0.0% of statements
ok  	github.com/zarz/spotiflac_android/backend/playlists	0.005s	coverage: 62.8% of statements
ok  	github.com/zarz/spotiflac_android/backend/settings	0.010s	coverage: 64.0% of statements
ok  	github.com/zarz/spotiflac_android/backend/sync	0.008s	coverage: 40.8% of statements
ok  	github.com/zarz/spotiflac_android/backend/telemetry	0.004s	coverage: 18.5% of statements
	github.com/zarz/spotiflac_android/backend/users		coverage: 0.0% of statements

## coverage
total:										(statements)			39.3%
