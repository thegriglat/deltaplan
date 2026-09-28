// Package zone — реестр зон в памяти: коды, участники, порядок подключения,
// ведущий, рассылка событий зоны и пересылка состояний.
//
// Чистая логика без сети: участник получает сообщения через интерфейс Sink
// (в ws — неблокирующая постановка в очередь соединения), поэтому всё
// проверяется юнит-тестами с поддельным Sink.
//
// Правила (docs/net_protocol.md):
//   - код зоны — случайное число 1000–9999 строкой (без ведущего нуля, чтобы
//     «0472» не путали с «472»), уникально среди активных зон; код
//     освобождается сразу, как зона закрыта, и может быть выдан снова;
//   - порядок подключения (join_order) — 1 у создателя, дальше +1 на каждый
//     вход, номера не переиспользуются внутри зоны;
//   - ведущий — живой участник с наименьшим join_order;
//   - в зоне не больше MaxMembers живых пилотов;
//   - версия зоны — версия игры создателя; вход с другой версией отклоняется;
//   - зона удаляется, как только из неё ушёл последний живой пилот;
//   - PilotState пересылается всем остальным в зоне, ZoneState — только от
//     ведущего (от остальных молча отбрасывается); Envelope.from_id
//     проставляет реестр (значение клиента затирается).
//
// Все отправки в Sink делаются под мьютексом реестра, поэтому порядок событий
// у каждого получателя согласован (например, PeerJoined приходит раньше
// первого PilotState нового пилота). Sink.Send обязан не блокироваться.
package zone

import (
	"fmt"
	"math/rand/v2"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	pb "deltaplan/server/gen/deltaplan/v1"
)

// MaxMembers — максимум живых пилотов в зоне.
const MaxMembers = 16

// Диапазон кодов зон: [codeMin, codeMax].
const (
	codeMin = 1000
	codeMax = 9999
)

// Sink принимает сообщения для участника. Send не должен блокироваться.
type Sink interface {
	Send(env *pb.Envelope)
}

// Member — живой пилот (одно соединение после Hello).
type Member struct {
	ID      string
	Name    string
	Version string
	Sink    Sink

	// Поля ниже меняет только Registry под своим мьютексом.
	zone      *Zone
	joinOrder uint32
	joinedAt  time.Time
}

// Zone — активная зона.
type Zone struct {
	Code      string
	Params    *pb.Zone
	Version   string
	CreatedAt time.Time

	members   []*Member // по порядку подключения
	nextOrder uint32
}

func (z *Zone) leader() *Member {
	if len(z.members) == 0 {
		return nil
	}
	return z.members[0]
}

// Error — отказ с кодом из контракта.
type Error struct {
	Code pb.ErrorCode
	Text string
}

func (e *Error) Error() string { return e.Code.String() + ": " + e.Text }

func errorf(code pb.ErrorCode, format string, args ...any) *Error {
	return &Error{Code: code, Text: fmt.Sprintf(format, args...)}
}

// Registry — все активные зоны. Потокобезопасен.
type Registry struct {
	mu    sync.RWMutex
	zones map[string]*Zone

	// Для тестов: источник случайных кодов и часы.
	randN func(n int) int
	now   func() time.Time
}

// NewRegistry создаёт пустой реестр.
func NewRegistry() *Registry {
	return &Registry{
		zones: make(map[string]*Zone),
		randN: rand.IntN,
		now:   time.Now,
	}
}

// Create создаёт зону с параметрами params, создатель m сразу в ней и ведущий.
// m получает ZoneCreated, затем ZoneJoined. Возвращает код зоны.
func (r *Registry) Create(m *Member, params *pb.Zone) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if m.zone != nil {
		return "", errorf(pb.ErrorCode_ERROR_CODE_BAD_MESSAGE, "already in zone %s", m.zone.Code)
	}
	code, ok := r.freeCode()
	if !ok {
		// 9000 одновременных зон — для нашего сервера нереально; отвечаем
		// ближайшим по смыслу кодом ошибки.
		return "", errorf(pb.ErrorCode_ERROR_CODE_ZONE_FULL, "no free zone codes")
	}
	if params == nil {
		params = &pb.Zone{}
	}
	z := &Zone{Code: code, Params: params, Version: m.Version, CreatedAt: r.now()}
	r.zones[code] = z
	m.Sink.Send(&pb.Envelope{Msg: &pb.Envelope_ZoneCreated{ZoneCreated: &pb.ZoneCreated{Code: code}}})
	r.addLocked(z, m)
	return code, nil
}

// Join вводит m в зону по коду. m получает ZoneJoined, остальные — PeerJoined.
// Ошибки: ZONE_NOT_FOUND, VERSION_MISMATCH, ZONE_FULL; BAD_MESSAGE, если m уже в зоне.
func (r *Registry) Join(m *Member, code string) error {
	code = strings.TrimSpace(code)
	r.mu.Lock()
	defer r.mu.Unlock()
	if m.zone != nil {
		return errorf(pb.ErrorCode_ERROR_CODE_BAD_MESSAGE, "already in zone %s", m.zone.Code)
	}
	z := r.zones[code]
	if z == nil {
		return errorf(pb.ErrorCode_ERROR_CODE_ZONE_NOT_FOUND, "zone %s not found", code)
	}
	if m.Version != z.Version {
		return errorf(pb.ErrorCode_ERROR_CODE_VERSION_MISMATCH,
			"zone %s runs game version %q, yours is %q", code, z.Version, m.Version)
	}
	if len(z.members) >= MaxMembers {
		return errorf(pb.ErrorCode_ERROR_CODE_ZONE_FULL, "zone %s is full (%d pilots)", code, MaxMembers)
	}
	r.addLocked(z, m)
	return nil
}

