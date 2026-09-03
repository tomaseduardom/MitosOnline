extends RefCounted
class_name ResponseWindowHandler
## ResponseWindowHandler — Overlays de "ventana de respuesta": Paso D
## genérico (ActionPipeline.step_d_waiting, para habilidades activadas/cartas
## jugadas en la Pila) y el caso especial de Signo Amarillo (2026-08-26,
## TriggerSystem.waiting_for_responses, para triggers ETB de Oro/fuera del
## juego — señal separada porque TriggerResolution._wait_for_response_window()
## solo la emite cuando de verdad hay algo que pueda responder).
## Opera sobre CardInspectionLayer via _inspector (y sobre el Main del juego
## via _inspector._main).
## Extraído de CardInspectionLayer.gd (2026-08-28, "módulos gordos").

var _inspector: CardInspectionLayer

var _step_d_overlay: Node = null
var _trigger_response_overlay: Node = null


func setup(inspector: CardInspectionLayer) -> void:
	_inspector = inspector


func _on_step_d_waiting(stack_obj: Dictionary, priority_player: int) -> void:
	if _step_d_overlay and is_instance_valid(_step_d_overlay):
		_step_d_overlay.queue_free()
	var ability_name = stack_obj.get("name", "Habilidad")
	var layer = CanvasLayer.new()
	layer.layer = 90
	_inspector._main.add_child(layer)
	_step_d_overlay = layer
	var panel = PanelContainer.new()
	panel.set_anchor(SIDE_LEFT,   0.5)
	panel.set_anchor(SIDE_TOP,    0.0)
	panel.set_anchor(SIDE_RIGHT,  0.5)
	panel.set_anchor(SIDE_BOTTOM, 0.0)
	panel.set_offset(SIDE_LEFT,  -210)
	panel.set_offset(SIDE_TOP,     8)
	panel.set_offset(SIDE_RIGHT,  210)
	panel.set_offset(SIDE_BOTTOM, 88)
	layer.add_child(panel)
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)
	var title = Label.new()
	title.text = "⏸ Ventana de Respuesta"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	title.add_theme_font_size_override("font_size", 13)
	vbox.add_child(title)
	var name_lbl = Label.new()
	name_lbl.text = ability_name
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 11)
	name_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	vbox.add_child(name_lbl)
	var status_lbl = Label.new()
	status_lbl.text = "El oponente puede responder..."
	status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_lbl.add_theme_font_size_override("font_size", 10)
	status_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	vbox.add_child(status_lbl)
	var btn_row = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 12)
	vbox.add_child(btn_row)
	var btn_pass = Button.new()
	btn_pass.text = "Pasar ▶"
	btn_pass.pressed.connect(_pass_both_priority.bind(status_lbl))
	btn_row.add_child(btn_pass)

	# Signo Amarillo (2026-08-26): mientras esta ventana de respuesta esté
	# abierta por una habilidad de Oro o de fuera del juego (mano, destierro,
	# cementerio, castillo), si quien tiene prioridad para responder controla
	# un Oro con ese texto sin convertir todavía, se le ofrece el botón para
	# convertirlo y cancelar lo que está en la Pila.
	if _qualifies_for_signo_amarillo(stack_obj):
		var signo_card := _find_signo_amarillo_in_reserve(priority_player)
		if signo_card:
			var btn_signo = Button.new()
			btn_signo.text = "Convertir Oro (cancelar)"
			btn_signo.tooltip_text = "Convertir %s en un Oro sin habilidad para cancelar esta habilidad" % str(signo_card.card_name)
			btn_signo.pressed.connect(func():
				signo_card.is_converted = true
				ActionPipeline.cancel_stack_object(stack_obj.get("id", -1))
				_pass_both_priority(status_lbl)
			)
			btn_row.add_child(btn_signo)

	_inspector.get_tree().create_timer(2.0).timeout.connect(func():
		if _step_d_overlay and is_instance_valid(_step_d_overlay):
			_pass_both_priority(null)
	)
	panel.modulate.a = 0.0
	var tw = _inspector.create_tween()
	tw.tween_property(panel, "modulate:a", 1.0, 0.2)


func _qualifies_for_signo_amarillo(stack_obj: Dictionary) -> bool:
	"""¿La fuente de este objeto de la Pila es un Oro, o una carta fuera del
	juego (Mano/Destierro/Cementerio/Castillo)? Esas dos categorías son las
	que Signo Amarillo puede cancelar (2026-08-26, texto real de la carta)."""
	var context: Dictionary = stack_obj.get("context", {})
	var source_data: Dictionary = context.get("source_card", stack_obj.get("card_data", {}))
	if source_data.get("tipo", -1) == Constants.CardType.ORO:
		return true
	var source_node = context.get("source_card_node")
	if source_node and is_instance_valid(source_node):
		var off_board_zones = [Constants.Zone.MANO, Constants.Zone.DESTIERRO, Constants.Zone.CEMENTERIO, Constants.Zone.CASTILLO]
		return source_node.get("current_zone") in off_board_zones
	return false


