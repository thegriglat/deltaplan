extends TestCase
## Контракт К14 (docs/contracts/easter-eggs.md): луп гогота стаи assets/sounds/geese/geese_flock_loop.ogg.

const OGG := "res://assets/sounds/geese/geese_flock_loop.ogg"


func test_geese_sound() -> void:
	var s := load(OGG) as AudioStreamOggVorbis
	check(s != null, "geese_flock_loop.ogg грузится как AudioStreamOggVorbis")
	if s == null:
		return
	var len_s := s.get_length()
	check(len_s >= 8.0 and len_s <= 20.0, "длина %.2f с в 8–20" % len_s)
	check(s.loop, "loop == true")
