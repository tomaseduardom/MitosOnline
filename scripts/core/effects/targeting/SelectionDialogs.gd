extends RefCounted
## SelectionDialogs — Los 5 diálogos modales de SelectionManager
## (await_single_pick/await_two_choice/await_choice/await_castillo_pick/
## await_multi_pick), la API externa dominante de SelectionManager (54x/52x/
## 33x/4x/2x llamadas en todo el proyecto). Construyen su PROPIA UI
## descartable (CanvasLayer/Panel/etc.), independiente del panel de
## selección de cartas (open()/open_selection()/_create_selection_card(),
## que se quedan en SelectionManager.gd). Opera sobre SelectionManager via
## _main (señales card_selected/selection_completed/selection_cancelled,
## open_selection(), constantes de assets).
## Extraído de SelectionManager.gd (Fase 4 de reestructuración, "módulos gordos").

var _main: CanvasLayer


func setup(main: CanvasLayer) -> void:
	_main = main


func await_single_pick(candidates: Array, title: String, can_cancel: bool = true, min_selections: int = 1, filter: Callable = Callable()) -> Dictionary:
	"""Abre un panel CUSTOM de 1-sola-elección y espera la respuesta —
	extraído (2026-08-30) del mismo bloque de 15-20 líneas que se repetía
	copiado en Don de Amma, Tesoro de los Césares, Miguel, las dos de Tyet,
	Bernardo O'Higgins y varias más: open_selection() + Dictionary de
	estado (los lambdas de GDScript capturan variables locales por VALOR,
	así que 'var picked'/'var done' sueltos nunca se enteraban de la
	elección real — ver el resto de este archivo para más detalle de ese
	bug ya conocido) + conectar card_selected/selection_completed/
	selection_cancelled + esperar + desconectar.
	max_selections=1 siempre; min_selections=1 por defecto (con eso,
	SelectionManager emite 'card_selected' apenas se elige la primera, no
	hace falta escuchar 'selection_completed'). min_selections=0 (p.ej.
	costo opcional tipo Bernardo O'Higgins: 'Puedes Barajar...') SÍ puede
	terminar en 'selection_completed' con array vacío (confirmó sin elegir
	nada) — se escuchan las dos señales siempre, la de más no molesta.
	Returns: el card_data elegido, o {} si se canceló o confirmó vacío."""
	_main.open_selection(candidates, _main.SelectionMode.CUSTOM, {
		"title": title,
		"max_selections": 1,
		"min_selections": min_selections,
		"can_cancel": can_cancel,
		"filter": filter,
	})
	var state := {"resolved": false, "picked": {}}
	var on_single := func(d: Dictionary):
		state.picked = d
		state.resolved = true
	var on_completed := func(cards: Array):
		if not cards.is_empty():
			state.picked = cards[0]
		state.resolved = true
	var on_cancelled := func():
		state.resolved = true
	_main.card_selected.connect(on_single, CONNECT_ONE_SHOT)
	_main.selection_completed.connect(on_completed, CONNECT_ONE_SHOT)
	_main.selection_cancelled.connect(on_cancelled, CONNECT_ONE_SHOT)
	while not state.resolved:
		await _main.get_tree().process_frame
	if _main.card_selected.is_connected(on_single):
		_main.card_selected.disconnect(on_single)
	if _main.selection_completed.is_connected(on_completed):
		_main.selection_completed.disconnect(on_completed)
	if _main.selection_cancelled.is_connected(on_cancelled):
		_main.selection_cancelled.disconnect(on_cancelled)
	return state.picked


func await_two_choice(main: Node, title: String, option_a: String, option_b: String) -> bool:
	"""Popup de 2 botones estilizado con estética Fantasy TCG.
	Returns: true si se eligió option_a, false si option_b."""
	var picked_idx: int = await await_choice(main, title, [option_a, option_b])
	return picked_idx == 0


