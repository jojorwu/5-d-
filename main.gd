extends Node2D
## Draws every board of the multiverse: time goes right, timelines go down.

const Engine5D := preload("res://engine.gd")
const Bot := preload("res://bot.gd")
const Sfx := preload("res://sfx.gd")
const SQ := 40.0
const BOARD := SQ * 8
const STEP := Vector2(BOARD + 70, BOARD + 90)
const GLYPHS := ["", "♟", "♞", "♝", "♜", "♛", "♚"]
const LIGHT := Color("e8dcc4")
const DARK := Color("7a8fa6")
const ACCENT := Color("a77bff")
const BOT_SIDE := 1

var game
var turn_start  # snapshot to undo the current turn
var sel := {}   # {"l","t","sq"}
var targets := []
var last := []  # [from Rect2, to Rect2] of the last move
var anim := {}  # piece in flight
var born := {}  # Vector2i(l, t) -> msec the board appeared
var hover := Rect2()
var vs_bot := true
var busy := false
var gen := 0    # bumps on new game so a running bot turn aborts
var dragging := false

var font := SystemFont.new()
var cam := Camera2D.new()
var sfx := Sfx.new()
var title := Label.new()
var status := Label.new()
var note := Label.new()
var banner := Label.new()
var buttons := {}


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color("12131c"))
	font.font_names = PackedStringArray(["Segoe UI Symbol", "DejaVu Sans", "Noto Sans Symbols2"])
	add_child(cam)
	add_child(sfx)
	_build_ui()
	_new_game()


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var th := Theme.new()
	for st in ["normal", "hover", "pressed", "disabled", "focus"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = {"normal": Color("2a2d42"), "hover": Color("3b3f5e"), "pressed": ACCENT.darkened(0.3), "disabled": Color("1c1e2c"), "focus": Color(0, 0, 0, 0)}[st]
		sb.set_corner_radius_all(6)
		sb.content_margin_left = 12
		sb.content_margin_right = 12
		sb.content_margin_top = 6
		sb.content_margin_bottom = 6
		th.set_stylebox(st, "Button", sb)
	th.set_font_size("font_size", "Button", 15)
	th.set_font_size("font_size", "CheckButton", 15)
	th.set_font_size("font_size", "Label", 16)

	var panel := PanelContainer.new()
	panel.theme = th
	panel.position = Vector2(14, 14)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.07, 0.08, 0.12, 0.9)
	bg.border_color = ACCENT * Color(1, 1, 1, 0.6)
	bg.set_border_width_all(2)
	bg.set_corner_radius_all(12)
	bg.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", bg)
	layer.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	title.text = "ХРОНОШАХМАТЫ"
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", ACCENT.lightened(0.3))
	box.add_child(title)
	box.add_child(status)
	note.add_theme_color_override("font_color", Color("ffd36b"))
	note.custom_minimum_size.x = 340
	note.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(note)

	var grid := GridContainer.new()
	grid.columns = 2
	box.add_child(grid)
	for b in [["submit", "✔ Завершить ход", _on_submit], ["undo", "↶ Отменить ход", _on_undo],
			["focus", "◎ К Настоящему", _focus_present], ["resign", "⚑ Сдаться", _on_resign],
			["new", "★ Новая игра", _new_game]]:
		var btn := Button.new()
		btn.text = b[1]
		btn.pressed.connect(func(): sfx.play("click"); b[2].call())
		grid.add_child(btn)
		buttons[b[0]] = btn
	var bot_toggle := CheckButton.new()
	bot_toggle.text = "Против бота (вы — белые)"
	bot_toggle.button_pressed = vs_bot
	bot_toggle.toggled.connect(func(on): vs_bot = on; _new_game())
	box.add_child(bot_toggle)
	var snd := CheckButton.new()
	snd.text = "Звук"
	snd.button_pressed = true
	snd.toggled.connect(func(on): sfx.enabled = on)
	box.add_child(snd)
	var help := Label.new()
	help.text = "ЛКМ — ход · ПКМ — двигать вид · колесо — масштаб"
	help.add_theme_font_size_override("font_size", 13)
	help.modulate = Color(1, 1, 1, 0.55)
	box.add_child(help)

	banner.set_anchors_preset(Control.PRESET_FULL_RECT)
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	banner.add_theme_font_size_override("font_size", 64)
	banner.add_theme_color_override("font_outline_color", Color.BLACK)
	banner.add_theme_constant_override("outline_size", 12)
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(banner)


