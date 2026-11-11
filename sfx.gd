extends Node
## Sound effects synthesized at startup, so the game ships with no audio files.

const RATE := 22050

var enabled := true
var streams := {}
var players := []
var _next := 0


func _ready() -> void:
	streams = {
		"move": _tone(240, 170, 0.12, 0.45, 32.0, 0.0),
		"capture": _tone(170, 80, 0.25, 0.6, 14.0, 0.3),
		"travel": _tone(260, 1500, 0.7, 0.05, 3.5, 0.5),
		"turn": _tone(880, 880, 0.7, 0.0, 6.0, 0.35),
		"check": _tone(740, 700, 0.35, 0.0, 7.0, 0.8),
		"error": _tone(130, 120, 0.22, 0.2, 9.0, 0.9),
		"win": _tone(523, 1046, 1.2, 0.0, 2.5, 0.4),
		"click": _tone(1200, 900, 0.04, 0.2, 60.0, 0.0),
	}
	for i in 6:
		var p := AudioStreamPlayer.new()
		add_child(p)
		players.append(p)


func play(name: String) -> void:
	if not enabled:
		return
	var p: AudioStreamPlayer = players[_next]
	_next = (_next + 1) % players.size()
	p.stream = streams[name]
	p.play()


## Sine sweep f0->f1 with optional 2nd harmonic and noise, exponential decay.
func _tone(f0: float, f1: float, dur: float, noise: float, decay: float, harm: float) -> AudioStreamWAV:
	var n := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	for i in n:
		var k := float(i) / n
		phase += TAU * lerpf(f0, f1, k) / RATE
		var env := exp(-decay * k * dur) * minf(1.0, i / (0.004 * RATE)) * (1.0 - k)
		var s := (sin(phase) + harm * sin(2.0 * phase)) / (1.0 + harm)
		s = lerpf(s, randf_range(-1.0, 1.0), noise)
		data.encode_s16(i * 2, int(clampf(s * env * 0.6, -1.0, 1.0) * 32767))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.data = data
	return w
