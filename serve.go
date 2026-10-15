// serve.go - web UI + reverse proxy for selfHostedIMG.
// /v1/* -> sd-server on 127.0.0.1:7860 (avoids CORS entirely).
// / -> /app/index.html. Everything else 404s; no directory listings, ever.
package main

import (
	"fmt"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
)

func getenv(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func main() {
	uiPort := getenv("UI_PORT", "8090")
	target, err := url.Parse("http://127.0.0.1:7860")
	if err != nil {
		fmt.Fprintln(os.Stderr, "[serve] bad target:", err)
		os.Exit(1)
	}
	proxy := httputil.NewSingleHostReverseProxy(target)

	mux := http.NewServeMux()
	mux.Handle("/v1/", proxy)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		http.ServeFile(w, r, "/app/index.html")
	})

	fmt.Println("[serve] UI on :" + uiPort + ", proxying /v1/ to sd-server")
	if err := http.ListenAndServe(":"+uiPort, mux); err != nil {
		fmt.Fprintln(os.Stderr, "[serve] error:", err)
		os.Exit(1)
	}
}