func _new_game() -> void:
	gen += 1
	busy = false
	game = Engine5D.new()
	game.setup()
	turn_start = game.clone()
	last = []
	anim = {}
	born = {Vector2i(0, 0): Time.get_ticks_msec()}
	banner.visible = false
	cam.zoom = Vector2.ONE
	cam.position = Vector2(BOARD / 2, BOARD / 2)
	_clear("Сделайте ход на доске в зелёной рамке.")


func _clear(msg: String) -> void:
	sel = {}
	targets = []
	note.text = msg
	_refresh()


func _refresh() -> void:
	var side := "● Ход белых" if game.player == 0 else "○ Ход чёрных"
	if vs_bot:
		side += " (бот думает…)" if busy else " (вы)" if game.player != BOT_SIDE else ""
	var s := "%s\nНастоящее: ход %d · линий времени: %d" % [side, game.present() / 2 + 1, game.timelines.size()]
	if game.winner < 0 and game.king_attacked(game.player, true):
		s += "\n⚠ ШАХ"
	status.text = s
	var locked: bool = busy or game.winner >= 0
	buttons.submit.disabled = locked or not game.can_submit()
	buttons.undo.disabled = locked
	buttons.resign.disabled = locked
	queue_redraw()


func _on_submit() -> void:
	if busy or game.winner >= 0:
		return
	var err: String = game.submit()
	if err != "":
		sfx.play("error")
		_clear(err)
		return
	_after_turn()
	if vs_bot and game.player == BOT_SIDE:
		_bot_turn()


func _after_turn() -> void:
	turn_start = game.clone()
	sfx.play("check" if game.king_attacked(game.player, true) else "turn")
	_focus_present()
	_clear("")


func _on_undo() -> void:
	game = turn_start.clone()
	last = []
	anim = {}
	_clear("")


func _on_resign() -> void:
	_finish(1 - game.player)


func _finish(w: int) -> void:
	game.winner = w
	busy = false
	sfx.play("win")
	banner.text = "Победа %s!" % ("белых" if w == 0 else "чёрных")
	banner.add_theme_color_override("font_color", Color.WHITE if w == 0 else Color("9aa4c8"))
	banner.visible = true
	banner.modulate.a = 0
	banner.scale = Vector2.ONE
	create_tween().tween_property(banner, "modulate:a", 1.0, 0.8)
	_clear("")


func _bot_turn() -> void:
	var my_gen := gen
	busy = true
	_refresh()
	var th := Thread.new()
	var snapshot = game.clone()
	th.start(func(): return Bot.plan_turn(snapshot))
	while th.is_alive():
		await get_tree().process_frame
	var moves: Array = th.wait_to_finish()
	await get_tree().create_timer(0.35).timeout
	if my_gen != gen:
		return
	if moves.is_empty():
		_finish(1 - BOT_SIDE)
		note.text = "У бота нет легального хода — мат!"
		return
	for m in moves:
		_do_move(m[0], m[1], m[2], m[3])
		await get_tree().create_timer(0.8 if anim.travel else 0.45).timeout
		if my_gen != gen:
			return
		if game.winner >= 0:
			return  # _do_move already called _finish
	game.submit()  # plan_turn only returns legal turns
	busy = false
	_after_turn()


func _do_move(l: int, t: int, sq: int, to: Vector4i) -> void:
	var pc: int = game.board(l, t)[sq]
	var captured: bool = game.board(to.w, to.z)[to.y * 8 + to.x] != 0
	var travel := to.z != t or to.w != l
	var dest: Vector2i = game.apply_move(l, t, sq, to)
	var now := Time.get_ticks_msec()
	born[Vector2i(l, t + 1)] = now
	born[dest] = now
	var from_r := sq_rect(l, t + 1, sq & 7, sq >> 3)
	var to_r := sq_rect(dest.x, dest.y, to.x, to.y)
	last = [from_r, to_r]
	anim = {"from": sq_rect(l, t, sq & 7, sq >> 3).position, "to": to_r.position, "pc": pc, "l": dest.x, "t": dest.y,
		"sq": to.y * 8 + to.x, "start": now, "dur": 750.0 if travel else 280.0, "travel": travel}
	sfx.play("travel" if travel else "capture" if captured else "move")
	if game.winner >= 0:
		_finish(game.winner)
	_clear("Можно завершить ход." if game.can_submit() and not busy and game.winner < 0 else "")