func await_choice(main: Node, title: String, options: Array) -> int:
	"""Modal de Elección estilizado Fantasy TCG con fondo de altar catedralicio,
	shader de viñeta suave y botones dorados de alta legibilidad (sin emojis).
	Returns: el índice (0-based) de la opción elegida."""
	var canvas := CanvasLayer.new()
	canvas.layer = 70
	main.add_child(canvas)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.75)
	bg.size = main.get_viewport().get_visible_rect().size
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas.add_child(bg)

	var num_opts: int = options.size()
	# Layout vertical si son 3+ opciones o si el texto es largo, u horizontal si son 2 cortas
	var has_long_text: bool = false
	for opt in options:
		if str(opt).length() > 28:
			has_long_text = true
			break
	var is_vertical: bool = num_opts >= 3 or has_long_text

	var panel_w: float = 720.0 if not is_vertical else 640.0
	var panel_h: float = 190.0 if not is_vertical else (110.0 + float(num_opts) * 54.0)

	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -panel_w / 2.0
	panel.offset_top = -panel_h / 2.0
	panel.offset_right = panel_w / 2.0
	panel.offset_bottom = panel_h / 2.0

	var p_style := StyleBoxFlat.new()
	p_style.bg_color = Color(0.03, 0.03, 0.05, 0.98)
	p_style.set_corner_radius_all(18)
	p_style.shadow_color = Color(0, 0, 0, 0.85)
	p_style.shadow_size = 30
	panel.add_theme_stylebox_override("panel", p_style)
	canvas.add_child(panel)

	# Fondo Altar Catedralicio con Viñeta Suave
	var bg_rect := TextureRect.new()
	bg_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg_rect.texture = _main.TEX_ALTAR_BG
	bg_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var smat := ShaderMaterial.new()
	smat.shader = _main.SHADER_VIGNETTE
	smat.set_shader_parameter("panel_size", Vector2(panel_w, panel_h))
	smat.set_shader_parameter("corner_radius", 18.0)
	smat.set_shader_parameter("vignette_amount", 0.70)
	smat.set_shader_parameter("tint_color", Color(0.02, 0.02, 0.03, 0.30))
	smat.set_shader_parameter("edge_shadow_color", Color(0.01, 0.01, 0.02, 0.95))
	bg_rect.material = smat
	panel.add_child(bg_rect)

	var main_vbox := VBoxContainer.new()
	main_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_vbox.offset_left = 24
	main_vbox.offset_top = 18
	main_vbox.offset_right = -24
	main_vbox.offset_bottom = -18
	main_vbox.add_theme_constant_override("separation", 12)
	panel.add_child(main_vbox)

	# Título en Cinzel-Bold
	var title_lbl := Label.new()
	title_lbl.text = title.to_upper()
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.add_theme_font_override("font", _main.FONT_CINZEL_BOLD)
	title_lbl.add_theme_font_size_override("font_size", 17)
	title_lbl.add_theme_color_override("font_color", Color(0.95, 0.85, 0.60, 1.0))
	title_lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	title_lbl.add_theme_constant_override("shadow_offset_x", 1)
	title_lbl.add_theme_constant_override("shadow_offset_y", 2)
	main_vbox.add_child(title_lbl)

	# Línea separadora dorada
	var sep := ColorRect.new()
	sep.custom_minimum_size = Vector2(0, 1)
	sep.color = Color(0.75, 0.60, 0.35, 0.40)
	main_vbox.add_child(sep)

	# Contenedor de Opciones
	var opts_box: BoxContainer = VBoxContainer.new() if is_vertical else HBoxContainer.new()
	opts_box.alignment = BoxContainer.ALIGNMENT_CENTER
	opts_box.add_theme_constant_override("separation", 12)
	opts_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(opts_box)

	var state := {"done": false, "picked_index": 0}

	for i in range(num_opts):
		var btn := Button.new()
		btn.text = str(options[i])
		btn.focus_mode = Control.FOCUS_NONE
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.add_theme_font_override("font", _main.FONT_CINZEL_BOLD)
		btn.add_theme_font_size_override("font_size", 14)
		if not is_vertical:
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.custom_minimum_size = Vector2(180, 42)

		# Estilo normal (borde dorado tenue y fondo oscuro elegante)
		var btn_normal := StyleBoxFlat.new()
		btn_normal.bg_color = Color(0.08, 0.09, 0.12, 0.88)
		btn_normal.set_border_width_all(1)
		btn_normal.border_color = Color(0.70, 0.58, 0.35, 0.75)
		btn_normal.set_corner_radius_all(8)
		btn_normal.content_margin_left = 18
		btn_normal.content_margin_right = 18
		btn_normal.content_margin_top = 8
		btn_normal.content_margin_bottom = 8
		btn.add_theme_stylebox_override("normal", btn_normal)
		btn.add_theme_color_override("font_color", Color(0.92, 0.88, 0.80, 1.0))

		# Estilo hover (brillo dorado y fondo iluminado)
		var btn_hover := StyleBoxFlat.new()
		btn_hover.bg_color = Color(0.16, 0.18, 0.24, 0.95)
		btn_hover.set_border_width_all(2)
		btn_hover.border_color = Color(1.0, 0.88, 0.50, 1.0)
		btn_hover.set_corner_radius_all(8)
		btn_hover.content_margin_left = 18
		btn_hover.content_margin_right = 18
		btn_hover.content_margin_top = 8
		btn_hover.content_margin_bottom = 8
		btn.add_theme_stylebox_override("hover", btn_hover)
		btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 0.95, 1.0))

		var btn_pressed := btn_hover.duplicate()
		btn_pressed.bg_color = Color(0.22, 0.24, 0.32, 1.0)
		btn.add_theme_stylebox_override("pressed", btn_pressed)

		var captured_idx: int = i
		btn.pressed.connect(func():
			state.picked_index = captured_idx
			state.done = true
		)
		opts_box.add_child(btn)

	# Animación de entrada suave
	panel.scale = Vector2(0.94, 0.94)
	panel.pivot_offset = Vector2(panel_w / 2.0, panel_h / 2.0)
	var tween := panel.create_tween()
	tween.tween_property(panel, "scale", Vector2.ONE, 0.18).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)

	while not state.done:
		await main.get_tree().process_frame

	canvas.queue_free()
	return state.picked_index


