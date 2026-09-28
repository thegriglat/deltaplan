// Package ws — WebSocket-сторона сервера: /v1/ws и /v1/status.
//
// Одно соединение — один пилот. Кадры текстовые, каждый — Envelope в proto3
// JSON (разбор protojson с DiscardUnknown, вывод protojson.Marshal по
// умолчанию). Лимит кадра — ReadLimit.
//
// Порядок: первым должен прийти Hello (до Welcome всё остальное, включая
// Ping, — Error BAD_MESSAGE). Неразобранный кадр, двоичный кадр или сообщение
// не к месту — Error BAD_MESSAGE, соединение остаётся. Envelope без
// известного варианта (сообщение из более новой версии протокола) молча
// пропускается.
//
// Отправка: у соединения свой пишущий goroutine и две ограниченные очереди.
// Управляющие сообщения (Welcome, ZoneJoined, PeerLeft, ZoneState, Pong,
// Error, …) — очередь ctrlQueue, пишутся первыми; переполнилась — клиент
// безнадёжно отстал, соединение закрывается. PilotState — очередь
// stateQueue; при переполнении новые состояния отбрасываются (зона не
// ждёт медленного клиента), а если очередь не разгружается дольше
// StallTimeout — соединение закрывается.
//
// Живость: сервер шлёт WebSocket ping каждые PingInterval; нет pong за
// PingTimeout — соединение закрывается (обрыв → PeerLeft остальным).
package ws

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"runtime"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/encoding/protojson"

	pb "deltaplan/server/gen/deltaplan/v1"
	"deltaplan/server/internal/zone"
)

// Значения по умолчанию.
const (
	ReadLimit    = 64 << 10
	ctrlQueue    = 64
	stateQueue   = 256
	writeTimeout = 10 * time.Second
	// MaxNameRunes — длиннее имя из Hello обрезается.
	MaxNameRunes = 20
)

// Server обслуживает WebSocket-соединения пилотов.
type Server struct {
	Registry      *zone.Registry
	Log           *slog.Logger
	ServerVersion string
	// GameVersion — если не пусто, Hello с другой версией получает
	// VERSION_MISMATCH. Пусто — версия проверяется только при входе в зону.
	GameVersion string

	PingInterval time.Duration // по умолчанию 15 с
	PingTimeout  time.Duration // по умолчанию 15 с
	StallTimeout time.Duration // по умолчанию 5 с

	startedAt time.Time
	nextID    atomic.Uint64
	conns     atomic.Int64
	dropped   atomic.Uint64

	baseCtx context.Context
	cancel  context.CancelFunc
	wg      sync.WaitGroup
}

// NewServer создаёт сервер с пустым реестром зон.
func NewServer(log *slog.Logger, serverVersion, gameVersion string) *Server {
	ctx, cancel := context.WithCancel(context.Background())
	return &Server{
		Registry:      zone.NewRegistry(),
		Log:           log,
		ServerVersion: serverVersion,
		GameVersion:   gameVersion,
		PingInterval:  15 * time.Second,
		PingTimeout:   15 * time.Second,
		StallTimeout:  5 * time.Second,
		startedAt:     time.Now(),
		baseCtx:       ctx,
		cancel:        cancel,
	}
}

// Shutdown закрывает все соединения (их пилоты уходят из зон) и ждёт, пока
// обработчики завершатся, или истечёт ctx.
func (s *Server) Shutdown(ctx context.Context) error {
	s.cancel()
	done := make(chan struct{})
	go func() { s.wg.Wait(); close(done) }()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Handler — маршруты сервера: /v1/ws, /v1/status, /healthz.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", s.ServeWS)
	mux.HandleFunc("/v1/status", s.ServeStatus)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok"))
	})
	return mux
}

// Status — содержимое /v1/status (для отладки).
type Status struct {
	ServerVersion string          `json:"server_version"`
	GameVersion   string          `json:"game_version,omitempty"`
	StartedAt     time.Time       `json:"started_at"`
	Connections   int64           `json:"connections"`
	DroppedStates uint64          `json:"dropped_states"`
	Zones         []zone.ZoneInfo `json:"zones"`
	Runtime       RuntimeInfo     `json:"runtime"`
}

// RuntimeInfo — память и goroutine процесса.
type RuntimeInfo struct {
	Goroutines int    `json:"goroutines"`
	HeapAlloc  uint64 `json:"heap_alloc"`
	HeapInuse  uint64 `json:"heap_inuse"`
	Sys        uint64 `json:"sys"`
	NumGC      uint32 `json:"num_gc"`
	TotalAlloc uint64 `json:"total_alloc"`
}

