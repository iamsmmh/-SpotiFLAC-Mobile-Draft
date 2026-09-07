package gobackend

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"mime"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// Minimal read-only LAN web player.
//
// Serves the downloaded music folder over plain HTTP on the local network:
// a self-contained single-page player (no external assets) plus range-aware
// media streaming. Intentionally tiny: no accounts, no pairing, no writes,
// nothing outside the chosen root directory, and it never starts on its own —
// the user flips it on in Settings and it dies with the app. This is meant
// for casting your OWN files to a laptop/tablet/TV browser on the same
// network; it is not a cloud feature and the UI should say so.

type lanTrack struct {
	Index int    `json:"index"`
	Title string `json:"title"`
	Path  string `json:"-"`
	Ext   string `json:"-"`
}

type lanServerConfig struct {
	Port     int    `json:"port"`
	Root     string `json:"root"`
	Pin      string `json:"pin,omitempty"`
	CertFile string `json:"certFile,omitempty"`
	KeyFile  string `json:"keyFile,omitempty"`
}

var lanWebPlayer struct {
	mu       sync.Mutex
	server   *http.Server
	listener net.Listener
	root     string
	port     int
	running  bool
}

var lanAudioExtensions = map[string]bool{
	".flac": true, ".mp3": true, ".m4a": true, ".aac": true,
	".ogg": true, ".opus": true, ".wav": true, ".aiff": true, ".aif": true,
}

func init() {
	for ext, typ := range map[string]string{
		".flac": "audio/flac", ".m4a": "audio/mp4", ".opus": "audio/opus",
		".aiff": "audio/aiff", ".aif": "audio/aiff", ".aac": "audio/aac",
	} {
		_ = mime.AddExtensionType(ext, typ)
	}
}

// scanLanTracks lists playable files under root. The returned list is the
// ONLY thing the /media endpoint can serve (index-addressed, never a raw
// path), so path traversal is structurally impossible.
func scanLanTracks(root string) []lanTrack {
	var tracks []lanTrack
	maxTracks := 2000
	_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			if info != nil && info.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if info.IsDir() {
			depth, relErr := filepath.Rel(root, path)
			if relErr == nil && depth != "." && strings.Count(depth, string(filepath.Separator)) >= 4 {
				return filepath.SkipDir
			}
			return nil
		}
		ext := strings.ToLower(filepath.Ext(path))
		if !lanAudioExtensions[ext] || info.Size() <= 0 {
			return nil
		}
		name := strings.TrimSuffix(info.Name(), filepath.Ext(info.Name()))
		title := name
		if parts := strings.SplitN(name, " - ", 2); len(parts) == 2 {
			title = parts[1] + " \u2014 " + parts[0]
		}
		tracks = append(tracks, lanTrack{Index: len(tracks), Title: title, Path: path, Ext: ext})
		if len(tracks) >= maxTracks {
			return filepath.SkipAll
		}
		return nil
	})
	sort.Slice(tracks, func(i, j int) bool { return tracks[i].Title < tracks[j].Title })
	for i := range tracks {
		tracks[i].Index = i
	}
	return tracks
}

func lanLANAddresses() []string {
	var urls []string
	ifaces, err := net.Interfaces()
	if err != nil {
		return urls
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipNet, ok := addr.(*net.IPNet)
			if !ok || ipNet.IP.To4() == nil {
				continue
			}
			ip := ipNet.IP.To4()
			if !ip.IsPrivate() {
				continue
			}
			urls = append(urls, fmt.Sprintf("http://%s:%d", ip, lanWebPlayerPort()))
		}
	}
	return urls
}

func lanWebPlayerPort() int {
	lanWebPlayer.mu.Lock()
	defer lanWebPlayer.mu.Unlock()
	return lanWebPlayer.port
}

