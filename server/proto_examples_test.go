package server_test

// Машинная проверка примеров docs/net_protocol.md: каждый блок ```json — это
// Envelope, который разбирается protojson (строго, без незнакомых полей) и
// совпадает по содержимому с тем, что выдаёт protojson.Marshal. Все варианты
// Envelope.msg должны иметь хотя бы один пример.

import (
	"encoding/json"
	"os"
	"reflect"
	"regexp"
	"testing"

	"google.golang.org/protobuf/encoding/protojson"

	deltaplanv1 "deltaplan/server/gen/deltaplan/v1"
)

var jsonBlock = regexp.MustCompile("(?s)```json\n(.*?)\n```")

func TestProtocolDocExamples(t *testing.T) {
	doc, err := os.ReadFile("../docs/net_protocol.md")
	if err != nil {
		t.Fatal(err)
	}
	blocks := jsonBlock.FindAllStringSubmatch(string(doc), -1)
	if len(blocks) == 0 {
		t.Fatal("в docs/net_protocol.md нет блоков ```json")
	}
	covered := map[string]bool{}
	for i, b := range blocks {
		src := b[1]
		var env deltaplanv1.Envelope
		if err := protojson.Unmarshal([]byte(src), &env); err != nil {
			t.Errorf("пример %d не разбирается: %v\n%s", i+1, err, src)
			continue
		}
		oneof := env.ProtoReflect().Descriptor().Oneofs().ByName("msg")
		fd := env.ProtoReflect().WhichOneof(oneof)
		if fd == nil {
			t.Errorf("пример %d: не задан вариант Envelope.msg\n%s", i+1, src)
			continue
		}
		covered[string(fd.Name())] = true

		out, err := protojson.Marshal(&env)
		if err != nil {
			t.Fatal(err)
		}
		var want, got any
		if err := json.Unmarshal([]byte(src), &want); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(out, &got); err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(want, got) {
			t.Errorf("пример %d не совпадает с выводом protojson\nв документе: %s\nprotojson:   %s", i+1, src, out)
		}
	}
	fields := (&deltaplanv1.Envelope{}).ProtoReflect().Descriptor().Oneofs().ByName("msg").Fields()
	for i := 0; i < fields.Len(); i++ {
		name := string(fields.Get(i).Name())
		if !covered[name] {
			t.Errorf("нет примера для Envelope.%s", name)
		}
	}
}
