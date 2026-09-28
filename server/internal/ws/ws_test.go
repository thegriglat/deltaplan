package ws

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/encoding/protojson"

	pb "deltaplan/server/gen/deltaplan/v1"
)

// Тесты поднимают настоящий HTTP-сервер (httptest) и ходят к нему настоящим
// WebSocket-клиентом, обмениваясь кадрами proto3 JSON.

func newTestServer(t *testing.T, gameVersion string) (*Server, string) {
	t.Helper()
	srv := NewServer(slog.New(slog.NewTextHandler(io.Discard, nil)), "test", gameVersion)
	hs := httptest.NewServer(srv.Handler())
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
		hs.Close()
	})
	return srv, hs.URL
}

type client struct {
	t  *testing.T
	c  *websocket.Conn
	id string
}

func dial(t *testing.T, url string) *client {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(url, "http")+"/v1/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.CloseNow() })
	return &client{t: t, c: c}
}

// hello подключается и здоровается, запоминает id.
func hello(t *testing.T, url, name, version string) *client {
	t.Helper()
	cl := dial(t, url)
	cl.send(&pb.Envelope{Msg: &pb.Envelope_Hello{Hello: &pb.Hello{GameVersion: version, Name: name}}})
	w := cl.recv().GetWelcome()
	if w == nil || w.YourId == "" || w.ServerVersion != "test" {
		t.Fatalf("want Welcome, got %v", w)
	}
	cl.id = w.YourId
	return cl
}

func (cl *client) sendRaw(s string) {
	cl.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := cl.c.Write(ctx, websocket.MessageText, []byte(s)); err != nil {
		cl.t.Fatal(err)
	}
}

func (cl *client) send(env *pb.Envelope) {
	cl.t.Helper()
	b, err := protojson.Marshal(env)
	if err != nil {
		cl.t.Fatal(err)
	}
	cl.sendRaw(string(b))
}

func (cl *client) recvTimeout(d time.Duration) (*pb.Envelope, error) {
	ctx, cancel := context.WithTimeout(context.Background(), d)
	defer cancel()
	_, data, err := cl.c.Read(ctx)
	if err != nil {
		return nil, err
	}
	env := &pb.Envelope{}
	if err := protojson.Unmarshal(data, env); err != nil {
		return nil, fmt.Errorf("server sent bad JSON %q: %w", data, err)
	}
	return env, nil
}

func (cl *client) recv() *pb.Envelope {
	cl.t.Helper()
	env, err := cl.recvTimeout(3 * time.Second)
	if err != nil {
		cl.t.Fatalf("recv: %v", err)
	}
	return env
}

// expectNothing проверяет, что за короткое время ничего не пришло. После
// таймаута чтения соединение coder/websocket закрывается — вызывать последним.
func (cl *client) expectNothing() {
	cl.t.Helper()
	if env, err := cl.recvTimeout(300 * time.Millisecond); err == nil {
		cl.t.Fatalf("unexpected message %v", env)
	}
}

func (cl *client) expectError(code pb.ErrorCode) {
	cl.t.Helper()
	env := cl.recv()
	if env.GetError().GetCode() != code {
		cl.t.Fatalf("want Error %v, got %v", code, env)
	}
}

func (cl *client) create() string {
	cl.t.Helper()
	cl.send(&pb.Envelope{Msg: &pb.Envelope_CreateZone{CreateZone: &pb.CreateZone{Zone: &pb.Zone{LocationId: "altai", Seed: 7}}}})
	code := cl.recv().GetZoneCreated().GetCode()
	if code == "" {
		cl.t.Fatal("want ZoneCreated")
	}
	zj := cl.recv().GetZoneJoined()
	if zj.GetCode() != code || zj.LeaderId != cl.id || zj.Zone.GetLocationId() != "altai" {
		cl.t.Fatalf("bad ZoneJoined %v", zj)
	}
	return code
}

func (cl *client) join(code string) *pb.ZoneJoined {
	cl.t.Helper()
	cl.send(&pb.Envelope{Msg: &pb.Envelope_JoinZone{JoinZone: &pb.JoinZone{Code: code}}})
	env := cl.recv()
	zj := env.GetZoneJoined()
	if zj == nil {
		cl.t.Fatalf("want ZoneJoined, got %v", env)
	}
	return zj
}

func (cl *client) joinErr(code string, want pb.ErrorCode) {
	cl.t.Helper()
	cl.send(&pb.Envelope{Msg: &pb.Envelope_JoinZone{JoinZone: &pb.JoinZone{Code: code}}})
	cl.expectError(want)
}

func pilotState(id string, x float32) *pb.Envelope {
	return &pb.Envelope{FromId: "forged", Msg: &pb.Envelope_PilotState{PilotState: &pb.PilotState{
		PilotId: id, Pos: &pb.Vec3{X: x}, Phase: pb.PilotPhase_PILOT_PHASE_FLY,
	}}}
}