const lanPlayerPage = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SpotiFLAC LAN Player</title>
<style>
:root{color-scheme:dark}body{font:15px/1.5 system-ui;background:#101014;color:#eee;margin:0;padding:16px}
h1{font-size:18px;margin:4px 0 14px}.t{padding:9px 10px;border-bottom:1px solid #2a2a33;cursor:pointer;border-radius:8px}
.t:hover{background:#1b1b23}.t.on{background:#23233a}audio{width:100%;position:sticky;bottom:0;background:#101014;padding:8px 0}
#n{color:#888;font-size:13px}
</style></head><body>
<h1>SpotiFLAC LAN Player <span id="n"></span></h1>
<div id="list"></div>
<audio id="a" controls></audio>
<script>
const list=document.getElementById('list'),audio=document.getElementById('a'),n=document.getElementById('n');
let current=-1;
async function load(){
  const tracks=await (await fetch('/api/tracks')).json();
  n.textContent='('+tracks.length+' files)';
  list.innerHTML='';
  tracks.forEach((t,i)=>{
    const d=document.createElement('div');d.className='t';d.textContent=t.title;
    d.onclick=()=>{current=i;d.blur();audio.src='/media?i='+i;audio.play();
      document.querySelectorAll('.t.on').forEach(x=>x.classList.remove('on'));d.classList.add('on');};
    list.appendChild(d);
  });
}
audio.addEventListener('ended',()=>{
  const next=list.children[current+1];if(next){next.click();}
});
load();
</script></body></html>`

func lanMux(root string) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(lanPlayerPage))
	})
	mux.HandleFunc("/api/tracks", func(w http.ResponseWriter, r *http.Request) {
		tracks := scanLanTracks(root)
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		_ = json.NewEncoder(w).Encode(tracks)
	})
	mux.HandleFunc("/media", func(w http.ResponseWriter, r *http.Request) {
		idx, err := strconv.Atoi(r.URL.Query().Get("i"))
		tracks := scanLanTracks(root)
		if err != nil || idx < 0 || idx >= len(tracks) {
			http.NotFound(w, r)
			return
		}
		track := tracks[idx]
		f, err := os.Open(track.Path)
		if err != nil {
			http.Error(w, "cannot open file", http.StatusNotFound)
			return
		}
		defer f.Close()
		info, err := f.Stat()
		if err != nil {
			http.Error(w, "cannot stat file", http.StatusNotFound)
			return
		}
		http.ServeContent(w, r, info.Name(), info.ModTime(), f)
	})
	return mux
}

func lanTokenForPin(pin string) string {
	sum := sha256.Sum256([]byte("spotiflac-lan-v1|" + pin))
	return hex.EncodeToString(sum[:])
}

func lanConstEq(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

func lanAuthorized(r *http.Request, pin, token string) bool {
	if lanConstEq(r.Header.Get("X-SpotiFLAC-Pin"), pin) {
		return true
	}
	auth := r.Header.Get("Authorization")
	if len(auth) >= 7 && strings.EqualFold(auth[:7], "Bearer ") {
		if lanConstEq(strings.TrimSpace(auth[7:]), token) {
			return true
		}
	}
	if c, err := r.Cookie("spotiflac_lan"); err == nil && lanConstEq(c.Value, token) {
		return true
	}
	if q := r.URL.Query().Get("pin"); q != "" && lanConstEq(q, pin) {
		return true
	}
	return false
}

// lanSecureMux wraps [lanMux] with PIN / bearer / cookie auth and a
// read-only method gate. When [pin] is empty the inner mux is returned
// unchanged so existing tests keep exercising the open player.
func lanSecureMux(root, pin string) http.Handler {
	inner := lanMux(root)
	expected := strings.TrimSpace(pin)
	if expected == "" {
		return inner
	}
	token := lanTokenForPin(expected)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet, http.MethodHead, http.MethodOptions:
		default:
			http.Error(w, "read-only", http.StatusMethodNotAllowed)
			return
		}
		if !lanAuthorized(r, expected, token) {
			w.Header().Set("WWW-Authenticate", `Bearer realm="spotiflac-lan"`)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		http.SetCookie(w, &http.Cookie{
			Name:     "spotiflac_lan",
			Value:    token,
			Path:     "/",
			HttpOnly: true,
			SameSite: http.SameSiteStrictMode,
		})
		inner.ServeHTTP(w, r)
	})
}

// StartLanWebPlayer boots the server. configJSON: {"port":0,"root":"/dir"};
// port 0 lets the OS pick a free one. Idempotent per root/port. Returns the
// same JSON shape as GetLanWebPlayerStatus.
func StartLanWebPlayer(configJSON string) (bridgeOut string, bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeOut, bridgeErr = "", r
		}
	}()

	var cfg lanServerConfig
	if err := json.Unmarshal([]byte(configJSON), &cfg); err != nil {
		return "", fmt.Errorf("invalid config: %w", err)
	}
	if strings.TrimSpace(cfg.Root) == "" {
		return "", fmt.Errorf("root directory is required")
	}
	info, err := os.Stat(cfg.Root)
	if err != nil || !info.IsDir() {
		return "", fmt.Errorf("root is not a readable directory")
	}

	lanWebPlayer.mu.Lock()
	if lanWebPlayer.running {
		lanWebPlayer.mu.Unlock()
		return GetLanWebPlayerStatus(), nil
	}
	addr := net.JoinHostPort("0.0.0.0", strconv.Itoa(cfg.Port))
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		lanWebPlayer.mu.Unlock()
		return "", fmt.Errorf("could not bind %s: %w", addr, err)
	}
	var handler http.Handler
	if strings.TrimSpace(cfg.Pin) != "" {
		handler = lanSecureMux(cfg.Root, cfg.Pin)
	} else {
		handler = lanMux(cfg.Root)
	}
	srv := &http.Server{Handler: handler}
	certFile := strings.TrimSpace(cfg.CertFile)
	keyFile := strings.TrimSpace(cfg.KeyFile)
	lanWebPlayer.server = srv
	lanWebPlayer.listener = ln
	lanWebPlayer.root = cfg.Root
	lanWebPlayer.port = ln.Addr().(*net.TCPAddr).Port
	lanWebPlayer.running = true
	lanWebPlayer.mu.Unlock()

	go func() {
		defer func() { _ = recoverBridgePanic(recover()) }()
		if certFile != "" && keyFile != "" {
			_ = srv.ServeTLS(ln, certFile, keyFile)
			return
		}
		_ = srv.Serve(ln)
	}()

	return GetLanWebPlayerStatus(), nil
}

// StopLanWebPlayer shuts the server down; safe to call when not running.
func StopLanWebPlayer() (bridgeErr error) {
	defer func() {
		if r := recoverBridgePanic(recover()); r != nil {
			bridgeErr = r
		}
	}()

	lanWebPlayer.mu.Lock()
	defer lanWebPlayer.mu.Unlock()
	if !lanWebPlayer.running {
		return nil
	}
	if lanWebPlayer.server != nil {
		_ = lanWebPlayer.server.Close()
	}
	lanWebPlayer.server = nil
	lanWebPlayer.listener = nil
	lanWebPlayer.running = false
	lanWebPlayer.root = ""
	lanWebPlayer.port = 0
	return nil
}

// GetLanWebPlayerStatus reports the live state for the settings UI.
func GetLanWebPlayerStatus() (bridgeOut string) {
	defer func() { _ = recoverBridgePanic(recover()) }()

	lanWebPlayer.mu.Lock()
	running := lanWebPlayer.running
	root := lanWebPlayer.root
	port := lanWebPlayer.port
	lanWebPlayer.mu.Unlock()

	count := 0
	if running {
		count = len(scanLanTracks(root))
	}
	var urls []string
	if running {
		urls = lanLANAddresses()
	}
	out, _ := json.Marshal(map[string]any{
		"running": running,
		"port":    port,
		"root":    root,
		"urls":    urls,
		"tracks":  count,
	})
	return string(out)
}