// Status — снимок состояния сервера.
func (s *Server) Status() Status {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	return Status{
		ServerVersion: s.ServerVersion,
		GameVersion:   s.GameVersion,
		StartedAt:     s.startedAt,
		Connections:   s.conns.Load(),
		DroppedStates: s.dropped.Load(),
		Zones:         s.Registry.Snapshot(),
		Runtime: RuntimeInfo{
			Goroutines: runtime.NumGoroutine(),
			HeapAlloc:  ms.HeapAlloc,
			HeapInuse:  ms.HeapInuse,
			Sys:        ms.Sys,
			NumGC:      ms.NumGC,
			TotalAlloc: ms.TotalAlloc,
		},
	}
}

// ServeStatus отдаёт Status в JSON.
func (s *Server) ServeStatus(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(s.Status())
}

// ServeWS принимает WebSocket и ведёт соединение до его закрытия.
func (s *Server) ServeWS(w http.ResponseWriter, r *http.Request) {
	if s.baseCtx.Err() != nil {
		http.Error(w, "shutting down", http.StatusServiceUnavailable)
		return
	}
	wsc, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// Авторизации нет, клиент — игра (не браузер): Origin не проверяем.
		InsecureSkipVerify: true,
	})
	if err != nil {
		s.Log.Info("ws accept failed", "remote", r.RemoteAddr, "err", err)
		return
	}
	s.wg.Add(1)
	defer s.wg.Done()
	s.conns.Add(1)
	defer s.conns.Add(-1)

	wsc.SetReadLimit(ReadLimit)
	ctx, cancel := context.WithCancel(s.baseCtx)
	c := &conn{
		srv:    s,
		ws:     wsc,
		ctx:    ctx,
		cancel: cancel,
		ctrl:   make(chan *pb.Envelope, ctrlQueue),
		state:  make(chan *pb.Envelope, stateQueue),
		log:    s.Log.With("remote", r.RemoteAddr),
	}
	c.log.Debug("connected")
	go c.writeLoop()
	go c.keepalive()
	reason := c.readLoop()
	cancel()
	if c.member != nil {
		if code := s.Registry.ZoneCode(c.member); code != "" {
			s.Registry.Leave(c.member)
			c.log.Info("left zone on disconnect", "zone", code)
		}
	}
	_ = wsc.CloseNow()
	c.log.Info("disconnected", "reason", reason)
}

type conn struct {
	srv    *Server
	ws     *websocket.Conn
	ctx    context.Context
	cancel context.CancelFunc
	ctrl   chan *pb.Envelope
	state  chan *pb.Envelope
	log    *slog.Logger

	member *zone.Member // после Hello; меняется только в readLoop

	mu        sync.Mutex
	fullSince time.Time // с какого момента stateQueue переполнена
}

// Send ставит сообщение в очередь на отправку; не блокируется (zone.Sink).
func (c *conn) Send(env *pb.Envelope) {
	if c.ctx.Err() != nil {
		return
	}
	if env.GetPilotState() != nil {
		select {
		case c.state <- env:
			c.mu.Lock()
			c.fullSince = time.Time{}
			c.mu.Unlock()
		default:
			c.srv.dropped.Add(1)
			c.mu.Lock()
			now := time.Now()
			if c.fullSince.IsZero() {
				c.fullSince = now
			}
			stalled := now.Sub(c.fullSince) > c.srv.StallTimeout
			c.mu.Unlock()
			if stalled {
				c.log.Warn("client too slow, closing")
				c.cancel()
			}
		}
		return
	}
	select {
	case c.ctrl <- env:
	default:
		c.log.Warn("control queue overflow, closing")
		c.cancel()
	}
}

func (c *conn) writeLoop() {
	defer c.cancel()
	for {
		// Управляющие — в первую очередь.
		select {
		case env := <-c.ctrl:
			if !c.write(env) {
				return
			}
			continue
		default:
		}
		select {
		case <-c.ctx.Done():
			return
		case env := <-c.ctrl:
			if !c.write(env) {
				return
			}
		case env := <-c.state:
			if !c.write(env) {
				return
			}
		}
	}
}

func (c *conn) write(env *pb.Envelope) bool {
	data, err := protojson.Marshal(env)
	if err != nil {
		c.log.Error("marshal", "err", err)
		return true
	}
	ctx, cancel := context.WithTimeout(c.ctx, writeTimeout)
	defer cancel()
	if err := c.ws.Write(ctx, websocket.MessageText, data); err != nil {
		c.log.Debug("write failed", "err", err)
		return false
	}
	return true
}

func (c *conn) keepalive() {
	t := time.NewTicker(c.srv.PingInterval)
	defer t.Stop()
	for {
		select {
		case <-c.ctx.Done():
			return
		case <-t.C:
			ctx, cancel := context.WithTimeout(c.ctx, c.srv.PingTimeout)
			err := c.ws.Ping(ctx)
			cancel()
			if err != nil {
				if c.ctx.Err() == nil {
					c.log.Info("ping timeout, closing", "err", err)
				}
				c.cancel()
				return
			}
		}
	}
}