var _castillo_pick_active: bool = false
var _castillo_pick_callback: Callable = Callable()
var _castillo_pick_cleanup: Callable = Callable()


func start_castillo_pick(main: Node, title: String, callback: Callable) -> void:
	"""Versión 'start' de await_castillo_pick() (2026-09-06, a pedido del
	usuario) — separada para poder correr EN CARRERA contra otro tipo de
	selección (p.ej. CardInteractionModule.start_target_selection(), usada
	por Sherlock Holmes para elegir entre 'cartas en juego' o 'un Castillo'
	con el primer click real, sin preguntar antes). El que resuelve primero
	debe cancelar al otro (ver cancel_castillo_pick()). callback recibe
	true/false (propio/rival)."""
	var player_castillo: Panel = main.get_node_or_null("GameBoard/PlayerArea/PlayerCastillo")
	var opponent_castillo: Panel = main.get_node_or_null("GameBoard/OpponentArea/OpponentCastillo")
	if not player_castillo or not opponent_castillo:
		# No debería pasar (nodos fijos de Main.tscn) — fallback al popup viejo.
		callback.call(await await_two_choice(main, title, "Tu Castillo", "Castillo del oponente"))
		return

	if main.has_method("_update_debug"):
		main._update_debug("%s — clickea tu Castillo o el del rival" % title)

	_castillo_pick_active = true
	_castillo_pick_callback = callback

	_set_castillo_pick_glow(player_castillo, true)
	_set_castillo_pick_glow(opponent_castillo, true)
	var prev_player_filter := player_castillo.mouse_filter
	var prev_opponent_filter := opponent_castillo.mouse_filter
	player_castillo.mouse_filter = Control.MOUSE_FILTER_STOP
	opponent_castillo.mouse_filter = Control.MOUSE_FILTER_STOP

	# Cursor de mano + pulso suave de brillo (2026-08-30, a pedido del
	# usuario: "también ponerle un efecto o hacerlo 'cliqueable' para mayor
	# visual" — el borde estático ya avisaba que había que elegir, pero no
	# se sentía interactivo hasta clickear). Se para al resolver, junto con
	# todo lo demás.
	var prev_player_cursor := player_castillo.mouse_default_cursor_shape
	var prev_opponent_cursor := opponent_castillo.mouse_default_cursor_shape
	player_castillo.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	opponent_castillo.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	var pulse_player := player_castillo.create_tween()
	pulse_player.set_loops()
	pulse_player.tween_property(player_castillo, "modulate", Color(1.25, 1.25, 1.25, 1.0), 0.6).set_trans(Tween.TRANS_SINE)
	pulse_player.tween_property(player_castillo, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.6).set_trans(Tween.TRANS_SINE)
	var pulse_opponent := opponent_castillo.create_tween()
	pulse_opponent.set_loops()
	pulse_opponent.tween_property(opponent_castillo, "modulate", Color(1.25, 1.25, 1.25, 1.0), 0.6).set_trans(Tween.TRANS_SINE)
	pulse_opponent.tween_property(opponent_castillo, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.6).set_trans(Tween.TRANS_SINE)

	var on_player_input: Callable
	var on_opponent_input: Callable
	_castillo_pick_cleanup = func() -> void:
		if player_castillo.gui_input.is_connected(on_player_input):
			player_castillo.gui_input.disconnect(on_player_input)
		if opponent_castillo.gui_input.is_connected(on_opponent_input):
			opponent_castillo.gui_input.disconnect(on_opponent_input)
		player_castillo.mouse_filter = prev_player_filter
		opponent_castillo.mouse_filter = prev_opponent_filter
		player_castillo.mouse_default_cursor_shape = prev_player_cursor
		opponent_castillo.mouse_default_cursor_shape = prev_opponent_cursor
		pulse_player.kill()
		pulse_opponent.kill()
		player_castillo.modulate = Color(1.0, 1.0, 1.0, 1.0)
		opponent_castillo.modulate = Color(1.0, 1.0, 1.0, 1.0)
		_set_castillo_pick_glow(player_castillo, false)
		_set_castillo_pick_glow(opponent_castillo, false)

	on_player_input = func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			_resolve_castillo_pick(true)
	on_opponent_input = func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			_resolve_castillo_pick(false)
	player_castillo.gui_input.connect(on_player_input)
	opponent_castillo.gui_input.connect(on_opponent_input)


