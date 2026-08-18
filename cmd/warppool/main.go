// warppool: aggregate SOCKS5 RR + minimal control HTTP API
package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		fatalUsage()
	}
	switch os.Args[1] {
	case "aggregate":
		runAggregate(os.Args[2:])
	case "control":
		runControl(os.Args[2:])
	case "expose":
		// TCP relay: warp-cli proxy only binds 127.0.0.1; publish via 0.0.0.0
		runExpose(os.Args[2:])
	default:
		fatalUsage()
	}
}

func fatalUsage() {
	fmt.Fprintf(os.Stderr, "usage:\n  warppool aggregate --listen :1080 --healthy /data/state/healthy.json\n  warppool control --listen 127.0.0.1:9090 --data /data --scripts /opt/warp-pool/scripts [--web /opt/warp-pool/web] [--token T]\n  warppool expose --listen 0.0.0.0:11000 --backend 10.200.0.2:40000\n")
	os.Exit(2)
}

// runExpose is a dumb TCP proxy so host-published ports can reach warp's loopback SOCKS.
func runExpose(args []string) {
	listen := ""
	backend := ""
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--listen":
			i++
			if i < len(args) {
				listen = args[i]
			}
		case "--backend":
			i++
			if i < len(args) {
				backend = args[i]
			}
		}
	}
	if listen == "" || backend == "" {
		fatalUsage()
	}
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		log.Fatalf("expose listen %s: %v", listen, err)
	}
	log.Printf("expose %s -> %s", listen, backend)
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Printf("expose accept: %v", err)
			continue
		}
		go func(client net.Conn) {
			defer client.Close()
			up, err := net.DialTimeout("tcp", backend, 10*time.Second)
			if err != nil {
				return
			}
			defer up.Close()
			errc := make(chan struct{}, 2)
			go func() { _, _ = io.Copy(up, client); errc <- struct{}{} }()
			go func() { _, _ = io.Copy(client, up); errc <- struct{}{} }()
			<-errc
		}(c)
	}
}

type healthyFile struct {
	Backends []backend `json:"backends"`
}

type backend struct {
	ID   int    `json:"id"`
	Addr string `json:"addr"`
}

// stickyState is global sticky routing; missing file = RR.
type stickyState struct {
	ID int    `json:"id"`
	TS string `json:"ts"`
}

func loadHealthy(path string) ([]backend, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var hf healthyFile
	if err := json.Unmarshal(b, &hf); err != nil {
		return nil, err
	}
	out := make([]backend, 0, len(hf.Backends))
	for _, x := range hf.Backends {
		if x.Addr != "" {
			out = append(out, x)
		}
	}
	return out, nil
}

func runAggregate(args []string) {
	listen := ":1080"
	healthy := "/data/state/healthy.json"
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--listen":
			i++
			if i < len(args) {
				listen = args[i]
			}
		case "--healthy":
			i++
			if i < len(args) {
				healthy = args[i]
			}
		}
	}

	stateDir := filepath.Dir(healthy)
	stickyPath := filepath.Join(stateDir, "sticky.json")
	aggPath := filepath.Join(stateDir, "agg_enabled")

	var rr uint64
	var mu sync.Mutex
	var cached []backend
	var cachedAt time.Time

	var stickyMu sync.Mutex
	var stickyCached *stickyState
	var stickyCachedAt time.Time
	var stickyLoaded bool

	var aggMu sync.Mutex
	var aggCached bool
	var aggCachedAt time.Time
	var aggLoaded bool

	getBackends := func() []backend {
		mu.Lock()
		defer mu.Unlock()
		if time.Since(cachedAt) < 2*time.Second && len(cached) > 0 {
			return append([]backend(nil), cached...)
		}
		list, err := loadHealthy(healthy)
		if err != nil || len(list) == 0 {
			return append([]backend(nil), cached...)
		}
		cached = list
		cachedAt = time.Now()
		return append([]backend(nil), cached...)
	}

	getSticky := func() *stickyState {
		stickyMu.Lock()
		defer stickyMu.Unlock()
		if stickyLoaded && time.Since(stickyCachedAt) < 2*time.Second {
			if stickyCached == nil {
				return nil
			}
			cp := *stickyCached
			return &cp
		}
		st, err := loadSticky(stickyPath)
		stickyCachedAt = time.Now()
		stickyLoaded = true
		if err != nil {
			stickyCached = nil
			return nil
		}
		stickyCached = st
		cp := *st
		return &cp
	}

	getAggEnabled := func() bool {
		aggMu.Lock()
		defer aggMu.Unlock()
		if aggLoaded && time.Since(aggCachedAt) < 2*time.Second {
			return aggCached
		}
		aggCached = loadAggEnabled(aggPath)
		aggCachedAt = time.Now()
		aggLoaded = true
		return aggCached
	}

	ln, err := net.Listen("tcp", listen)
	if err != nil {
		log.Fatalf("aggregate listen: %v", err)
	}
	log.Printf("aggregate socks5 on %s (healthy=%s)", listen, healthy)

	for {
		c, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		routeLog := filepath.Join(stateDir, "route.jsonl")
		go serveSocks(c, &rr, getBackends, getSticky, getAggEnabled, routeLog)
	}
}