func TestHealthz(t *testing.T) {
	_, url := newTestServer(t, "")
	resp, err := http.Get(url + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 || string(b) != "ok" {
		t.Fatalf("%d %q", resp.StatusCode, b)
	}
}

func TestCreateJoinAndStatus(t *testing.T) {
	_, url := newTestServer(t, "")
	a := hello(t, url, "Папа", "0.7.1")
	code := a.create()
	b := hello(t, url, "Мама", "0.7.1")
	zj := b.join(code)
	if zj.LeaderId != a.id || len(zj.Peers) != 2 || zj.Peers[0].Name != "Папа" || zj.Peers[1].Id != b.id ||
		zj.Peers[1].JoinOrder != 2 || zj.Zone.GetSeed() != 7 {
		t.Fatalf("bad ZoneJoined %v", zj)
	}
	if pj := a.recv().GetPeerJoined(); pj.GetPeer().GetId() != b.id || pj.GetPeer().GetName() != "Мама" {
		t.Fatalf("want PeerJoined, got %v", pj)
	}

	resp, err := http.Get(url + "/v1/status")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var st Status
	if err := json.NewDecoder(resp.Body).Decode(&st); err != nil {
		t.Fatal(err)
	}
	if st.Connections != 2 || len(st.Zones) != 1 || st.Zones[0].Code != code || st.Zones[0].Leader != a.id ||
		len(st.Zones[0].Members) != 2 {
		t.Fatalf("bad status %+v", st)
	}
}

func TestUniqueCodes(t *testing.T) {
	_, url := newTestServer(t, "")
	seen := map[string]bool{}
	for range 50 {
		c := hello(t, url, "p", "v")
		code := c.create()
		if seen[code] {
			t.Fatalf("duplicate code %s", code)
		}
		seen[code] = true
	}
}

func TestZoneNotFound(t *testing.T) {
	_, url := newTestServer(t, "")
	a := hello(t, url, "a", "v")
	a.joinErr("0000", pb.ErrorCode_ERROR_CODE_ZONE_NOT_FOUND)
	a.joinErr("abc", pb.ErrorCode_ERROR_CODE_ZONE_NOT_FOUND)
	// Соединение живо: можно создать зону.
	a.create()
}

func TestVersionMismatchOnJoin(t *testing.T) {
	_, url := newTestServer(t, "")
	a := hello(t, url, "a", "0.7.1")
	code := a.create()
	b := hello(t, url, "b", "0.7.0")
	b.joinErr(code, pb.ErrorCode_ERROR_CODE_VERSION_MISMATCH)
}

func TestVersionMismatchOnHello(t *testing.T) {
	_, url := newTestServer(t, "0.7.1")
	c := dial(t, url)
	c.send(&pb.Envelope{Msg: &pb.Envelope_Hello{Hello: &pb.Hello{GameVersion: "0.6", Name: "old"}}})
	c.expectError(pb.ErrorCode_ERROR_CODE_VERSION_MISMATCH)
	// Без Welcome дальше нельзя.
	c.send(&pb.Envelope{Msg: &pb.Envelope_JoinZone{JoinZone: &pb.JoinZone{Code: "1234"}}})
	c.expectError(pb.ErrorCode_ERROR_CODE_BAD_MESSAGE)
	hello(t, url, "ok", "0.7.1")
}

func TestLeaderChangeOnLeave(t *testing.T) {
	_, url := newTestServer(t, "")
	a := hello(t, url, "a", "v")
	code := a.create()
	b := hello(t, url, "b", "v")
	b.join(code)
	a.recv() // PeerJoined b
	c := hello(t, url, "c", "v")
	c.join(code)
	a.recv()
	b.recv() // PeerJoined c

	a.send(&pb.Envelope{Msg: &pb.Envelope_LeaveZone{LeaveZone: &pb.LeaveZone{}}})
	for _, cl := range []*client{b, c} {
		if pl := cl.recv().GetPeerLeft(); pl.GetId() != a.id {
			t.Fatalf("want PeerLeft %s, got %v", a.id, pl)
		}
		if lc := cl.recv().GetLeaderChanged(); lc.GetLeaderId() != b.id {
			t.Fatalf("want LeaderChanged %s, got %v", b.id, lc)
		}
	}
	// a остался подключён и может войти снова — в конец порядка.
	zj := a.join(code)
	if zj.LeaderId != b.id || zj.Peers[len(zj.Peers)-1].Id != a.id || zj.Peers[len(zj.Peers)-1].JoinOrder != 4 {
		t.Fatalf("rejoin %v", zj)
	}
}

func TestLeaderChangeOnDisconnect(t *testing.T) {
	_, url := newTestServer(t, "")
	a := hello(t, url, "a", "v")
	code := a.create()
	b := hello(t, url, "b", "v")
	b.join(code)
	_ = a.c.CloseNow() // обрыв без LeaveZone
	if pl := b.recv().GetPeerLeft(); pl.GetId() != a.id {
		t.Fatalf("want PeerLeft, got %v", pl)
	}
	if lc := b.recv().GetLeaderChanged(); lc.GetLeaderId() != b.id {
		t.Fatalf("want LeaderChanged, got %v", lc)
	}
}

func TestZoneDeletedWhenLastLeaves(t *testing.T) {
	srv, url := newTestServer(t, "")
	a := hello(t, url, "a", "v")
	code := a.create()
	b := hello(t, url, "b", "v")
	b.join(code)
	a.send(&pb.Envelope{Msg: &pb.Envelope_LeaveZone{LeaveZone: &pb.LeaveZone{}}})
	_ = b.c.CloseNow()
	deadline := time.Now().Add(3 * time.Second)
	for srv.Registry.Count() != 0 {
		if time.Now().After(deadline) {
			t.Fatal("zone not deleted")
		}
		time.Sleep(10 * time.Millisecond)
	}
	c := hello(t, url, "c", "v")
	c.joinErr(code, pb.ErrorCode_ERROR_CODE_ZONE_NOT_FOUND)
}

func TestRelayOnlyWithinZone(t *testing.T) {
	_, url := newTestServer(t, "")
	a := hello(t, url, "a", "v")
	code := a.create()
	b := hello(t, url, "b", "v")
	b.join(code)
	a.recv() // PeerJoined
	x := hello(t, url, "x", "v")
	x.create()

	b.send(pilotState(b.id, 1))
	env := a.recv()
	if env.FromId != b.id || env.GetPilotState().GetPilotId() != b.id || env.GetPilotState().GetPos().GetX() != 1 {
		t.Fatalf("a got %v", env)
	}
	// Бот от ведущего: fromId — ведущий, pilotId — бот.
	a.send(&pb.Envelope{Msg: &pb.Envelope_PilotState{PilotState: &pb.PilotState{PilotId: "bot-1", IsBot: true}}})
	env = b.recv()
	if env.FromId != a.id || env.GetPilotState().GetPilotId() != "bot-1" {
		t.Fatalf("b got %v", env)
	}
	// ZoneState от не-ведущего отбрасывается, от ведущего доходит.
	b.send(&pb.Envelope{Msg: &pb.Envelope_ZoneState{ZoneState: &pb.ZoneState{Clock: 99}}})
	a.send(&pb.Envelope{Msg: &pb.Envelope_ZoneState{ZoneState: &pb.ZoneState{Clock: 10, Queue: []string{a.id, b.id}}}})
	env = b.recv()
	if env.FromId != a.id || env.GetZoneState().GetClock() != 10 {
		t.Fatalf("b got %v", env)
	}
	// Отправителю эхо не приходит, в чужую зону ничего не утекает.
	b.send(&pb.Envelope{Msg: &pb.Envelope_Ping{Ping: &pb.Ping{ClientTime: 1}}})
	if env := b.recv(); env.GetPong() == nil {
		t.Fatalf("b: want only Pong (no echo), got %v", env)
	}
	a.expectNothing()
	x.expectNothing()
}

func TestZoneFull(t *testing.T) {
	_, url := newTestServer(t, "")
	first := hello(t, url, "p0", "v")
	code := first.create()
	for i := 1; i < 16; i++ {
		hello(t, url, fmt.Sprint("p", i), "v").join(code)
	}
	hello(t, url, "p16", "v").joinErr(code, pb.ErrorCode_ERROR_CODE_ZONE_FULL)
}

func TestPingPong(t *testing.T) {
	_, url := newTestServer(t, "")
	a := hello(t, url, "a", "v")
	before := float64(time.Now().UnixNano()) / 1e9
	a.send(&pb.Envelope{Msg: &pb.Envelope_Ping{Ping: &pb.Ping{ClientTime: 1234.567}}})
	p := a.recv().GetPong()
	after := float64(time.Now().UnixNano()) / 1e9
	if p.GetClientTime() != 1234.567 || p.GetServerTime() < before-0.001 || p.GetServerTime() > after+0.001 {
		t.Fatalf("bad Pong %v (want server time in [%f, %f])", p, before, after)
	}
}

func TestBadMessages(t *testing.T) {
	_, url := newTestServer(t, "")
	c := dial(t, url)
	// До Hello — всё отклоняется, включая Ping.
	c.send(&pb.Envelope{Msg: &pb.Envelope_Ping{Ping: &pb.Ping{}}})
	c.expectError(pb.ErrorCode_ERROR_CODE_BAD_MESSAGE)
	c.sendRaw("not json")
	c.expectError(pb.ErrorCode_ERROR_CODE_BAD_MESSAGE)
	c.send(&pb.Envelope{Msg: &pb.Envelope_Hello{Hello: &pb.Hello{GameVersion: "v", Name: "c"}}})
	w := c.recv().GetWelcome()
	if w == nil {
		t.Fatal("want Welcome after bad frames")
	}
	c.id = w.YourId
	c.sendRaw(`{"pilotState": {"pilotId": 5}}`) // неверный тип поля
	c.expectError(pb.ErrorCode_ERROR_CODE_BAD_MESSAGE)
	c.send(pilotState("x", 0)) // вне зоны
	c.expectError(pb.ErrorCode_ERROR_CODE_BAD_MESSAGE)
	c.send(&pb.Envelope{Msg: &pb.Envelope_Welcome{Welcome: &pb.Welcome{}}}) // серверное сообщение
	c.expectError(pb.ErrorCode_ERROR_CODE_BAD_MESSAGE)
	c.send(&pb.Envelope{Msg: &pb.Envelope_Hello{Hello: &pb.Hello{}}}) // повторный Hello
	c.expectError(pb.ErrorCode_ERROR_CODE_BAD_MESSAGE)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := c.c.Write(ctx, websocket.MessageBinary, []byte{1, 2}); err != nil {
		t.Fatal(err)
	}
	c.expectError(pb.ErrorCode_ERROR_CODE_BAD_MESSAGE)
	// Незнакомые ключи и незнакомый вариант (новая версия протокола) — молча.
	c.sendRaw(`{"futureThing": {"a": 1}}`)
	c.sendRaw(`{"ping": {"clientTime": 2, "newField": true}}`)
	if p := c.recv().GetPong(); p.GetClientTime() != 2 {
		t.Fatalf("want Pong 2 (unknown ignored), got %v", p)
	}
	c.create()
	c.send(&pb.Envelope{Msg: &pb.Envelope_CreateZone{CreateZone: &pb.CreateZone{}}}) // уже в зоне
	c.expectError(pb.ErrorCode_ERROR_CODE_BAD_MESSAGE)
}

func TestNameTruncated(t *testing.T) {
	_, url := newTestServer(t, "")
	a := hello(t, url, strings.Repeat("Я", 30), "v")
	a.create()
	b := hello(t, url, "b", "v")
	code := ""
	for _, z := range b.statusZones(url) {
		code = z
	}
	zj := b.join(code)
	if n := []rune(zj.Peers[0].Name); len(n) != MaxNameRunes {
		t.Fatalf("name not truncated: %d runes", len(n))
	}
}

func (cl *client) statusZones(url string) []string {
	resp, err := http.Get(url + "/v1/status")
	if err != nil {
		cl.t.Fatal(err)
	}
	defer resp.Body.Close()
	var st Status
	_ = json.NewDecoder(resp.Body).Decode(&st)
	var codes []string
	for _, z := range st.Zones {
		codes = append(codes, z.Code)
	}
	return codes
}

// Пинг WebSocket без ответа (клиент не читает) — сервер закрывает
// соединение, остальные получают PeerLeft.
func TestKeepaliveTimeout(t *testing.T) {
	srv, url := newTestServer(t, "")
	srv.PingInterval = 100 * time.Millisecond
	srv.PingTimeout = 200 * time.Millisecond
	a := hello(t, url, "a", "v")
	code := a.create()
	b := hello(t, url, "b", "v") // b читает (отвечает на ping), a — нет
	b.join(code)
	if pl := b.recv().GetPeerLeft(); pl.GetId() != a.id {
		t.Fatalf("want PeerLeft of silent a, got %v", pl)
	}
}

// Медленный клиент: PilotState для него отбрасываются, остальные в зоне
// получают свои без задержек.
func TestSlowClientDoesNotBlockZone(t *testing.T) {
	srv, url := newTestServer(t, "")
	srv.StallTimeout = time.Hour
	a := hello(t, url, "a", "v")
	code := a.create()
	slow := hello(t, url, "slow", "v")
	slow.join(code)
	a.recv()
	fast := hello(t, url, "fast", "v")
	fast.join(code)
	a.recv()
	slow.recv()
	// slow больше не читает.
	for i := range 3000 {
		a.send(pilotState(a.id, float32(i)))
	}
	// Часть пачки могла отброситься и у fast (он читает медленнее, чем a
	// пишет); после паузы последнее состояние обязано дойти.
	time.Sleep(300 * time.Millisecond)
	a.send(pilotState(a.id, -1))
	for {
		env := fast.recv()
		if env.GetPilotState().GetPos().GetX() == -1 {
			break
		}
	}
	if srv.dropped.Load() == 0 {
		t.Log("no drops observed (socket buffers absorbed everything)")
	}
}