func _resolve_castillo_pick(picked_own: bool) -> void:
	if not _castillo_pick_active:
		return
	_castillo_pick_active = false
	var callback := _castillo_pick_callback
	var cleanup := _castillo_pick_cleanup
	_castillo_pick_callback = Callable()
	_castillo_pick_cleanup = Callable()
	if cleanup.is_valid():
		cleanup.call()
	if callback.is_valid():
		callback.call(picked_own)


func cancel_castillo_pick() -> void:
	"""Cancela una selección de Castillo en curso SIN invocar el callback —
	usado cuando otra selección en carrera (p.ej. una carta en juego) ganó
	primero (ver start_castillo_pick())."""
	if not _castillo_pick_active:
		return
	_castillo_pick_active = false
	var cleanup := _castillo_pick_cleanup
	_castillo_pick_callback = Callable()
	_castillo_pick_cleanup = Callable()
	if cleanup.is_valid():
		cleanup.call()


func await_castillo_pick(main: Node, title: String) -> bool:
	"""Espera un click directo sobre el Panel del Castillo propio o del
	rival en el tablero — reemplaza el popup de 2 botones de texto para
	elegir 'tu Castillo o el del oponente' (2026-08-30, a pedido del
	usuario: 'estaría bueno poder hacer click al castillo para hacerlo más
	interactivo', p.ej. Infernum Vox, Aho, Espada del Juicio). Resalta
	ambos paneles con un borde celeste mientras espera. Sin cancelar —
	mismo criterio que await_two_choice(), es una elección obligatoria
	entre dos zonas, no un 'puedes'. Envoltorio de start_castillo_pick()
	(2026-09-06, mismo split que start_target_selection()/await_target()).
	Returns: true si se clickeó el Castillo propio, false si el rival."""
	var state := {"done": false, "picked_own": true}
	start_castillo_pick(main, title, func(v: bool) -> void:
		state.picked_own = v
		state.done = true)
	while not state.done:
		await main.get_tree().process_frame
	return state.picked_own