func loadSticky(path string) (*stickyState, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var st stickyState
	if err := json.Unmarshal(b, &st); err != nil {
		return nil, err
	}
	if st.ID < 0 {
		return nil, errors.New("invalid sticky id")
	}
	return &st, nil
}

// loadAggEnabled: missing file = enabled (true); content "0"/"false" = off.
func loadAggEnabled(path string) bool {
	b, err := os.ReadFile(path)
	if err != nil {
		return true
	}
	s := strings.TrimSpace(string(b))
	if s == "0" || strings.EqualFold(s, "false") {
		return false
	}
	return true
}

func clientHost(addr net.Addr) string {
	if addr == nil {
		return ""
	}
	s := addr.String()
	if h, _, err := net.SplitHostPort(s); err == nil {
		return h
	}
	return s
}

var routeLogMu sync.Mutex

// appendRouteLog records one successful aggregate selection (not byte counters).
func appendRouteLog(path, src, target string, backendID int, via string) {
	if path == "" {
		return
	}
	line := fmt.Sprintf(`{"ts":"%s","src":%q,"target":%q,"backend_id":%d,"via":%q}`+"\n",
		time.Now().UTC().Format(time.RFC3339), src, target, backendID, via)
	routeLogMu.Lock()
	defer routeLogMu.Unlock()
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	_, _ = f.WriteString(line)
	_ = f.Close()
	// cheap trim: if > ~2MB keep last 1500 lines
	if st, err := os.Stat(path); err == nil && st.Size() > 2<<20 {
		b, err := os.ReadFile(path)
		if err != nil {
			return
		}
		lines := strings.Split(string(b), "\n")
		if len(lines) > 1500 {
			keep := strings.Join(lines[len(lines)-1500:], "\n")
			_ = os.WriteFile(path, []byte(keep), 0o644)
		}
	}
}

