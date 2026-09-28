// Нагрузочный тест сервера: N зон × M клиентов, каждый шлёт PilotState с
// частотой hz (ведущий — ещё ZoneState 1 Гц) и читает всё, что приходит.
// Раз в -sample печатает память сервера: RSS из /proc/<pid>/status (если
// задан -pid) и runtime-статистику из /v1/status.
//
//	go build -o /tmp/ds ./cmd/deltaplan-server && /tmp/ds -addr 127.0.0.1:8090 &
//	go run ./cmd/loadtest -url ws://127.0.0.1:8090 -pid $! -duration 10m
//
// Результат (NET-20, 2026-09-28): 3 зоны × 10 клиентов × 10 Гц, 10 мин,
// сервер и нагрузка на одной машине (Linux amd64, сборка без -race).
// Отправлено 179 970 PilotState (10,0/с на клиента), принято 1 635 165
// (90,8/с на клиента при ожидаемых ≈ 91 = 9 × 10 + ZoneState), отброшено 0,
// ошибок 0. Память стабильна, роста нет:
//
//	t, с   RSS, КБ  heap_alloc  sys      goroutines
//	0      17412    1.8 MB      11.8 MB  96
//	30     21060    1.8 MB      18.7 MB  96
//	150    20676    1.9 MB      18.7 MB  96
//	300    19512    1.8 MB      18.7 MB  96
//	450    19920    1.7 MB      18.7 MB  96
//	570    19856    2.7 MB      18.7 MB  96
//	601    18932    0.9 MB      19.0 MB  6   (все отключились, зон 0)
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
	"google.golang.org/protobuf/encoding/protojson"

	pb "deltaplan/server/gen/deltaplan/v1"
)

type stats struct {
	sent, recv, errs atomic.Int64
}

func main() {
	url := flag.String("url", "ws://127.0.0.1:8080", "server base URL (ws://host:port)")
	zones := flag.Int("zones", 3, "zones")
	clients := flag.Int("clients", 10, "clients per zone")
	hz := flag.Float64("hz", 10, "PilotState rate per client")
	duration := flag.Duration("duration", 10*time.Minute, "test duration")
	sample := flag.Duration("sample", 30*time.Second, "memory sample interval")
	pid := flag.Int("pid", 0, "server pid for RSS (0 = skip)")
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), *duration)
	defer cancel()
	var st stats
	var wg sync.WaitGroup

	for z := range *zones {
		codeCh := make(chan string, 1)
		for i := range *clients {
			var code string
			if i > 0 {
				code = <-codeCh
				codeCh <- code
			}
			cl, err := connect(ctx, *url, fmt.Sprintf("z%d-p%d", z, i), code, codeCh)
			if err != nil {
				log.Fatalf("zone %d client %d: %v", z, i, err)
			}
			wg.Add(1)
			go func() { defer wg.Done(); cl.run(ctx, *hz, i == 0, &st) }()
		}
	}
	log.Printf("connected %d zones × %d clients, %.0f Hz, for %v", *zones, *clients, *hz, *duration)

	httpBase := "http" + strings.TrimPrefix(*url, "ws")
	start := time.Now()
	printSample(httpBase, *pid, start, &st)
	tick := time.NewTicker(*sample)
	defer tick.Stop()
loop:
	for {
		select {
		case <-ctx.Done():
			break loop
		case <-tick.C:
			printSample(httpBase, *pid, start, &st)
		}
	}
	wg.Wait()
	el := time.Since(start).Seconds()
	n := float64(*zones * *clients)
	log.Printf("done: sent %d (%.1f/s per client), received %d (%.1f/s per client, expected ≈ %.0f), errors %d",
		st.sent.Load(), float64(st.sent.Load())/el/n, st.recv.Load(), float64(st.recv.Load())/el/n,
		float64(*clients-1)**hz+float64(*clients-1)/float64(*clients), st.errs.Load())
	time.Sleep(time.Second)
	printSample(httpBase, *pid, start, &st)
}

func printSample(base string, pid int, start time.Time, st *stats) {
	rss := "-"
	if pid > 0 {
		if b, err := os.ReadFile(fmt.Sprintf("/proc/%d/status", pid)); err == nil {
			for _, l := range strings.Split(string(b), "\n") {
				if strings.HasPrefix(l, "VmRSS:") {
					rss = strings.Join(strings.Fields(l)[1:], " ")
				}
			}
		}
	}
	var s struct {
		Connections   int64  `json:"connections"`
		DroppedStates uint64 `json:"dropped_states"`
		Zones         []any  `json:"zones"`
		Runtime       struct {
			Goroutines int    `json:"goroutines"`
			HeapAlloc  uint64 `json:"heap_alloc"`
			HeapInuse  uint64 `json:"heap_inuse"`
			Sys        uint64 `json:"sys"`
			NumGC      uint32 `json:"num_gc"`
		} `json:"runtime"`
	}
	resp, err := http.Get(base + "/v1/status")
	if err == nil {
		_ = json.NewDecoder(resp.Body).Decode(&s)
		resp.Body.Close()
	}
	log.Printf("t=%4.0fs rss=%s heap_alloc=%.1fMB heap_inuse=%.1fMB sys=%.1fMB goroutines=%d gc=%d conns=%d zones=%d dropped=%d sent=%d recv=%d",
		time.Since(start).Seconds(), rss, mb(s.Runtime.HeapAlloc), mb(s.Runtime.HeapInuse), mb(s.Runtime.Sys),
		s.Runtime.Goroutines, s.Runtime.NumGC, s.Connections, len(s.Zones), s.DroppedStates, st.sent.Load(), st.recv.Load())
}