// addLocked добавляет m в конец порядка подключения и рассылает события.
func (r *Registry) addLocked(z *Zone, m *Member) {
	z.nextOrder++
	m.zone = z
	m.joinOrder = z.nextOrder
	m.joinedAt = r.now()
	z.members = append(z.members, m)

	peers := make([]*pb.Peer, len(z.members))
	for i, p := range z.members {
		peers[i] = p.peer()
	}
	m.Sink.Send(&pb.Envelope{Msg: &pb.Envelope_ZoneJoined{ZoneJoined: &pb.ZoneJoined{
		Code:     z.Code,
		Zone:     z.Params,
		Peers:    peers,
		LeaderId: z.leader().ID,
	}}})
	joined := &pb.Envelope{Msg: &pb.Envelope_PeerJoined{PeerJoined: &pb.PeerJoined{Peer: m.peer()}}}
	for _, p := range z.members {
		if p != m {
			p.Sink.Send(joined)
		}
	}
}

func (m *Member) peer() *pb.Peer {
	return &pb.Peer{Id: m.ID, Name: m.Name, JoinOrder: m.joinOrder}
}

// Leave выводит m из его зоны (LeaveZone или обрыв). Остальным — PeerLeft и,
// если ушёл ведущий, LeaderChanged. Последний ушёл — зона удалена, код
// свободен. Возвращает false, если m не был в зоне.
func (r *Registry) Leave(m *Member) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	z := m.zone
	if z == nil {
		return false
	}
	wasLeader := z.leader() == m
	for i, p := range z.members {
		if p == m {
			z.members = append(z.members[:i], z.members[i+1:]...)
			break
		}
	}
	m.zone = nil
	m.joinOrder = 0
	if len(z.members) == 0 {
		delete(r.zones, z.Code)
		return true
	}
	left := &pb.Envelope{Msg: &pb.Envelope_PeerLeft{PeerLeft: &pb.PeerLeft{Id: m.ID}}}
	for _, p := range z.members {
		p.Sink.Send(left)
	}
	if wasLeader {
		lc := &pb.Envelope{Msg: &pb.Envelope_LeaderChanged{LeaderChanged: &pb.LeaderChanged{LeaderId: z.leader().ID}}}
		for _, p := range z.members {
			p.Sink.Send(lc)
		}
	}
	return true
}

// Relay пересылает PilotState или ZoneState от m остальным в его зоне,
// проставив env.FromId = m.ID. ZoneState не от ведущего отбрасывается
// (возвращает nil). Ошибка BAD_MESSAGE — m не в зоне или сообщение не того
// типа. env после вызова разделяется между получателями — не менять его.
func (r *Registry) Relay(m *Member, env *pb.Envelope) error {
	switch env.GetMsg().(type) {
	case *pb.Envelope_PilotState, *pb.Envelope_ZoneState:
	default:
		return errorf(pb.ErrorCode_ERROR_CODE_BAD_MESSAGE, "message is not relayable")
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	z := m.zone
	if z == nil {
		return errorf(pb.ErrorCode_ERROR_CODE_BAD_MESSAGE, "not in a zone")
	}
	if env.GetZoneState() != nil && z.leader() != m {
		return nil
	}
	env.FromId = m.ID
	for _, p := range z.members {
		if p != m {
			p.Sink.Send(env)
		}
	}
	return nil
}

// ZoneCode — код зоны m или "", если m не в зоне.
func (r *Registry) ZoneCode(m *Member) string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if m.zone == nil {
		return ""
	}
	return m.zone.Code
}

// freeCode выбирает случайный свободный код. Вызывать под r.mu.
func (r *Registry) freeCode() (string, bool) {
	n := codeMax - codeMin + 1
	if len(r.zones) >= n {
		return "", false
	}
	// Пока занято мало кодов, случайная проба почти всегда удачна; на
	// случай плотного заполнения — линейный обход от случайной точки.
	for range 32 {
		c := strconv.Itoa(codeMin + r.randN(n))
		if _, busy := r.zones[c]; !busy {
			return c, true
		}
	}
	start := r.randN(n)
	for i := range n {
		c := strconv.Itoa(codeMin + (start+i)%n)
		if _, busy := r.zones[c]; !busy {
			return c, true
		}
	}
	return "", false
}

// MemberInfo — участник в снимке реестра (для /v1/status).
type MemberInfo struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Version   string    `json:"version"`
	JoinOrder uint32    `json:"join_order"`
	JoinedAt  time.Time `json:"joined_at"`
}

// ZoneInfo — зона в снимке реестра.
type ZoneInfo struct {
	Code      string       `json:"code"`
	Version   string       `json:"version"`
	CreatedAt time.Time    `json:"created_at"`
	Leader    string       `json:"leader"`
	Members   []MemberInfo `json:"members"`
}

// Snapshot — копия состояния всех зон, отсортированная по коду.
func (r *Registry) Snapshot() []ZoneInfo {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]ZoneInfo, 0, len(r.zones))
	for _, z := range r.zones {
		zi := ZoneInfo{Code: z.Code, Version: z.Version, CreatedAt: z.CreatedAt, Leader: z.leader().ID}
		for _, m := range z.members {
			zi.Members = append(zi.Members, MemberInfo{
				ID: m.ID, Name: m.Name, Version: m.Version, JoinOrder: m.joinOrder, JoinedAt: m.joinedAt,
			})
		}
		out = append(out, zi)
	}
	// Коды одной длины (4 цифры) — строковое сравнение совпадает с числовым.
	slices.SortFunc(out, func(a, b ZoneInfo) int { return strings.Compare(a.Code, b.Code) })
	return out
}

// Count — число активных зон.
func (r *Registry) Count() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.zones)
}
