package zone

import (
	"fmt"
	"testing"

	pb "deltaplan/server/gen/deltaplan/v1"
)

// fakeSink копит полученные сообщения.
type fakeSink struct{ got []*pb.Envelope }

func (s *fakeSink) Send(env *pb.Envelope) { s.got = append(s.got, env) }

func (s *fakeSink) take() []*pb.Envelope {
	g := s.got
	s.got = nil
	return g
}

func newMember(id, version string) (*Member, *fakeSink) {
	s := &fakeSink{}
	return &Member{ID: id, Name: "pilot " + id, Version: version, Sink: s}, s
}

func errCode(err error) pb.ErrorCode {
	if e, ok := err.(*Error); ok {
		return e.Code
	}
	return pb.ErrorCode_ERROR_CODE_UNSPECIFIED
}

func TestCreateSendsCreatedThenJoined(t *testing.T) {
	r := NewRegistry()
	a, sa := newMember("1", "0.7")
	code, err := r.Create(a, &pb.Zone{Seed: 42})
	if err != nil {
		t.Fatal(err)
	}
	if len(code) != 4 || code < "1000" || code > "9999" {
		t.Fatalf("bad code %q", code)
	}
	got := sa.take()
	if len(got) != 2 || got[0].GetZoneCreated().GetCode() != code {
		t.Fatalf("want ZoneCreated first, got %v", got)
	}
	zj := got[1].GetZoneJoined()
	if zj == nil || zj.Code != code || zj.LeaderId != "1" || zj.Zone.GetSeed() != 42 ||
		len(zj.Peers) != 1 || zj.Peers[0].JoinOrder != 1 {
		t.Fatalf("bad ZoneJoined %v", got[1])
	}
}

func TestUniqueCodesAndReuse(t *testing.T) {
	r := NewRegistry()
	seen := map[string]*Member{}
	for i := range 3000 {
		m, _ := newMember(fmt.Sprint(i), "v")
		code, err := r.Create(m, nil)
		if err != nil {
			t.Fatal(err)
		}
		if seen[code] != nil {
			t.Fatalf("duplicate code %s", code)
		}
		seen[code] = m
	}
	if r.Count() != 3000 {
		t.Fatalf("count %d", r.Count())
	}
	// Освободить один код и заставить генератор выдать именно его.
	var freed string
	for c, m := range seen {
		freed = c
		r.Leave(m)
		break
	}
	r.randN = func(int) int { var n int; fmt.Sscan(freed, &n); return n - codeMin }
	m, _ := newMember("x", "v")
	code, err := r.Create(m, nil)
	if err != nil || code != freed {
		t.Fatalf("freed code not reused: %q %v", code, err)
	}
}

func TestCodesExhaustedFallback(t *testing.T) {
	r := NewRegistry()
	r.randN = func(int) int { return 0 } // всегда «1000» — дальше линейный обход
	// Заняты все коды, кроме 5555.
	for c := codeMin; c <= codeMax; c++ {
		if c != 5555 {
			r.zones[fmt.Sprint(c)] = &Zone{}
		}
	}
	m, _ := newMember("last", "v")
	if code, err := r.Create(m, nil); err != nil || code != "5555" {
		t.Fatalf("want 5555, got %q %v", code, err)
	}
	over, _ := newMember("over", "v")
	if _, err := r.Create(over, nil); err == nil {
		t.Fatal("want error when all codes are busy")
	}
}

func TestJoinErrors(t *testing.T) {
	r := NewRegistry()
	a, _ := newMember("1", "0.7")
	code, _ := r.Create(a, nil)

	b, _ := newMember("2", "0.7")
	if c := errCode(r.Join(b, "0000")); c != pb.ErrorCode_ERROR_CODE_ZONE_NOT_FOUND {
		t.Fatalf("want ZONE_NOT_FOUND, got %v", c)
	}
	old, _ := newMember("3", "0.6")
	if c := errCode(r.Join(old, code)); c != pb.ErrorCode_ERROR_CODE_VERSION_MISMATCH {
		t.Fatalf("want VERSION_MISMATCH, got %v", c)
	}
	if err := r.Join(b, code); err != nil {
		t.Fatal(err)
	}
	if c := errCode(r.Join(b, code)); c != pb.ErrorCode_ERROR_CODE_BAD_MESSAGE {
		t.Fatalf("double join: want BAD_MESSAGE, got %v", c)
	}
	if _, err := r.Create(b, nil); errCode(err) != pb.ErrorCode_ERROR_CODE_BAD_MESSAGE {
		t.Fatalf("create while in zone: want BAD_MESSAGE, got %v", err)
	}
}

func TestZoneFull(t *testing.T) {
	r := NewRegistry()
	a, _ := newMember("0", "v")
	code, _ := r.Create(a, nil)
	for i := 1; i < MaxMembers; i++ {
		m, _ := newMember(fmt.Sprint(i), "v")
		if err := r.Join(m, code); err != nil {
			t.Fatalf("member %d: %v", i, err)
		}
	}
	m, _ := newMember("17th", "v")
	if c := errCode(r.Join(m, code)); c != pb.ErrorCode_ERROR_CODE_ZONE_FULL {
		t.Fatalf("want ZONE_FULL, got %v", c)
	}
	// Место освободилось — вход снова возможен, join_order продолжает расти.
	r.Leave(a)
	if err := r.Join(m, code); err != nil {
		t.Fatal(err)
	}
	if m.joinOrder != MaxMembers+1 {
		t.Fatalf("join order %d", m.joinOrder)
	}
}