var unmarshal = protojson.UnmarshalOptions{DiscardUnknown: true}

// readLoop читает кадры до обрыва; возвращает причину для лога.
func (c *conn) readLoop() string {
	for {
		typ, data, err := c.ws.Read(c.ctx)
		if err != nil {
			if c.srv.baseCtx.Err() != nil {
				return "server shutdown"
			}
			var ce websocket.CloseError
			if errors.As(err, &ce) {
				return "closed by client: " + ce.Code.String()
			}
			return err.Error()
		}
		if typ != websocket.MessageText {
			c.sendError(pb.ErrorCode_ERROR_CODE_BAD_MESSAGE, "binary frames are not supported")
			continue
		}
		env := &pb.Envelope{}
		if err := unmarshal.Unmarshal(data, env); err != nil {
			c.sendError(pb.ErrorCode_ERROR_CODE_BAD_MESSAGE, "cannot parse envelope: "+err.Error())
			continue
		}
		c.handle(env)
	}
}

func (c *conn) sendError(code pb.ErrorCode, text string) {
	c.log.Debug("client error", "code", code.String(), "text", text)
	c.Send(&pb.Envelope{Msg: &pb.Envelope_Error{Error: &pb.Error{Code: code, Text: text}}})
}

func (c *conn) replyErr(err error) {
	var ze *zone.Error
	if errors.As(err, &ze) {
		c.sendError(ze.Code, ze.Text)
		return
	}
	c.sendError(pb.ErrorCode_ERROR_CODE_BAD_MESSAGE, err.Error())
}

func (c *conn) handle(env *pb.Envelope) {
	if env.GetMsg() == nil {
		// Незнакомый вариант из более новой версии протокола — пропускаем.
		return
	}
	if hello := env.GetHello(); hello != nil {
		c.hello(hello)
		return
	}
	if c.member == nil {
		c.sendError(pb.ErrorCode_ERROR_CODE_BAD_MESSAGE, "Hello expected first")
		return
	}
	reg := c.srv.Registry
	switch m := env.GetMsg().(type) {
	case *pb.Envelope_Ping:
		now := time.Now()
		c.Send(&pb.Envelope{Msg: &pb.Envelope_Pong{Pong: &pb.Pong{
			ClientTime: m.Ping.GetClientTime(),
			ServerTime: float64(now.UnixNano()) / 1e9,
		}}})
	case *pb.Envelope_CreateZone:
		code, err := reg.Create(c.member, m.CreateZone.GetZone())
		if err != nil {
			c.replyErr(err)
			return
		}
		c.log.Info("zone created", "zone", code, "id", c.member.ID, "version", c.member.Version)
	case *pb.Envelope_JoinZone:
		if err := reg.Join(c.member, m.JoinZone.GetCode()); err != nil {
			c.log.Info("join refused", "zone", m.JoinZone.GetCode(), "id", c.member.ID, "err", err)
			c.replyErr(err)
			return
		}
		c.log.Info("joined zone", "zone", m.JoinZone.GetCode(), "id", c.member.ID)
	case *pb.Envelope_LeaveZone:
		code := reg.ZoneCode(c.member)
		if reg.Leave(c.member) {
			c.log.Info("left zone", "zone", code, "id", c.member.ID)
		}
	case *pb.Envelope_PilotState, *pb.Envelope_ZoneState:
		if err := reg.Relay(c.member, env); err != nil {
			c.replyErr(err)
		}
	default:
		c.sendError(pb.ErrorCode_ERROR_CODE_BAD_MESSAGE, "unexpected message from client")
	}
}

func (c *conn) hello(h *pb.Hello) {
	if c.member != nil {
		c.sendError(pb.ErrorCode_ERROR_CODE_BAD_MESSAGE, "duplicate Hello")
		return
	}
	if gv := c.srv.GameVersion; gv != "" && h.GetGameVersion() != gv {
		c.log.Info("hello refused: version", "want", gv, "got", h.GetGameVersion())
		c.sendError(pb.ErrorCode_ERROR_CODE_VERSION_MISMATCH,
			"server runs game version "+strconv.Quote(gv)+", yours is "+strconv.Quote(h.GetGameVersion()))
		return
	}
	id := strconv.FormatUint(c.srv.nextID.Add(1), 10)
	c.member = &zone.Member{ID: id, Name: truncateName(h.GetName()), Version: h.GetGameVersion(), Sink: c}
	c.log.Info("hello", "id", id, "name", c.member.Name, "version", c.member.Version)
	c.Send(&pb.Envelope{Msg: &pb.Envelope_Welcome{Welcome: &pb.Welcome{YourId: id, ServerVersion: c.srv.ServerVersion}}})
}

func truncateName(s string) string {
	if utf8.RuneCountInString(s) <= MaxNameRunes {
		return s
	}
	return string([]rune(s)[:MaxNameRunes])
}
