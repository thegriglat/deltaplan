// Сервер сетевой игры Deltaplan: зоны в памяти и пересылка состояний пилотов
// по WebSocket (контракт — proto/deltaplan/v1/net.proto, описание —
// docs/net_protocol.md).
//
// Запуск:
//
//	deltaplan-server -addr :8080 [-game-version 0.7.1]
//
// Флаги (переменная окружения — если флаг не задан):
//
//	-addr          DELTAPLAN_ADDR          адрес HTTP, по умолчанию ":8080"
//	-game-version  DELTAPLAN_GAME_VERSION  если задана — Hello с другой версией
//	                                       получает VERSION_MISMATCH; пусто — версии
//	                                       сверяются только при входе в зону
//	-log-level     DELTAPLAN_LOG_LEVEL     debug | info | warn | error (info)
//
// Маршруты: /v1/ws (WebSocket), /healthz (200 "ok"), /v1/status (JSON для отладки).
// Логи — в stdout (slog, текст). SIGINT/SIGTERM — плавная остановка.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"deltaplan/server/internal/ws"
)

// version — версия сервера (Welcome.server_version, /v1/status). Сборка
// может подставить: -ldflags "-X main.version=1.2.3".
var version = "dev"

func envOr(key, def string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return def
}

func main() {
	addr := flag.String("addr", envOr("DELTAPLAN_ADDR", ":8080"), "listen address (env DELTAPLAN_ADDR)")
	gameVersion := flag.String("game-version", envOr("DELTAPLAN_GAME_VERSION", ""),
		"required game version on Hello, empty = any (env DELTAPLAN_GAME_VERSION)")
	logLevel := flag.String("log-level", envOr("DELTAPLAN_LOG_LEVEL", "info"),
		"debug|info|warn|error (env DELTAPLAN_LOG_LEVEL)")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}

	var level slog.Level
	if err := level.UnmarshalText([]byte(strings.ToUpper(*logLevel))); err != nil {
		fmt.Fprintln(os.Stderr, "bad -log-level:", err)
		os.Exit(2)
	}
	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: level}))

	if err := run(log, *addr, *gameVersion); err != nil {
		log.Error("server failed", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger, addr, gameVersion string) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	srv := ws.NewServer(log, version, gameVersion)
	hs := &http.Server{
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	log.Info("listening", "addr", ln.Addr().String(), "version", version, "game_version", gameVersion)

	errc := make(chan error, 1)
	go func() { errc <- hs.Serve(ln) }()

	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	log.Info("shutting down")
	shCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// Сначала перестаём принимать новые запросы, затем закрываем WebSocket
	// (http.Server.Shutdown захваченные соединения не трогает).
	if err := hs.Shutdown(shCtx); err != nil {
		log.Warn("http shutdown", "err", err)
	}
	if err := srv.Shutdown(shCtx); err != nil {
		log.Warn("ws shutdown", "err", err)
	}
	if err := <-errc; err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	log.Info("stopped")
	return nil
}