func TestJoinOrderPeersAndLeaderChange(t *testing.T) {
	r := NewRegistry()
	a, sa := newMember("a", "v")
	b, sb := newMember("b", "v")
	c, sc := newMember("c", "v")
	code, _ := r.Create(a, nil)
	sa.take()
	_ = r.Join(b, code)
	zj := sb.take()[0].GetZoneJoined()
	if len(zj.Peers) != 2 || zj.Peers[0].Id != "a" || zj.Peers[1].Id != "b" || zj.Peers[1].JoinOrder != 2 || zj.LeaderId != "a" {
		t.Fatalf("bad ZoneJoined %v", zj)
	}
	if pj := sa.take(); len(pj) != 1 || pj[0].GetPeerJoined().GetPeer().GetId() != "b" {
		t.Fatalf("a: want PeerJoined b, got %v", pj)
	}
	_ = r.Join(c, code)
	sa.take()
	sb.take()
	sc.take()

	// Не-ведущий уходит: только PeerLeft.
	r.Leave(b)
	for _, s := range []*fakeSink{sa, sc} {
		got := s.take()
		if len(got) != 1 || got[0].GetPeerLeft().GetId() != "b" {
			t.Fatalf("want PeerLeft b only, got %v", got)
		}
	}
	if sb.take() != nil {
		t.Fatal("leaver must get nothing")
	}
	// Ведущий уходит: PeerLeft, затем LeaderChanged на следующего по порядку.
	r.Leave(a)
	got := sc.take()
	if len(got) != 2 || got[0].GetPeerLeft().GetId() != "a" || got[1].GetLeaderChanged().GetLeaderId() != "c" {
		t.Fatalf("want PeerLeft a + LeaderChanged c, got %v", got)
	}
	// Вернувшийся встаёт в конец порядка и ведущим не становится.
	_ = r.Join(a, code)
	zj = sa.take()[0].GetZoneJoined()
	if zj.LeaderId != "c" || zj.Peers[1].JoinOrder != 4 {
		t.Fatalf("rejoin: %v", zj)
	}
}

func TestZoneDeletedWhenLastLeaves(t *testing.T) {
	r := NewRegistry()
	a, _ := newMember("a", "v")
	b, _ := newMember("b", "v")
	code, _ := r.Create(a, nil)
	_ = r.Join(b, code)
	r.Leave(a)
	r.Leave(b)
	if r.Count() != 0 {
		t.Fatal("zone must be deleted")
	}
	if r.Leave(b) {
		t.Fatal("second leave must be no-op")
	}
	c, _ := newMember("c", "v")
	if errCode(r.Join(c, code)) != pb.ErrorCode_ERROR_CODE_ZONE_NOT_FOUND {
		t.Fatal("deleted zone must not be joinable")
	}
}

func TestRelay(t *testing.T) {
	r := NewRegistry()
	a, sa := newMember("a", "v")
	b, sb := newMember("b", "v")
	x, sx := newMember("x", "v") // другая зона
	code, _ := r.Create(a, nil)
	_ = r.Join(b, code)
	_, _ = r.Create(x, nil)
	sa.take()
	sb.take()
	sx.take()

	ps := &pb.Envelope{FromId: "forged", Msg: &pb.Envelope_PilotState{PilotState: &pb.PilotState{PilotId: "b"}}}
	if err := r.Relay(b, ps); err != nil {
		t.Fatal(err)
	}
	got := sa.take()
	if len(got) != 1 || got[0].FromId != "b" || got[0].GetPilotState().GetPilotId() != "b" {
		t.Fatalf("a: %v", got)
	}
	if sb.take() != nil || sx.take() != nil {
		t.Fatal("relay must not echo to sender or leak to other zones")
	}

	// ZoneState от не-ведущего отбрасывается, от ведущего — пересылается.
	zs := func() *pb.Envelope {
		return &pb.Envelope{Msg: &pb.Envelope_ZoneState{ZoneState: &pb.ZoneState{Clock: 5}}}
	}
	if err := r.Relay(b, zs()); err != nil || sa.take() != nil {
		t.Fatal("ZoneState from non-leader must be dropped")
	}
	if err := r.Relay(a, zs()); err != nil {
		t.Fatal(err)
	}
	if got := sb.take(); len(got) != 1 || got[0].FromId != "a" {
		t.Fatalf("b: %v", got)
	}

	out, _ := newMember("out", "v")
	if errCode(r.Relay(out, zs())) != pb.ErrorCode_ERROR_CODE_BAD_MESSAGE {
		t.Fatal("relay outside zone must be BAD_MESSAGE")
	}
	if errCode(r.Relay(a, &pb.Envelope{Msg: &pb.Envelope_Ping{Ping: &pb.Ping{}}})) != pb.ErrorCode_ERROR_CODE_BAD_MESSAGE {
		t.Fatal("non-relayable must be BAD_MESSAGE")
	}
}

func TestSnapshot(t *testing.T) {
	r := NewRegistry()
	a, _ := newMember("a", "v")
	b, _ := newMember("b", "v")
	code, _ := r.Create(a, nil)
	_ = r.Join(b, code)
	s := r.Snapshot()
	if len(s) != 1 || s[0].Code != code || s[0].Leader != "a" || len(s[0].Members) != 2 || s[0].Members[1].JoinOrder != 2 {
		t.Fatalf("snapshot %+v", s)
	}
}