func serveSocks(client net.Conn, rr *uint64, get func() []backend, getSticky func() *stickyState, getAgg func() bool, routeLog string) {
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(30 * time.Second))
	src := clientHost(client.RemoteAddr())

	buf := make([]byte, 258)
	if _, err := io.ReadFull(client, buf[:2]); err != nil {
		return
	}
	if buf[0] != 0x05 {
		return
	}
	nmethods := int(buf[1])
	if _, err := io.ReadFull(client, buf[:nmethods]); err != nil {
		return
	}
	if _, err := client.Write([]byte{0x05, 0x00}); err != nil {
		return
	}

	if _, err := io.ReadFull(client, buf[:4]); err != nil {
		return
	}
	if buf[0] != 0x05 || buf[1] != 0x01 {
		_, _ = client.Write([]byte{0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	var host string
	var port uint16
	switch buf[3] {
	case 0x01:
		if _, err := io.ReadFull(client, buf[:4]); err != nil {
			return
		}
		host = net.IP(buf[:4]).String()
	case 0x03:
		if _, err := io.ReadFull(client, buf[:1]); err != nil {
			return
		}
		l := int(buf[0])
		if _, err := io.ReadFull(client, buf[:l]); err != nil {
			return
		}
		host = string(buf[:l])
	case 0x04:
		if _, err := io.ReadFull(client, buf[:16]); err != nil {
			return
		}
		host = net.IP(buf[:16]).String()
	default:
		_, _ = client.Write([]byte{0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	if _, err := io.ReadFull(client, buf[:2]); err != nil {
		return
	}
	port = binary.BigEndian.Uint16(buf[:2])
	target := net.JoinHostPort(host, strconv.Itoa(int(port)))

	if !getAgg() {
		_, _ = client.Write([]byte{0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}

	backends := get()
	if len(backends) == 0 {
		_, _ = client.Write([]byte{0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}

	// sticky: try matching backend first; dial fail or missing → RR
	if st := getSticky(); st != nil {
		for _, b := range backends {
			if b.ID != st.ID {
				continue
			}
			remote, err := dialViaSocks(b.Addr, target)
			if err == nil {
				appendRouteLog(routeLog, src, target, b.ID, "sticky")
				_, _ = client.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
				_ = client.SetDeadline(time.Time{})
				_ = remote.SetDeadline(time.Time{})
				relay(client, remote)
				return
			}
			break
		}
	}

	var lastErr error
	n := len(backends)
	start := int(atomic.AddUint64(rr, 1)-1) % n
	for i := 0; i < n; i++ {
		b := backends[(start+i)%n]
		remote, err := dialViaSocks(b.Addr, target)
		if err != nil {
			lastErr = err
			continue
		}
		appendRouteLog(routeLog, src, target, b.ID, "rr")
		_, _ = client.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		_ = client.SetDeadline(time.Time{})
		_ = remote.SetDeadline(time.Time{})
		relay(client, remote)
		return
	}
	log.Printf("all backends failed for %s: %v", target, lastErr)
	_, _ = client.Write([]byte{0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
}

func dialViaSocks(proxyAddr, target string) (net.Conn, error) {
	c, err := net.DialTimeout("tcp", proxyAddr, 5*time.Second)
	if err != nil {
		return nil, err
	}
	_ = c.SetDeadline(time.Now().Add(15 * time.Second))
	if _, err := c.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		c.Close()
		return nil, err
	}
	resp := make([]byte, 2)
	if _, err := io.ReadFull(c, resp); err != nil {
		c.Close()
		return nil, err
	}
	if resp[0] != 0x05 || resp[1] != 0x00 {
		c.Close()
		return nil, errors.New("socks auth rejected")
	}

	host, portStr, err := net.SplitHostPort(target)
	if err != nil {
		c.Close()
		return nil, err
	}
	port, _ := strconv.Atoi(portStr)
	req := []byte{0x05, 0x01, 0x00}
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			req = append(req, 0x01)
			req = append(req, v4...)
		} else {
			req = append(req, 0x04)
			req = append(req, ip.To16()...)
		}
	} else {
		if len(host) > 255 {
			c.Close()
			return nil, errors.New("host too long")
		}
		req = append(req, 0x03, byte(len(host)))
		req = append(req, host...)
	}
	var pb [2]byte
	binary.BigEndian.PutUint16(pb[:], uint16(port))
	req = append(req, pb[:]...)
	if _, err := c.Write(req); err != nil {
		c.Close()
		return nil, err
	}
	hdr := make([]byte, 4)
	if _, err := io.ReadFull(c, hdr); err != nil {
		c.Close()
		return nil, err
	}
	if hdr[1] != 0x00 {
		c.Close()
		return nil, fmt.Errorf("socks connect status %d", hdr[1])
	}
	switch hdr[3] {
	case 0x01:
		_, err = io.ReadFull(c, make([]byte, 4+2))
	case 0x03:
		l := make([]byte, 1)
		if _, err = io.ReadFull(c, l); err == nil {
			_, err = io.ReadFull(c, make([]byte, int(l[0])+2))
		}
	case 0x04:
		_, err = io.ReadFull(c, make([]byte, 16+2))
	}
	if err != nil {
		c.Close()
		return nil, err
	}
	_ = c.SetDeadline(time.Time{})
	return c, nil
}

func relay(a, b net.Conn) {
	defer a.Close()
	defer b.Close()
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(a, b); done <- struct{}{} }()
	go func() { _, _ = io.Copy(b, a); done <- struct{}{} }()
	<-done
}

func runControl(args []string) {
	listen := "127.0.0.1:9090"
	data := "/data"
	scripts := "/opt/warp-pool/scripts"
	webRoot := os.Getenv("WEB_ROOT")
	if webRoot == "" {
		webRoot = "/opt/warp-pool/web"
	}
	token := os.Getenv("CONTROL_TOKEN")
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--listen":
			i++
			if i < len(args) {
				listen = args[i]
			}
		case "--data":
			i++
			if i < len(args) {
				data = args[i]
			}
		case "--scripts":
			i++
			if i < len(args) {
				scripts = args[i]
			}
		case "--token":
			i++
			if i < len(args) {
				token = args[i]
			}
		case "--web":
			i++
			if i < len(args) {
				webRoot = args[i]
			}
		}
	}

	host, _, err := net.SplitHostPort(listen)
	if err == nil && host != "" && host != "127.0.0.1" && host != "::1" && host != "localhost" {
		if strings.TrimSpace(token) == "" {
			log.Fatalf("CONTROL_BIND is non-loopback (%s) but CONTROL_TOKEN is empty — refusing to start", host)
		}
	}

	// apply any prior hot config so child scripts see it via os.Environ()
	_ = applyRuntimeConfig(data)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if !authOK(r, token) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		writeJSON(w, readHealth(data))
	})
	mux.HandleFunc("/config", func(w http.ResponseWriter, r *http.Request) {
		if !authOK(r, token) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		switch r.Method {
		case http.MethodGet:
			writeJSON(w, getConfig(listen, token))
		case http.MethodPut:
			handlePutConfig(w, r, data, listen, token)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	})
	mux.HandleFunc("/instances", func(w http.ResponseWriter, r *http.Request) {
		if !authOK(r, token) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		switch r.Method {
		case http.MethodGet:
			writeJSON(w, readInstances(data))
		case http.MethodPost:
			handlePostInstances(w, r, data)
		case http.MethodDelete:
			handleDeleteInstance(w, r, data, scripts)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	})
	mux.HandleFunc("/ip-history", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !authOK(r, token) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		id := intFrom(r.URL.Query().Get("id"))
		limit := intFrom(r.URL.Query().Get("limit"))
		if limit <= 0 {
			limit = 50
		}
		writeJSON(w, readIPHistory(data, id, limit))
	})
	mux.HandleFunc("/routes", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !authOK(r, token) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		limit := intFrom(r.URL.Query().Get("limit"))
		if limit <= 0 {
			limit = 100
		}
		writeJSON(w, readJSONLTail(filepath.Join(data, "state", "route.jsonl"), limit))
	})
	mux.HandleFunc("/rotate", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !authOK(r, token) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		q := r.URL.Query()
		mode := q.Get("mode")
		if mode == "" {
			mode = "restart" // v0.3 default; soft|reconnect alias → restart in rotate-instance.sh
		}
		script := filepath.Join(scripts, "rotate-instance.sh")
		var cmd *exec.Cmd
		if q.Get("all") == "1" {
			cmd = exec.Command("/bin/bash", script, "all", mode)
		} else {
			id := q.Get("id")
			if id == "" {
				http.Error(w, "missing id", http.StatusBadRequest)
				return
			}
			cmd = exec.Command("/bin/bash", script, id, mode)
		}
		cmd.Env = os.Environ()
		// File stdout/stderr — CombinedOutput pipes hang if child daemons inherit the pipe
		logFile := filepath.Join(os.TempDir(), fmt.Sprintf("warppool-rotate-%d.log", time.Now().UnixNano()))
		f, err := os.Create(logFile)
		if err != nil {
			http.Error(w, "log create: "+err.Error(), http.StatusInternalServerError)
			return
		}
		cmd.Stdout = f
		cmd.Stderr = f
		err = cmd.Run()
		_, _ = f.Seek(0, 0)
		out, _ := io.ReadAll(f)
		_ = f.Close()
		_ = os.Remove(logFile)
		msg := string(out)
		if err != nil {
			status := http.StatusInternalServerError
			resp := map[string]any{"ok": false, "error": err.Error(), "output": msg}
			if strings.Contains(msg, "cooldown") {
				status = http.StatusTooManyRequests
			}
			if strings.Contains(msg, "not found") {
				status = http.StatusNotFound
			}
			if strings.Contains(msg, "v4_collision") {
				status = http.StatusConflict
				resp["reason"] = "v4_collision"
			}
			if a := parseAttempts(msg); a > 0 {
				resp["attempts"] = a
			}
			if v4 := parseV4FromOutput(msg); v4 != "" {
				resp["v4"] = v4
			}
			w.WriteHeader(status)
			writeJSON(w, resp)
			return
		}
		okResp := map[string]any{"ok": true, "output": msg, "unique": true}
		if a := parseAttempts(msg); a > 0 {
			okResp["attempts"] = a
		}
		if v4 := parseV4FromOutput(msg); v4 != "" {
			okResp["v4"] = v4
		}
		writeJSON(w, okResp)
	})
	mux.HandleFunc("/healthcheck", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !authOK(r, token) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		script := filepath.Join(scripts, "health-once.sh")
		cmd := exec.Command("/bin/bash", script)
		cmd.Env = os.Environ()
		out, err := cmd.CombinedOutput()
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			writeJSON(w, map[string]any{"ok": false, "error": err.Error(), "output": string(out)})
			return
		}
		writeJSON(w, map[string]any{"ok": true, "output": string(out)})
	})
	mux.HandleFunc("/pool", func(w http.ResponseWriter, r *http.Request) {
		if !authOK(r, token) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		writeJSON(w, readPool(data))
	})
	mux.HandleFunc("/pool/membership", func(w http.ResponseWriter, r *http.Request) {
		if !authOK(r, token) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		handlePoolMembership(w, r, data, scripts)
	})
	mux.HandleFunc("/pool/sticky", func(w http.ResponseWriter, r *http.Request) {
		if !authOK(r, token) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		handlePoolSticky(w, r, data)
	})

	// single-page UI — no auth needed (static HTML; API calls handle auth via token param)
	indexPath := filepath.Join(webRoot, "index.html")
	serveUI := func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, indexPath)
	}
	mux.HandleFunc("/ui", serveUI)
	mux.HandleFunc("/ui/", serveUI)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		http.ServeFile(w, r, indexPath)
	})

	srv := &http.Server{Addr: listen, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	log.Printf("control api on %s web=%s", listen, webRoot)
	log.Fatal(srv.ListenAndServe())
}