func mb(b uint64) float64 { return float64(b) / (1 << 20) }

type client struct {
	c  *websocket.Conn
	id string
}

func connect(ctx context.Context, url, name, code string, codeCh chan string) (*client, error) {
	c, _, err := websocket.Dial(ctx, url+"/v1/ws", nil)
	if err != nil {
		return nil, err
	}
	c.SetReadLimit(1 << 20)
	cl := &client{c: c}
	if err := cl.send(ctx, &pb.Envelope{Msg: &pb.Envelope_Hello{Hello: &pb.Hello{GameVersion: "load", Name: name}}}); err != nil {
		return nil, err
	}
	env, err := cl.recv(ctx)
	if err != nil || env.GetWelcome() == nil {
		return nil, fmt.Errorf("no Welcome: %v %v", env, err)
	}
	cl.id = env.GetWelcome().YourId
	if code == "" {
		err = cl.send(ctx, &pb.Envelope{Msg: &pb.Envelope_CreateZone{CreateZone: &pb.CreateZone{Zone: &pb.Zone{LocationId: "altai", Seed: 1, BotsCount: 0}}}})
	} else {
		err = cl.send(ctx, &pb.Envelope{Msg: &pb.Envelope_JoinZone{JoinZone: &pb.JoinZone{Code: code}}})
	}
	if err != nil {
		return nil, err
	}
	for {
		env, err := cl.recv(ctx)
		if err != nil {
			return nil, err
		}
		if zc := env.GetZoneCreated(); zc != nil {
			codeCh <- zc.Code
		}
		if env.GetZoneJoined() != nil {
			return cl, nil
		}
		if e := env.GetError(); e != nil {
			return nil, fmt.Errorf("error %v", e)
		}
	}
}

func (cl *client) send(ctx context.Context, env *pb.Envelope) error {
	b, err := protojson.Marshal(env)
	if err != nil {
		return err
	}
	return cl.c.Write(ctx, websocket.MessageText, b)
}

func (cl *client) recv(ctx context.Context) (*pb.Envelope, error) {
	_, data, err := cl.c.Read(ctx)
	if err != nil {
		return nil, err
	}
	env := &pb.Envelope{}
	return env, protojson.Unmarshal(data, env)
}

func (cl *client) run(ctx context.Context, hz float64, leader bool, st *stats) {
	defer cl.c.CloseNow()
	go func() {
		for {
			if _, _, err := cl.c.Read(ctx); err != nil {
				return
			}
			st.recv.Add(1)
		}
	}()
	tick := time.NewTicker(time.Duration(float64(time.Second) / hz))
	defer tick.Stop()
	start := time.Now()
	lastZS := start
	for i := 0; ; i++ {
		select {
		case <-ctx.Done():
			return
		case now := <-tick.C:
			t := now.Sub(start).Seconds()
			ps := &pb.PilotState{
				PilotId: cl.id, Name: "Пилот " + cl.id, T: t,
				Pos:   &pb.Vec3{X: float32(100 + i%500), Y: 1500.25, Z: float32(-340 - i%300)},
				Rot:   &pb.Quat{Y: 0.6, W: 0.8},
				Vel:   &pb.Vec3{X: 9.5, Y: -1.25, Z: -6},
				Phase: pb.PilotPhase_PILOT_PHASE_FLY, Wing: "wings/sport",
				Colors: &pb.WingColors{HueDeg: 222, Sat: 1, Value: 1},
			}
			if err := cl.send(ctx, &pb.Envelope{Msg: &pb.Envelope_PilotState{PilotState: ps}}); err != nil {
				if ctx.Err() == nil {
					st.errs.Add(1)
				}
				return
			}
			st.sent.Add(1)
			if leader && now.Sub(lastZS) >= time.Second {
				lastZS = now
				_ = cl.send(ctx, &pb.Envelope{Msg: &pb.Envelope_ZoneState{ZoneState: &pb.ZoneState{Clock: t, Queue: []string{cl.id}}}})
			}
		}
	}
}
