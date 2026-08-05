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
	fmt.Fprintf(os.Stderr, "usage:\n  warppool aggregate --listen :1080 --healthy /data/state/healthy.json\n  warppool control --listen 127.0.0.1:9090 --data /data --scripts /opt/warp-pool/scripts\n  warppool expose --listen 0.0.0.0:11000 --backend 127.0.0.1:40000\n")
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
		}
	}

	host, _, err := net.SplitHostPort(listen)
	if err == nil && host != "" && host != "127.0.0.1" && host != "::1" && host != "localhost" {
		if strings.TrimSpace(token) == "" {
			log.Fatalf("CONTROL_BIND is non-loopback (%s) but CONTROL_TOKEN is empty — refusing to start", host)
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if !authOK(r, token) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		writeJSON(w, readHealth(data))
	})
	mux.HandleFunc("/instances", func(w http.ResponseWriter, r *http.Request) {
		if !authOK(r, token) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		writeJSON(w, readInstances(data))
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
			mode = "reconnect" // v0.2 default; soft is alias in rotate-instance.sh
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
		out, err := cmd.CombinedOutput()
		if err != nil {
			status := http.StatusInternalServerError
			msg := string(out)
			if strings.Contains(msg, "cooldown") {
				status = http.StatusTooManyRequests
			}
			if strings.Contains(msg, "not found") {
				status = http.StatusNotFound
			}
			w.WriteHeader(status)
			writeJSON(w, map[string]any{"ok": false, "error": err.Error(), "output": msg})
			return
		}
		writeJSON(w, map[string]any{"ok": true, "output": string(out)})
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

	srv := &http.Server{Addr: listen, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	log.Printf("control api on %s", listen)
	log.Fatal(srv.ListenAndServe())
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