func _focus_present() -> void:
	var r: Vector2i = game.active_range()
	var target := Vector2(game.present() * STEP.x + BOARD / 2, (r.x + r.y) * 0.5 * STEP.y + BOARD / 2)
	create_tween().tween_property(cam, "position", target, 0.6).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func board_pos(l: int, t: int) -> Vector2:
	return Vector2(t * STEP.x, l * STEP.y)


func sq_rect(l: int, t: int, x: int, y: int) -> Rect2:
	return Rect2(board_pos(l, t) + Vector2(x * SQ, (7 - y) * SQ), Vector2(SQ, SQ))


func _process(_dt: float) -> void:
	var m := get_global_mouse_position()
	var t := floori(m.x / STEP.x)
	var l := floori(m.y / STEP.y)
	var local := m - board_pos(l, t)
	hover = Rect2()
	if game.is_playable(l, t, game.player) and Rect2(0, 0, BOARD, BOARD).has_point(local):
		hover = sq_rect(l, t, int(local.x / SQ), 7 - int(local.y / SQ))
	queue_redraw()  # cheap 2D redraw every frame keeps animations simple


func _draw() -> void:
	var now := Time.get_ticks_msec()
	var p: int = game.present()
	var keys: Array = game.timelines.keys()
	var pulse := 0.25 + 0.1 * sin(now / 300.0)
	var px := p * STEP.x + BOARD / 2
	draw_line(Vector2(px, keys.min() * STEP.y - 50), Vector2(px, keys.max() * STEP.y + BOARD + 50), Color(1, 0.8, 0.3, pulse), BOARD + 40)
	for l: int in keys:
		var tl = game.timelines[l]
		var y := l * STEP.y + BOARD / 2
		var col := ACCENT if game.is_active(l) else Color(0.4, 0.4, 0.45)
		draw_line(Vector2(tl.start * STEP.x - 20, y), Vector2(game.end_t(l) * STEP.x + BOARD + 20, y), col * Color(1, 1, 1, 0.5), 14)
		draw_string(font, Vector2(tl.start * STEP.x - 70, y + 8), "L%+d" % l if l != 0 else "L0", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, col.lightened(0.4))
		for i in tl.boards.size():
			_draw_board(l, tl.start + i, tl.boards[i], game.is_active(l), now)
	for r: Rect2 in last:
		draw_rect(r, Color(1, 0.85, 0.2, 0.35))
	if hover.size != Vector2.ZERO:
		draw_rect(hover, Color(1, 1, 1, 0.8), false, 2)
	if sel:
		draw_rect(sq_rect(sel.l, sel.t, sel.sq & 7, sel.sq >> 3), Color(1, 1, 0, 0.5))
	for to: Vector4i in targets:
		var r := sq_rect(to.w, to.z, to.x, to.y)
		var cap: bool = game.board(to.w, to.z)[to.y * 8 + to.x] != 0
		var c := Color(0.95, 0.25, 0.25, 0.75) if cap else (ACCENT if to.z != sel.t or to.w != sel.l else Color(0.25, 0.85, 0.4))
		if cap:
			draw_arc(r.get_center(), SQ * 0.45, 0, TAU, 24, c, 4)
		else:
			draw_circle(r.get_center(), SQ * (0.16 + 0.03 * sin(now / 150.0)), c * Color(1, 1, 1, 0.85))
	_draw_flight(now)


