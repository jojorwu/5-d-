extends SceneTree
## Run: godot --headless --path . --script res://tests/test_engine.gd

const Engine5D := preload("res://engine.gd")
var fails := 0


func check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok:
		fails += 1


func _init() -> void:
	var g = Engine5D.new()
	g.setup()
	var n := 0
	for sq in 16:
		n += g.moves_from(0, 0, sq).size()
	check(n == 20, "20 opening moves (got %d)" % n)
	check(not g.can_submit(), "cannot submit before moving")
	g.apply_move(0, 0, 6, Vector4i(5, 2, 0, 0))  # Ng1-f3
	check(g.submit() == "", "white submits")
	g.apply_move(0, 1, 62, Vector4i(5, 5, 1, 0))  # Ng8-f6
	check(g.submit() == "", "black submits")
	# knight f3 jumps one turn back and two ranks up: lands on f5 of board t=0 -> branch
	var jump := Vector4i(5, 4, 0, 0)
	check(jump in g.moves_from(0, 2, 21), "knight can time-travel")
	g.apply_move(0, 2, 21, jump)
	check(g.timelines.has(1) and g.timelines[1].start == 1, "new timeline L+1 branches at t=1")
	check(g.end_t(0) == 3 and g.board(0, 3)[21] == 0, "knight departed from L0")
	check(g.board(1, 1)[37] == 2, "knight arrived on L+1")
	check(g.present() == 1 and g.can_submit(), "present moved back to black's board")
	check(g.submit() == "", "white submits after branching")
	# black must now move on both L0 (t=3) and L+1 (t=1)
	g.apply_move(0, 3, 52, Vector4i(4, 4, 3, 0))  # e7-e5 on L0
	check(not g.can_submit(), "black still owes a move on L+1")

	var c = Engine5D.new()
	var b := PackedInt32Array()
	b.resize(64)
	b[4] = 6
	b[60] = -4
	c.timelines = {0: {"start": 1, "boards": [b]}}
	check(c.king_attacked(0), "rook on e8 attacks king on e1")
	check(c.active_range() == Vector2i(0, 0), "single timeline active")
	c.timelines[1] = c.timelines[0]
	c.timelines[2] = c.timelines[0]
	check(c.active_range() == Vector2i(0, 1), "white's 2nd unanswered branch is inactive")

	var Bot := preload("res://bot.gd")
	var s = Engine5D.new()
	s.setup()
	var plan: Array = Bot.plan_turn(s)
	check(plan.size() == 1, "bot plans one opening move")
	for m in plan:
		s.apply_move(m[0], m[1], m[2], m[3])
	check(s.submit() == "", "bot turn is legal")
	plan = Bot.plan_turn(s)
	for m in plan:
		s.apply_move(m[0], m[1], m[2], m[3])
	check(plan.size() == 1 and s.submit() == "", "bot plays black reply")

	var q = Engine5D.new()
	var qb := PackedInt32Array()
	qb.resize(64)
	qb[0] = 6      # white king a1
	qb[3] = 4      # white rook d1
	qb[59] = -5    # black queen d8, undefended
	qb[63] = -6    # black king h8
	q.timelines = {0: {"start": 0, "boards": [qb]}}
	plan = Bot.plan_turn(q)
	check(plan.size() == 1 and plan[0][3] == Vector4i(3, 7, 0, 0), "bot takes a hanging queen (got %s)" % [plan])
	quit(1 if fails else 0)
