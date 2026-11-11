extends RefCounted
## Multiverse chess rules. A board lives at (timeline L, time t).
## t even = white to move on it, t odd = black. One "turn" (time axis unit) = 2 boards.
## Pieces: >0 white, <0 black; 1 pawn 2 knight 3 bishop 4 rook 5 queen 6 king.
## Moves are Vector4i(x, y, t, l) targets; direction vectors are Vector4i(dx, dy, dTurn, dL).

const P := 1
const N := 2
const B := 3
const R := 4
const Q := 5
const K := 6
const OFF := -999

var timelines := {}  # l -> {"start": int, "boards": Array of PackedInt32Array(64)}
var player := 0      # 0 white, 1 black
var winner := -1

static var ROOK := _dirs(func(nz, s): return nz == 1 and s == 1)
static var BISHOP := _dirs(func(nz, s): return nz == 2 and s == 2)
static var ALL := _dirs(func(nz, s): return nz >= 1 and s == nz)
static var KNIGHT := _dirs(func(nz, s): return nz == 2 and s == 3)


static func _dirs(pred: Callable) -> Array:
	var out := []
	for a in range(-2, 3):
		for b in range(-2, 3):
			for c in range(-2, 3):
				for d in range(-2, 3):
					var v := [a, b, c, d]
					var nz := v.filter(func(e): return e != 0).size()
					var s: int = absi(a) + absi(b) + absi(c) + absi(d)
					# knights may use a 2; everything else only unit components
					if (pred.call(nz, s) as bool) and (s == 3 or v.all(func(e): return absi(e) <= 1)):
						out.append(Vector4i(a, b, c, d))
	return out


func setup() -> void:
	var b := PackedInt32Array()
	b.resize(64)
	var back := [R, N, B, Q, K, B, N, R]
	for x in 8:
		b[x] = back[x]
		b[8 + x] = P
		b[48 + x] = -P
		b[56 + x] = -back[x]
	timelines = {0: {"start": 0, "boards": [b]}}
	player = 0
	winner = -1


func clone():
	var g = get_script().new()
	for l in timelines:
		var boards := []
		for b in timelines[l].boards:
			boards.append((b as PackedInt32Array).duplicate())
		g.timelines[l] = {"start": timelines[l].start, "boards": boards}
	g.player = player
	g.winner = winner
	return g


func end_t(l: int) -> int:
	return timelines[l].start + timelines[l].boards.size() - 1


func board(l: int, t: int):
	if not timelines.has(l) or t < timelines[l].start or t > end_t(l):
		return null
	return timelines[l].boards[t - timelines[l].start]


func is_playable(l: int, t: int, color: int) -> bool:
	return timelines.has(l) and end_t(l) == t and t % 2 == color


## Timelines beyond one more than the opponent has made are inactive.
func active_range() -> Vector2i:
	var lo := 0
	var hi := 0
	for l in timelines:
		lo = mini(lo, l)
		hi = maxi(hi, l)
	return Vector2i(-mini(-lo, hi + 1), mini(hi, -lo + 1))


func is_active(l: int) -> bool:
	var r := active_range()
	return l >= r.x and l <= r.y


## The Present: earliest last board among active timelines.
func present() -> int:
	var p := 1 << 30
	for l in timelines:
		if is_active(l):
			p = mini(p, end_t(l))
	return p


func can_submit() -> bool:
	return present() % 2 != player


func _at(x: int, y: int, t: int, l: int) -> int:
	if x < 0 or x > 7 or y < 0 or y > 7:
		return OFF
	var b = board(l, t)
	return OFF if b == null else b[y * 8 + x]