func parseAttempts(msg string) int {
	const key = "attempts="
	idx := strings.LastIndex(msg, key)
	if idx < 0 {
		return 0
	}
	rest := msg[idx+len(key):]
	n := 0
	for _, c := range rest {
		if c < '0' || c > '9' {
			break
		}
		n = n*10 + int(c-'0')
	}
	return n
}

func parseV4FromOutput(msg string) string {
	// prefer "v4=1.2.3.4" tokens from rotate logs
	const key = "v4="
	idx := strings.LastIndex(msg, key)
	if idx < 0 {
		return ""
	}
	rest := msg[idx+len(key):]
	end := 0
	for end < len(rest) {
		c := rest[end]
		if (c >= '0' && c <= '9') || c == '.' {
			end++
			continue
		}
		break
	}
	if end == 0 {
		return ""
	}
	return rest[:end]
}

func authOK(r *http.Request, token string) bool {
	if strings.TrimSpace(token) == "" {
		return true
	}
	h := r.Header.Get("Authorization")
	if strings.HasPrefix(h, "Bearer ") && strings.TrimPrefix(h, "Bearer ") == token {
		return true
	}
	return r.URL.Query().Get("token") == token
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
}

func readHealth(data string) map[string]any {
	inst := readInstances(data)
	total := len(inst)
	okn := 0
	for _, it := range inst {
		if m, ok := it["healthy"].(bool); ok && m {
			okn++
		}
	}
	status := "ok"
	if total == 0 || okn == 0 {
		status = "down"
	} else if okn < total {
		status = "degraded"
	}
	return map[string]any{
		"status":  status,
		"healthy": okn,
		"total":   total,
		"ts":      time.Now().UTC().Format(time.RFC3339),
	}
}

