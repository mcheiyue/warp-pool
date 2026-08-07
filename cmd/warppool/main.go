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

	var rr uint64
	var mu sync.Mutex
	var cached []backend
	var cachedAt time.Time

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
		go serveSocks(c, &rr, getBackends)
	}
}

func serveSocks(client net.Conn, rr *uint64, get func() []backend) {
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(30 * time.Second))

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

	backends := get()
	if len(backends) == 0 {
		_, _ = client.Write([]byte{0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
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
		out = append(out, m)
	}
	return out
}

// --- hot config (WP-D skeleton) ---

// env keys allowed via PUT /config (JSON snake_case → ENV)
var configWhitelist = map[string]string{
	"rotate_cooldown":         "ROTATE_COOLDOWN",
	"health_auto_rotate":      "HEALTH_AUTO_ROTATE",
	"v4_unique":               "V4_UNIQUE",
	"v4_unique_retries":       "V4_UNIQUE_RETRIES",
	"v4_unique_hard_retries":  "V4_UNIQUE_HARD_RETRIES",
	"v4_unique_backoff":       "V4_UNIQUE_BACKOFF",
	"rotate_mode":             "ROTATE_MODE",
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
		"warp_instances":          envOr("WARP_INSTANCES", "0"),
		"rotate_cooldown":         envOr("ROTATE_COOLDOWN", "300"),
		"rotate_mode":             envOr("ROTATE_MODE", "restart"),
		"v4_unique":               envOr("V4_UNIQUE", "1"),
		"v4_unique_retries":       envOr("V4_UNIQUE_RETRIES", "3"),
		"v4_unique_hard_retries":  envOr("V4_UNIQUE_HARD_RETRIES", "1"),
		"v4_unique_backoff":       envOr("V4_UNIQUE_BACKOFF", "5"),
		"health_auto_rotate":      envOr("HEALTH_AUTO_ROTATE", "0"),
		"control_bind":            envOr("CONTROL_BIND", listen),
		"token_set":               strings.TrimSpace(token) != "",
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
	cur := len(readInstances(data))
	if dn, err := readDesiredN(data); err == nil && dn > cur {
		cur = dn
	}
	if want <= 0 {
		want = cur + 1
	}
	if err := writeDesiredN(data, want); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	_ = os.Setenv("WARP_INSTANCES", strconv.Itoa(want))
	writeJSON(w, map[string]any{
		"ok":      true,
		"desired": want,
		"note":    "entrypoint supervisor will hot-add up to desired (ports must be pre-published)",
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
	// mark for removal (supervisor can consume later)
	_ = os.MkdirAll(filepath.Join(data, "state"), 0o755)
	_ = os.WriteFile(filepath.Join(data, "state", "remove-id"), []byte(id+"\n"), 0o644)

	script := filepath.Join(scripts, "stop-instance.sh")
	cmd := exec.Command("/bin/bash", script, id)
	cmd.Env = os.Environ()
	out, err := cmd.CombinedOutput()
	if err != nil {
		// still recorded remove-id; surface script failure
		w.WriteHeader(http.StatusInternalServerError)
		writeJSON(w, map[string]any{
			"ok": false, "id": id, "remove_marked": true,
			"error": err.Error(), "output": string(out),
		})
		return
	}
	// lower desired if present
	if dn, err := readDesiredN(data); err == nil && dn > 0 {
		_ = writeDesiredN(data, dn-1)
	}
	writeJSON(w, map[string]any{"ok": true, "id": id, "stopped": true, "output": string(out)})
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
