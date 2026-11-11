extends RefCounted
## Greedy bot: plans a whole turn board by board. Each move is scored by material
## minus the most valuable piece the opponent could take back right away.
## shortcut: 1-ply + hanging-piece check, no search tree; add minimax over turns if it's too weak.

const VALUE := [0, 1, 3, 3, 5, 9, 100]


## Returns [[l, t, sq, Vector4i to], ...] for a full legal turn, or [] if none was found (mated).
static func plan_turn(g, tries := 4) -> Array:
	for i in tries:
		var sim = g.clone()
		var moves := []
		while not sim.can_submit():
			var m := best_move(sim, i * 0.7)
			if m.is_empty():
				break
			moves.append(m)
			sim.apply_move(m[0], m[1], m[2], m[3])
			if sim.winner >= 0:
				return moves
		if sim.can_submit() and not sim.king_attacked(sim.player):
			return moves
	return []


## Best move on the boards The Present forces us to play.
static func best_move(g, noise: float) -> Array:
	var best := []
	var best_s := -INF
	var p: int = g.present()
	for l in g.timelines:
		if not g.is_active(l) or g.end_t(l) != p:
			continue
		var b: PackedInt32Array = g.board(l, p)
		for sq in 64:
			if b[sq] == 0 or (b[sq] > 0) != (g.player == 0):
				continue
			for to: Vector4i in g.moves_from(l, p, sq):
				var sim = g.clone()
				sim.apply_move(l, p, sq, to)
				var s := score(sim, g.player) + randf() * (0.3 + noise)
				if s > best_s:
					best_s = s
					best = [l, p, sq, to]
	return best


static func score(g, me: int) -> float:
	if g.winner == me:
		return 1e6
	var s := 0.0
	for l in g.timelines:
		if not g.is_active(l):
			continue
		var b: PackedInt32Array = g.board(l, g.end_t(l))
		for sq in 64:
			var pc := b[sq]
			if pc == 0:
				continue
			var v: float = VALUE[absi(pc)]
			var x := sq & 7
			var y := sq >> 3
			if absi(pc) == 1:
				v += (y if pc > 0 else 7 - y) * 0.05
			elif absi(pc) != 6 and x >= 2 and x <= 5 and y >= 2 and y <= 5:
				v += 0.1
			s += v if (pc > 0) == (me == 0) else -v
	return s - threat(g, me) * 0.8


## Value of my most valuable piece the opponent can capture from boards where it is their move.
static func threat(g, me: int) -> int:
	var opp := 1 - me
	var worst := 0
	for l in g.timelines:
		var t: int = g.end_t(l)
		if t % 2 != opp:
			continue
		var b: PackedInt32Array = g.board(l, t)
		for sq in 64:
			if b[sq] == 0 or (b[sq] > 0) != (opp == 0):
				continue
			for to: Vector4i in g.moves_from(l, t, sq):
				worst = maxi(worst, VALUE[absi(g.board(to.w, to.z)[to.y * 8 + to.x])])
	return worst