func readInstances(data string) []map[string]any {
	dir := filepath.Join(data, "instances")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []map[string]any
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		id, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		metaPath := filepath.Join(dir, e.Name(), "meta.json")
		m := map[string]any{"id": id, "healthy": false}
		if b, err := os.ReadFile(metaPath); err == nil {
			_ = json.Unmarshal(b, &m)
			m["id"] = id
		}
		// old meta without pooled key → default true
		if _, ok := m["pooled"]; !ok {
			m["pooled"] = true
		}
		out = append(out, m)
	}
	return out
}

func intFrom(v any) int {
	switch x := v.(type) {
	case float64:
		return int(x)
	case float32:
		return int(x)
	case int:
		return x
	case int64:
		return int(x)
	case json.Number:
		n, _ := x.Int64()
		return int(n)
	case string:
		n, _ := strconv.Atoi(strings.TrimSpace(x))
		return n
	default:
		return 0
	}
}

// readJSONLTail returns last n JSON objects from a jsonl file (newest last).
func readJSONLTail(path string, limit int) []map[string]any {
	if limit <= 0 {
		limit = 100
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return []map[string]any{}
	}
	rawLines := strings.Split(string(b), "\n")
	var lines []string
	for _, ln := range rawLines {
		ln = strings.TrimSpace(ln)
		if ln != "" {
			lines = append(lines, ln)
		}
	}
	if len(lines) > limit {
		lines = lines[len(lines)-limit:]
	}
	out := make([]map[string]any, 0, len(lines))
	for _, ln := range lines {
		var m map[string]any
		if json.Unmarshal([]byte(ln), &m) == nil {
			out = append(out, m)
		}
	}
	return out
}

func readIPHistory(data string, id, limit int) map[string]any {
	if id < 0 {
		return map[string]any{"id": id, "entries": []any{}}
	}
	path := filepath.Join(data, "instances", strconv.Itoa(id), "ip-history.jsonl")
	return map[string]any{
		"id":      id,
		"entries": readJSONLTail(path, limit),
	}
}