func moves_from(l: int, t: int, sq: int) -> Array:
	var pc: int = board(l, t)[sq]
	if pc == 0:
		return []
	var color := 0 if pc > 0 else 1
	var x := sq & 7
	var y := sq >> 3
	var out := []
	match absi(pc):
		P:
			var f := 1 if color == 0 else -1
			for d in [Vector4i(0, f, 0, 0), Vector4i(0, 0, 0, f)]:
				if _at(x + d.x, y + d.y, t, l + d.w) == 0:
					out.append(Vector4i(x + d.x, y + d.y, t, l + d.w))
					var home := 1 if color == 0 else 6
					if d.y != 0 and y == home and _at(x, y + 2 * f, t, l) == 0:
						out.append(Vector4i(x, y + 2 * f, t, l))
			for d in [Vector4i(1, f, 0, 0), Vector4i(-1, f, 0, 0), Vector4i(0, 0, 1, f), Vector4i(0, 0, -1, f)]:
				var q := _at(x + d.x, y + d.y, t + 2 * d.z, l + d.w)
				if q != OFF and q != 0 and (q > 0) != (color == 0):
					out.append(Vector4i(x + d.x, y + d.y, t + 2 * d.z, l + d.w))
		N: _walk(x, y, t, l, color, KNIGHT, 1, out)
		B: _walk(x, y, t, l, color, BISHOP, 8, out)
		R: _walk(x, y, t, l, color, ROOK, 8, out)
		Q: _walk(x, y, t, l, color, ALL, 8, out)
		K: _walk(x, y, t, l, color, ALL, 1, out)
	return out


func _walk(x: int, y: int, t: int, l: int, color: int, dirs: Array, steps: int, out: Array) -> void:
	for d: Vector4i in dirs:
		for s in range(1, steps + 1):
			var to := Vector4i(x + d.x * s, y + d.y * s, t + 2 * d.z * s, l + d.w * s)
			var q := _at(to.x, to.y, to.z, to.w)
			if q == OFF or (q != 0 and (q > 0) == (color == 0)):
				break
			out.append(to)
			if q != 0:
				break


## Moving onto a board that already has a move after it creates a new timeline.
## Returns Vector2i(l, t) of the board the piece arrived on.
func apply_move(l: int, t: int, sq: int, to: Vector4i) -> Vector2i:
	var src: PackedInt32Array = (board(l, t) as PackedInt32Array).duplicate()
	var pc := src[sq]
	src[sq] = 0
	var dst_sq := to.y * 8 + to.x
	if absi(pc) == P and (to.y == 7 or to.y == 0):
		pc = Q * signi(pc)  # shortcut: auto-queen promotion, add a picker if anyone asks
	var captured := 0
	var arrived := Vector2i(to.w, to.z + 1)
	if to.w == l and to.z == t:
		captured = src[dst_sq]
		src[dst_sq] = pc
		timelines[l].boards.append(src)
	else:
		timelines[l].boards.append(src)
		var dst: PackedInt32Array = (board(to.w, to.z) as PackedInt32Array).duplicate()
		captured = dst[dst_sq]
		dst[dst_sq] = pc
		if end_t(to.w) == to.z:
			timelines[to.w].boards.append(dst)
		else:
			var r := timelines.keys()
			var nl: int = (r.max() + 1) if player == 0 else (r.min() - 1)
			timelines[nl] = {"start": to.z + 1, "boards": [dst]}
			arrived.x = nl
	if absi(captured) == K:
		winner = player
	return arrived


## Can the opponent of `color` capture any of its kings from a board where the opponent moves?
## any_board: also look at boards where `color` moves (used as the "check" warning).
func king_attacked(color: int, any_board := false) -> bool:
	var opp := 1 - color
	for l in timelines:
		var t := end_t(l)
		if t % 2 != opp and not any_board:
			continue
		var b: PackedInt32Array = board(l, t)
		for sq in 64:
			if b[sq] == 0 or (b[sq] > 0) != (opp == 0):
				continue
			for to: Vector4i in moves_from(l, t, sq):
				if absi(board(to.w, to.z)[to.y * 8 + to.x]) == K:
					return true
	return false


func submit() -> String:
	if not can_submit():
		return "Сначала сдвиньте Настоящее: сходите на всех досках настоящего."
	if king_attacked(player):
		return "Нельзя: ваш король останется под ударом."
	player = 1 - player
	return ""