func _draw_board(l: int, t: int, b: PackedInt32Array, active: bool, now: int) -> void:
	var a := clampf((now - born.get(Vector2i(l, t), 0)) / 350.0, 0, 1)
	var pos := board_pos(l, t) + Vector2((1 - a) * -30, 0)
	var fade := Color(1, 1, 1, a)
	var frame := Color(0.92, 0.92, 0.95) if t % 2 == 0 else Color(0.2, 0.2, 0.25)
	if game.is_playable(l, t, game.player) and game.winner < 0:
		frame = Color(0.3, 0.9, 0.5).lerp(Color.WHITE, 0.15 + 0.15 * sin(now / 250.0))
	draw_rect(Rect2(pos - Vector2(9, 9), Vector2(BOARD + 18, BOARD + 18)), Color(0, 0, 0, 0.4 * a))
	draw_rect(Rect2(pos - Vector2(6, 6), Vector2(BOARD + 12, BOARD + 12)), frame * fade)
	var dim := 1.0 if active else 0.45
	var flying: bool = not anim.is_empty() and now - anim.start < anim.dur and anim.l == l and anim.t == t
	for sq in 64:
		var cx := sq & 7
		var cy := sq >> 3
		var r := Rect2(pos + Vector2(cx * SQ, (7 - cy) * SQ), Vector2(SQ, SQ))
		draw_rect(r, (LIGHT if (cx + cy) % 2 == 1 else DARK) * Color(dim, dim, dim, a))
		if b[sq] != 0 and not (flying and anim.sq == sq):
			_draw_piece(r.position, b[sq], a)
	draw_string(font, pos + Vector2(0, -14), "ход %d · %s" % [t / 2 + 1, "белые" if t % 2 == 0 else "чёрные"], HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1, 1, 1, 0.6 * a))


func _draw_piece(at: Vector2, pc: int, alpha: float) -> void:
	var base := at + Vector2(0, SQ * 0.82)
	var g: String = GLYPHS[absi(pc)]
	draw_string_outline(font, base, g, HORIZONTAL_ALIGNMENT_CENTER, SQ, 32, 4, (Color.BLACK if pc > 0 else Color.WHITE) * Color(1, 1, 1, alpha))
	draw_string(font, base, g, HORIZONTAL_ALIGNMENT_CENTER, SQ, 32, (Color.WHITE if pc > 0 else Color.BLACK) * Color(1, 1, 1, alpha))


## The moving piece: slides on its board, arcs with a glowing trail when it travels in time.
func _draw_flight(now: int) -> void:
	if anim.is_empty() or now - anim.start >= anim.dur:
		return
	var k := ease((now - anim.start) / anim.dur, -2.0)
	var lift := Vector2(0, -sin(k * PI) * 140) if anim.travel else Vector2.ZERO
	if anim.travel:
		for i in 12:
			var kk := maxf(0, k - i * 0.03)
			var pt: Vector2 = anim.from.lerp(anim.to, kk) + Vector2(0, -sin(kk * PI) * 140) + Vector2(SQ, SQ) / 2
			draw_circle(pt, SQ * 0.4 * (1 - i / 12.0), ACCENT * Color(1, 1, 1, 0.35 * (1 - i / 12.0)))
	_draw_piece(anim.from.lerp(anim.to, k) + lift, anim.pc, 1.0)


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP and e.pressed:
			cam.zoom = (cam.zoom * 1.1).clampf(0.05, 3)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN and e.pressed:
			cam.zoom = (cam.zoom / 1.1).clampf(0.05, 3)
		elif e.button_index in [MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			dragging = e.pressed
		elif e.button_index == MOUSE_BUTTON_LEFT and e.pressed:
			_click(get_global_mouse_position())
	elif e is InputEventMouseMotion and dragging:
		cam.position -= e.relative / cam.zoom


func _click(world: Vector2) -> void:
	if game.winner >= 0 or busy or (vs_bot and game.player == BOT_SIDE):
		return
	var t := floori(world.x / STEP.x)
	var l := floori(world.y / STEP.y)
	var local := world - board_pos(l, t)
	if game.board(l, t) == null or not Rect2(0, 0, BOARD, BOARD).has_point(local):
		_clear(note.text)
		return
	var x := int(local.x / SQ)
	var y := 7 - int(local.y / SQ)
	var hit := Vector4i(x, y, t, l)
	if sel and hit in targets:
		_do_move(sel.l, sel.t, sel.sq, hit)
		return
	var pc: int = game.board(l, t)[y * 8 + x]
	if game.is_playable(l, t, game.player) and pc != 0 and (pc > 0) == (game.player == 0):
		_clear(note.text)
		sel = {"l": l, "t": t, "sq": y * 8 + x}
		targets = game.moves_from(l, t, y * 8 + x)
		sfx.play("click")
	else:
		_clear(note.text)
