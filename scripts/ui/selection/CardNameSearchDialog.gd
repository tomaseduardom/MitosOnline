extends RefCounted
class_name CardNameSearchDialog
## CardNameSearchDialog — Buscador de cartas por nombre para efectos "nombra
## una carta" (DAR, p.ej. Alicia en Wonderland, Tesoro de los Césares).
## Buscador EN VIVO (2026-08-30, a pedido del usuario: quería un buscador de
## verdad, cuadro de texto y resultados apareciendo en el MISMO panel, no
## dos pasos separados) — reemplaza la versión anterior (texto → Enter →
## overlay de SelectionManager aparte). Cada tecla re-filtra
## CardDatabase.get_all_cards() por substring y reconstruye los resultados
## como cartas reales (mismo CardScene que cualquier otra selección del
## juego, para que se sienta como un buscador de cartas normal, no una
## lista de texto). Clickear una carta del resultado resuelve el diálogo
## entero de una — no hay un paso de confirmación aparte.

const CardScene = preload("res://scenes/cards/Card.tscn")
const MIN_QUERY_LENGTH := 2
const MAX_RESULTS := 24
const RESULT_CARD_SCALE := 0.55

var _main: Node


func setup(main: Node) -> void:
	_main = main


func open_and_wait(prompt: String = "Nombra una carta") -> Dictionary:
	"""Abre el buscador en vivo y espera. Devuelve el card_data elegido, o
	{} si se cancela (botón Cancelar o Escape) sin haber clickeado ninguna
	carta."""
	var layer := CanvasLayer.new()
	layer.layer = 100
	_main.add_child(layer)

	var overlay := Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(overlay)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.05, 0.09, 0.95)
	style.border_color = Color(0.83, 0.69, 0.22, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	panel.add_theme_stylebox_override("panel", style)
	overlay.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var label := Label.new()
	label.text = prompt
	label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5, 1.0))
	vbox.add_child(label)

	var input := LineEdit.new()
	input.placeholder_text = "Escribe el nombre de la carta..."
	input.custom_minimum_size = Vector2(460, 0)
	vbox.add_child(input)

	var results_scroll := ScrollContainer.new()
	results_scroll.custom_minimum_size = Vector2(460, 280)
	vbox.add_child(results_scroll)

	var results_flow := HFlowContainer.new()
	results_flow.add_theme_constant_override("h_separation", 10)
	results_flow.add_theme_constant_override("v_separation", 10)
	results_scroll.add_child(results_flow)

	var status_label := Label.new()
	status_label.text = "Escribe al menos %d letras para buscar..." % MIN_QUERY_LENGTH
	status_label.add_theme_font_size_override("font_size", 12)
	status_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, 1.0))
	vbox.add_child(status_label)

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	vbox.add_child(buttons)
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancelar"
	buttons.add_child(cancel_btn)

	var state := {"resolved": false, "picked": {}}
	var displayed_cards: Array = []

	var clear_results := func():
		for c in displayed_cards:
			if is_instance_valid(c):
				c.queue_free()
		displayed_cards.clear()

	var on_result_clicked := func(clicked_card: Node):
		if state.resolved:
			return
		state.picked = clicked_card.card_data
		state.resolved = true

	var rebuild_results: Callable
	rebuild_results = func():
		clear_results.call()
		var query := input.text.strip_edges().to_lower()
		if query.length() < MIN_QUERY_LENGTH:
			status_label.text = "Escribe al menos %d letras para buscar..." % MIN_QUERY_LENGTH
			return
		var all_cards: Array = CardDatabase.get_all_cards()
		var seen_names := {}
		var shown := 0
		for c in all_cards:
			var nm: String = str(c.get("nombre", ""))
			if nm.is_empty() or not (query in nm.to_lower()):
				continue
			var nm_lower := nm.to_lower()
			if seen_names.has(nm_lower):
				continue
			seen_names[nm_lower] = true
			shown += 1
			if shown > MAX_RESULTS:
				break
			var card_node = CardScene.instantiate()
			card_node.load_from_data(c)
			card_node.scale = Vector2(RESULT_CARD_SCALE, RESULT_CARD_SCALE)
			card_node.base_scale = Vector2(RESULT_CARD_SCALE, RESULT_CARD_SCALE)
			card_node.card_scale_hover = 1.08
			card_node.can_interact = true
			card_node.set_zone(Constants.Zone.CEMENTERIO)
			card_node.card_clicked.connect(on_result_clicked)
			if _main.get("_card_inspector"):
				card_node.card_right_clicked.connect(_main._card_inspector.on_card_right_clicked)
			results_flow.add_child(card_node)
			displayed_cards.append(card_node)
		if shown == 0:
			status_label.text = "Sin resultados para \"%s\"" % query
		elif shown > MAX_RESULTS:
			status_label.text = "%d+ resultados — afiná la búsqueda" % MAX_RESULTS
		else:
			status_label.text = "%d resultado(s)" % shown

	input.text_changed.connect(func(_t): rebuild_results.call())
	cancel_btn.pressed.connect(func(): state.resolved = true)
	overlay.gui_input.connect(func(ev):
		if ev is InputEventKey and ev.pressed and ev.keycode == KEY_ESCAPE:
			state.resolved = true
	)

	input.grab_focus()
	while not state.resolved:
		await _main.get_tree().process_frame

	clear_results.call()
	layer.queue_free()
	return state.picked