func _find_signo_amarillo_in_reserve(player_id: int) -> Node:
	"""Busca en la Reserva de Oro de player_id un Oro con el texto de Signo
	Amarillo que todavía no se haya convertido — detección por texto, no por
	nombre, para cubrir cualquier carta con el mismo patrón."""
	var container = _inspector._main.player_gold if player_id == 0 else _inspector._main.opponent_gold
	if not container:
		return null
	for c in container.get_children():
		if not is_instance_valid(c) or c.get("is_converted") == true:
			continue
		var ability_text: String = str(c.get("card_ability") if c.get("card_ability") != null else "")
		if "convertir este oro en un oro sin habilidad" in ability_text.to_lower():
			return c
	return null


func _pass_both_priority(status_label) -> void:
	if not PriorityManager.priority_window_active:
		return
	PriorityManager.pass_priority()
	if status_label and is_instance_valid(status_label):
		status_label.text = "Resolviendo..."
	await _inspector.get_tree().create_timer(0.35).timeout
	if PriorityManager.priority_window_active:
		PriorityManager.pass_priority()


func _on_step_d_completed(_stack_obj: Dictionary, _had_response: bool) -> void:
	if _step_d_overlay and is_instance_valid(_step_d_overlay):
		_step_d_overlay.queue_free()
		_step_d_overlay = null


func _on_trigger_waiting_for_responses(trigger: Dictionary, responding_player: int) -> void:
	"""Ventana de respuesta para triggers ETB de Oro/fuera del juego
	(2026-08-26) — TriggerResolution._wait_for_response_window() solo emite
	esta señal cuando de verdad hay algo que pueda responder (un Signo
	Amarillo sin convertir), así que si no lo encontramos acá algo cambió
	de estado entremedio — no mostrar nada en vez de romper."""
	if _trigger_response_overlay and is_instance_valid(_trigger_response_overlay):
		_trigger_response_overlay.queue_free()
	var signo_card := _find_signo_amarillo_in_reserve(responding_player)
	if not signo_card:
		return
	var source_card: Node = trigger.get("card")
	var card_name: String = str(source_card.card_name) if source_card and is_instance_valid(source_card) else "Habilidad"
	var is_oro: bool = source_card and source_card.get("card_type") == Constants.CardType.ORO

	var layer = CanvasLayer.new()
	layer.layer = 90
	_inspector._main.add_child(layer)
	_trigger_response_overlay = layer
	var panel = PanelContainer.new()
	panel.set_anchor(SIDE_LEFT,   0.5)
	panel.set_anchor(SIDE_TOP,    0.0)
	panel.set_anchor(SIDE_RIGHT,  0.5)
	panel.set_anchor(SIDE_BOTTOM, 0.0)
	panel.set_offset(SIDE_LEFT,  -210)
	panel.set_offset(SIDE_TOP,     8)
	panel.set_offset(SIDE_RIGHT,  210)
	panel.set_offset(SIDE_BOTTOM, 96)
	layer.add_child(panel)
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)
	var title = Label.new()
	title.text = "⏸ Ventana de Respuesta"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	title.add_theme_font_size_override("font_size", 13)
	vbox.add_child(title)
	var name_lbl = Label.new()
	name_lbl.text = "%s (habilidad de %s)" % [card_name, "Oro" if is_oro else "fuera del juego"]
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 11)
	name_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(name_lbl)
	var btn_row = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 12)
	vbox.add_child(btn_row)
	var btn_pass = Button.new()
	btn_pass.text = "Pasar ▶"
	btn_pass.pressed.connect(func():
		TriggerSystem.pass_response()
	)
	btn_row.add_child(btn_pass)
	var btn_signo = Button.new()
	btn_signo.text = "Convertir Oro (cancelar)"
	btn_signo.tooltip_text = "Convertir %s en un Oro sin habilidad para cancelar esta habilidad" % str(signo_card.card_name)
	btn_signo.pressed.connect(func():
		signo_card.is_converted = true
		TriggerSystem.cancel_current_trigger(signo_card)
	)
	btn_row.add_child(btn_signo)
	panel.modulate.a = 0.0
	var tw = _inspector.create_tween()
	tw.tween_property(panel, "modulate:a", 1.0, 0.2)


func _on_trigger_response_window_closed(_trigger: Dictionary, _was_cancelled: bool) -> void:
	if _trigger_response_overlay and is_instance_valid(_trigger_response_overlay):
		_trigger_response_overlay.queue_free()
		_trigger_response_overlay = null