func truncate(s string, n int) string {
	if n <= 0 || len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

func appendPoolLog(data, msg string) {
	dir := filepath.Join(data, "logs")
	_ = os.MkdirAll(dir, 0o755)
	line := time.Now().UTC().Format(time.RFC3339) + " " + msg + "\n"
	f, err := os.OpenFile(filepath.Join(dir, "pool.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	_, _ = f.WriteString(line)
	_ = f.Close()
}

func stickyPath(data string) string {
	return filepath.Join(data, "state", "sticky.json")
}

func aggEnabledPath(data string) string {
	return filepath.Join(data, "state", "agg_enabled")
}

func boolFrom(v any) (bool, bool) {
	switch x := v.(type) {
	case bool:
		return x, true
	case float64:
		return x != 0, true
	case string:
		s := strings.TrimSpace(strings.ToLower(x))
		if s == "1" || s == "true" {
			return true, true
		}
		if s == "0" || s == "false" {
			return false, true
		}
		return false, false
	default:
		return false, false
	}
}

func readPool(data string) map[string]any {
	healthyPath := filepath.Join(data, "state", "healthy.json")
	backends, _ := loadHealthy(healthyPath)
	inst := readInstances(data)
	byID := map[int]map[string]any{}
	for _, it := range inst {
		id := intFrom(it["id"])
		byID[id] = it
	}
	memberIDs := map[int]bool{}
	members := make([]map[string]any, 0, len(backends))
	for _, b := range backends {
		memberIDs[b.ID] = true
		m := map[string]any{"id": b.ID, "addr": b.Addr, "pooled": true}
		if meta, ok := byID[b.ID]; ok {
			if v4, ok := meta["v4"]; ok {
				m["v4"] = v4
			}
			if p, ok := meta["pooled"]; ok {
				m["pooled"] = p
			}
		}
		members = append(members, m)
	}
	// P2.2: excluded only if unpooled or unhealthy — never healthy+pooled not-yet-in-backends
	excluded := make([]map[string]any, 0)
	for _, it := range inst {
		id := intFrom(it["id"])
		if memberIDs[id] {
			continue
		}
		pooled := true
		if p, ok := it["pooled"].(bool); ok {
			pooled = p
		}
		healthy := false
		if h, ok := it["healthy"].(bool); ok {
			healthy = h
		}
		if pooled && healthy {
			// transient (unique lock / rebuild lag) — not an exclusion
			continue
		}
		ex := map[string]any{"id": id, "pooled": it["pooled"], "healthy": it["healthy"]}
		if v4, ok := it["v4"]; ok {
			ex["v4"] = v4
		}
		reason := ""
		if r, ok := it["exclude_reason"].(string); ok && r != "" {
			reason = r
		} else if !pooled {
			reason = "manual"
		} else if !healthy {
			reason = "unhealthy"
		}
		ex["reason"] = reason
		excluded = append(excluded, ex)
	}
	// P2.1: sticky only if target is a current backend member
	var sticky any
	if st, err := loadSticky(stickyPath(data)); err == nil && st != nil {
		if memberIDs[st.ID] {
			sticky = st
		} else {
			_ = os.Remove(stickyPath(data))
			sticky = nil
		}
	} else {
		sticky = nil
	}
	listen := envOr("AGG_SOCKS_PORT", ":1080")
	// AGG_SOCKS_PORT may be bare port; keep as-is for display
	return map[string]any{
		"enabled":  loadAggEnabled(aggEnabledPath(data)),
		"strategy": "rr",
		"listen":   listen,
		"sticky":   sticky,
		"members":  members,
		"excluded": excluded,
		"ts":       time.Now().UTC().Format(time.RFC3339),
	}
}

func handlePoolMembership(w http.ResponseWriter, r *http.Request, data, scripts string) {
	var body map[string]any
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	id := intFrom(body["id"])
	pooled, ok := boolFrom(body["pooled"])
	if !ok {
		http.Error(w, "missing pooled", http.StatusBadRequest)
		return
	}
	instDir := filepath.Join(data, "instances", strconv.Itoa(id))
	if st, err := os.Stat(instDir); err != nil || !st.IsDir() {
		http.Error(w, "instance not found", http.StatusNotFound)
		return
	}
	metaPath := filepath.Join(instDir, "meta.json")
	meta := map[string]any{}
	if b, err := os.ReadFile(metaPath); err == nil {
		_ = json.Unmarshal(b, &meta)
	}
	meta["id"] = id
	meta["pooled"] = pooled
	reason := ""
	if !pooled {
		reason = "manual"
		if rsn, ok := body["reason"].(string); ok && strings.TrimSpace(rsn) != "" {
			reason = strings.TrimSpace(rsn)
		}
	}
	meta["exclude_reason"] = reason
	raw, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if err := os.WriteFile(metaPath, raw, 0o644); err != nil {
		http.Error(w, "write meta: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// PARK_ON_UNPOOL=1（默认）：出池停 warp-svc 省内存；入池再拉起。目录/netns 保留。
	parked := false
	park := strings.TrimSpace(os.Getenv("PARK_ON_UNPOOL"))
	if park == "" {
		park = "1"
	}
	if park == "1" {
		if !pooled {
			stop := exec.Command("/bin/bash", filepath.Join(scripts, "stop-instance.sh"), strconv.Itoa(id))
			stopOut, stopErr := stop.CombinedOutput()
			parked = stopErr == nil
			appendPoolLog(data, fmt.Sprintf("park id=%d stop_err=%v out=%s", id, stopErr, truncate(string(stopOut), 200)))
			if stopErr != nil {
				w.WriteHeader(http.StatusInternalServerError)
				writeJSON(w, map[string]any{
					"ok": false, "id": id, "pooled": pooled,
					"error": "park stop failed: " + stopErr.Error(), "output": string(stopOut),
				})
				return
			}
		} else {
			start := exec.Command("/bin/bash", filepath.Join(scripts, "start-instance.sh"), strconv.Itoa(id))
			startOut, startErr := start.CombinedOutput()
			appendPoolLog(data, fmt.Sprintf("unpark id=%d start_err=%v out=%s", id, startErr, truncate(string(startOut), 200)))
			if startErr != nil {
				w.WriteHeader(http.StatusInternalServerError)
				writeJSON(w, map[string]any{
					"ok": false, "id": id, "pooled": pooled,
					"error": "unpark start failed: " + startErr.Error(), "output": string(startOut),
				})
				return
			}
		}
	}

	// refresh healthy.json without supervising restarts
	script := filepath.Join(scripts, "health-once.sh")
	cmd := exec.Command("/bin/bash", script)
	cmd.Env = append(os.Environ(), "SUPERVISE_RESTART=0")
	out, err := cmd.CombinedOutput()
	appendPoolLog(data, fmt.Sprintf("membership id=%d pooled=%v reason=%q parked=%v health_err=%v", id, pooled, reason, parked, err))
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		writeJSON(w, map[string]any{
			"ok": false, "id": id, "pooled": pooled,
			"error": err.Error(), "output": string(out),
		})
		return
	}

	// 出池时若 sticky 目标仍是该 id，立即清除 sticky，让聚合立刻回退 RR
	if !pooled {
		stPath := stickyPath(data)
		if st, serr := loadSticky(stPath); serr == nil && st != nil && st.ID == id {
			_ = os.Remove(stPath)
			appendPoolLog(data, fmt.Sprintf("membership id=%d unpooled — sticky cleared", id))
		}
	}
	writeJSON(w, map[string]any{"ok": true, "id": id, "pooled": pooled, "exclude_reason": reason, "parked": parked})
}

func handlePoolSticky(w http.ResponseWriter, r *http.Request, data string) {
	path := stickyPath(data)
	switch r.Method {
	case http.MethodGet:
		st, err := loadSticky(path)
		if err != nil || st == nil {
			writeJSON(w, map[string]any{"id": nil})
			return
		}
		writeJSON(w, st)
	case http.MethodPost:
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "bad json", http.StatusBadRequest)
			return
		}
		id := intFrom(body["id"])
		if id < 0 {
			http.Error(w, "bad id", http.StatusBadRequest)
			return
		}
		// require instance dir; not required to be in backends
		instDir := filepath.Join(data, "instances", strconv.Itoa(id))
		if st, err := os.Stat(instDir); err != nil || !st.IsDir() {
			http.Error(w, "instance not found", http.StatusNotFound)
			return
		}
		if err := os.MkdirAll(filepath.Join(data, "state"), 0o755); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		st := stickyState{ID: id, TS: time.Now().UTC().Format(time.RFC3339)}
		raw, err := json.MarshalIndent(st, "", "  ")
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if err := os.WriteFile(path, raw, 0o644); err != nil {
			http.Error(w, "write: "+err.Error(), http.StatusInternalServerError)
			return
		}
		appendPoolLog(data, fmt.Sprintf("sticky set id=%d", id))
		writeJSON(w, map[string]any{"ok": true, "id": id, "ts": st.TS})
	case http.MethodDelete:
		_ = os.Remove(path)
		appendPoolLog(data, "sticky cleared")
		writeJSON(w, map[string]any{"ok": true, "id": nil})
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

// --- hot config (WP-D skeleton) ---

// env keys allowed via PUT /config (JSON snake_case → ENV)
var configWhitelist = map[string]string{
	"rotate_cooldown":        "ROTATE_COOLDOWN",
	"health_auto_rotate":     "HEALTH_AUTO_ROTATE",
	"v4_unique":              "V4_UNIQUE",
	"v4_unique_retries":      "V4_UNIQUE_RETRIES",
	"v4_unique_hard_retries": "V4_UNIQUE_HARD_RETRIES",
	"v4_unique_backoff":      "V4_UNIQUE_BACKOFF",
	"rotate_mode":            "ROTATE_MODE",
	"agg_enabled":            "AGG_ENABLED",
}

func runtimeConfigPath(data string) string {
	return filepath.Join(data, "state", "runtime-config.json")
}

func desiredNPath(data string) string {
	return filepath.Join(data, "state", "desired_n.json")
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func getConfig(listen, token string) map[string]any {
	return map[string]any{
		"warp_instances":         envOr("WARP_INSTANCES", "0"),
		"rotate_cooldown":        envOr("ROTATE_COOLDOWN", "300"),
		"rotate_mode":            envOr("ROTATE_MODE", "restart"),
		"v4_unique":              envOr("V4_UNIQUE", "1"),
		"v4_unique_retries":      envOr("V4_UNIQUE_RETRIES", "3"),
		"v4_unique_hard_retries": envOr("V4_UNIQUE_HARD_RETRIES", "1"),
		"v4_unique_backoff":      envOr("V4_UNIQUE_BACKOFF", "5"),
		"health_auto_rotate":     envOr("HEALTH_AUTO_ROTATE", "0"),
		"agg_enabled":            envOr("AGG_ENABLED", "1"),
		"control_bind":           envOr("CONTROL_BIND", listen),
		"token_set":              strings.TrimSpace(token) != "",
	}
}

func applyRuntimeConfig(data string) error {
	b, err := os.ReadFile(runtimeConfigPath(data))
	if err != nil {
		return err
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		return err
	}
	for k, envKey := range configWhitelist {
		if v, ok := m[k]; ok {
			_ = os.Setenv(envKey, fmt.Sprint(v))
			if k == "agg_enabled" {
				val := "0"
				if on, ok := boolFrom(v); ok && on {
					val = "1"
				}
				_ = os.MkdirAll(filepath.Join(data, "state"), 0o755)
				_ = os.WriteFile(aggEnabledPath(data), []byte(val), 0o644)
			}
		}
	}
	return nil
}

func handlePutConfig(w http.ResponseWriter, r *http.Request, data, listen, token string) {
	var body map[string]any
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json", http.StatusBadRequest)
		return
	}
	// merge with existing file
	cur := map[string]any{}
	if b, err := os.ReadFile(runtimeConfigPath(data)); err == nil {
		_ = json.Unmarshal(b, &cur)
	}
	applied := map[string]any{}
	for k, v := range body {
		envKey, ok := configWhitelist[k]
		if !ok {
			continue
		}
		cur[k] = v
		s := fmt.Sprint(v)
		_ = os.Setenv(envKey, s)
		applied[k] = v
		if k == "agg_enabled" {
			// cross-process flag for aggregate; file "0"/"1", missing=on
			val := "0"
			if on, ok := boolFrom(v); ok && on {
				val = "1"
			} else if !ok {
				// bare "1"/"0" already covered by boolFrom strings; fallback
				if strings.TrimSpace(s) == "1" {
					val = "1"
				}
			}
			_ = os.MkdirAll(filepath.Join(data, "state"), 0o755)
			_ = os.WriteFile(aggEnabledPath(data), []byte(val), 0o644)
		}
	}
	if err := os.MkdirAll(filepath.Join(data, "state"), 0o755); err != nil {
		http.Error(w, "state dir: "+err.Error(), http.StatusInternalServerError)
		return
	}
	b, err := json.MarshalIndent(cur, "", "  ")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if err := os.WriteFile(runtimeConfigPath(data), b, 0o644); err != nil {
		http.Error(w, "write: "+err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]any{"ok": true, "applied": applied, "config": getConfig(listen, token)})
}

func handlePostInstances(w http.ResponseWriter, r *http.Request, data string) {
	// want N via ?want= / ?n= / body {"want":N} / {"n":N}; bare POST adds +1
	want := 0
	if q := r.URL.Query().Get("want"); q != "" {
		want, _ = strconv.Atoi(q)
	} else if q := r.URL.Query().Get("n"); q != "" {
		want, _ = strconv.Atoi(q)
	}
	if want <= 0 && r.Body != nil {
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err == nil {
			if v, ok := body["want"]; ok {
				want, _ = strconv.Atoi(fmt.Sprint(v))
			} else if v, ok := body["n"]; ok {
				want, _ = strconv.Atoi(fmt.Sprint(v))
			}
		}
	}
	// cur = live dirs only (deleted instances remove their dir)
	cur := countInstanceDirs(data)
	if dn, err := readDesiredN(data); err == nil && dn > cur {
		cur = dn
	}
	if want <= 0 {
		want = cur + 1
	}
	if want < 1 {
		want = 1
	}
	if err := writeDesiredN(data, want); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	_ = os.Setenv("WARP_INSTANCES", strconv.Itoa(want))
	writeJSON(w, map[string]any{
		"ok":      true,
		"desired": want,
		"current": cur,
		"note":    "entrypoint supervisor will hot-add up to desired (ports must be pre-published for direct expose)",
	})
}

func handleDeleteInstance(w http.ResponseWriter, r *http.Request, data, scripts string) {
	id := r.URL.Query().Get("id")
	if id == "" {
		http.Error(w, "missing id", http.StatusBadRequest)
		return
	}
	if _, err := strconv.Atoi(id); err != nil {
		http.Error(w, "bad id", http.StatusBadRequest)
		return
	}
	_ = os.MkdirAll(filepath.Join(data, "state"), 0o755)

	// full remove: stop + drop-netns + rm instance dir (no API/UI residue)
	script := filepath.Join(scripts, "remove-instance.sh")
	if _, err := os.Stat(script); err != nil {
		// fallback older images
		script = filepath.Join(scripts, "stop-instance.sh")
	}
	cmd := exec.Command("/bin/bash", script, id)
	if filepath.Base(script) == "stop-instance.sh" {
		cmd = exec.Command("/bin/bash", script, id, "drop-netns")
	}
	cmd.Env = append(os.Environ(), "SUPERVISE_RESTART=0")
	out, err := cmd.CombinedOutput()
	// always try wipe dir if stop path left it
	_ = os.RemoveAll(filepath.Join(data, "instances", id))

	left := countInstanceDirs(data)
	if left < 1 {
		left = 0
	}
	_ = writeDesiredN(data, left)
	_ = os.Setenv("WARP_INSTANCES", strconv.Itoa(max(left, 1)))

	// tell supervisor not to revive this id (best-effort; dir gone is source of truth)
	_ = os.Remove(filepath.Join(data, "state", "remove-id"))

	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		writeJSON(w, map[string]any{
			"ok": false, "id": id, "desired": left,
			"error": err.Error(), "output": string(out),
		})
		return
	}
	// refresh healthy.json without restarting anything
	hc := exec.Command("/bin/bash", filepath.Join(scripts, "health-once.sh"))
	hc.Env = append(os.Environ(), "SUPERVISE_RESTART=0", "WARP_INSTANCES="+strconv.Itoa(max(left, 1)))
	_, _ = hc.CombinedOutput()

	writeJSON(w, map[string]any{
		"ok": true, "id": id, "removed": true, "desired": left,
		"output": string(out),
	})
}

func countInstanceDirs(data string) int {
	dir := filepath.Join(data, "instances")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	n := 0
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if _, err := strconv.Atoi(e.Name()); err == nil {
			n++
		}
	}
	return n
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func readDesiredN(data string) (int, error) {
	b, err := os.ReadFile(desiredNPath(data))
	if err != nil {
		return 0, err
	}
	var m struct {
		Desired int `json:"desired"`
		N       int `json:"n"`
	}
	if err := json.Unmarshal(b, &m); err != nil {
		return 0, err
	}
	if m.Desired > 0 {
		return m.Desired, nil
	}
	return m.N, nil
}

func writeDesiredN(data string, n int) error {
	if err := os.MkdirAll(filepath.Join(data, "state"), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(map[string]any{"desired": n, "ts": time.Now().UTC().Format(time.RFC3339)}, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(desiredNPath(data), b, 0o644)
}