func _set_castillo_pick_glow(panel: Panel, on: bool) -> void:
	if not on:
		panel.remove_theme_stylebox_override("panel")
		return
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0)
	style.border_color = Color(1.0, 0.85, 0.38, 0.95)
	style.set_border_width_all(3)
	style.set_corner_radius_all(8)
	style.shadow_color = Color(1.0, 0.78, 0.25, 0.55)
	style.shadow_size = 16
	panel.add_theme_stylebox_override("panel", style)


func await_multi_pick(candidates: Array, title: String, max_selections: int, min_selections: int = 0, can_cancel: bool = true, filter: Callable = Callable()) -> Dictionary:
	"""Selección múltiple (0 a max_selections) y espera la respuesta —
	extraído (2026-08-30) del mismo bloque repetido en
	_resolve_search_cemetery_to_hand()/_select_hand_cards_for_discard()
	(TargetedEffectExecutor.gd) y _resolve_reveal_cost_reduction()
	(GoldManager.gd). A diferencia de await_single_pick(), acá 'canceló
	del todo' y 'confirmó sin elegir nada' son resultados DISTINTOS a
	propósito (algunos llamadores necesitan diferenciarlos: declinar el
	'puedes' entero vs. aceptarlo pero no encontrar nada que valga la
	pena elegir) — por eso devuelve un Dictionary con las dos señales en
	vez de colapsarlas en un Array vacío como haría await_single_pick().
	Returns: {"cancelled": bool, "picked": Array[Dictionary]}."""
	_main.open_selection(candidates, _main.SelectionMode.CUSTOM, {
		"title": title,
		"max_selections": max_selections,
		"min_selections": min_selections,
		"can_cancel": can_cancel,
		"filter": filter,
	})
	var state := {"resolved": false, "picked": [], "cancelled": false}
	var on_single := func(d: Dictionary):
		state.picked = [d]
		state.resolved = true
	var on_completed := func(cards: Array):
		state.picked = cards
		state.resolved = true
	var on_cancelled := func():
		state.cancelled = true
		state.resolved = true
	_main.card_selected.connect(on_single, CONNECT_ONE_SHOT)
	_main.selection_completed.connect(on_completed, CONNECT_ONE_SHOT)
	_main.selection_cancelled.connect(on_cancelled, CONNECT_ONE_SHOT)
	while not state.resolved:
		await _main.get_tree().process_frame
	if _main.card_selected.is_connected(on_single):
		_main.card_selected.disconnect(on_single)
	if _main.selection_completed.is_connected(on_completed):
		_main.selection_completed.disconnect(on_completed)
	if _main.selection_cancelled.is_connected(on_cancelled):
		_main.selection_cancelled.disconnect(on_cancelled)
	return {"cancelled": state.cancelled, "picked": state.picked}
