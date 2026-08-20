class_name CardInspectionLayer
extends Node

const CardScene = preload("res://scenes/cards/Card.tscn")

var _main: Node = null

var inspected_card: Node = null
var _ability_buttons_panel: Control = null
var _inspected_source_card: Node = null
var _step_d_overlay: Node = null
var _glowing_cards: Dictionary = {}


func setup(main: Node) -> void:
	_main = main
	var ap = get_node_or_null("/root/ActionPipeline")
	if ap:
		if ap.has_signal("step_d_waiting") and not ap.step_d_waiting.is_connected(_on_step_d_waiting):
			ap.step_d_waiting.connect(_on_step_d_waiting)
		if ap.has_signal("step_d_completed") and not ap.step_d_completed.is_connected(_on_step_d_completed):
			ap.step_d_completed.connect(_on_step_d_completed)
		if ap.has_signal("stack_object_resolved") and not ap.stack_object_resolved.is_connected(_on_ability_glow_resolved):
			ap.stack_object_resolved.connect(_on_ability_glow_resolved)

	var pm = get_node_or_null("/root/PriorityManager")
	if pm and not pm.priority_changed.is_connected(_on_priority_changed_refresh_glows):
		pm.priority_changed.connect(_on_priority_changed_refresh_glows)


func _on_priority_changed_refresh_glows(_player_id: int) -> void:
	refresh_activatable_glows()


# =============================================================================
# INDICADOR PASIVO DE HABILIDAD ACTIVABLE (brillo celeste)
# =============================================================================
func refresh_activatable_glows() -> void:
	"""Prende/apaga el brillo celeste de 'tiene una habilidad activable
	disponible ahora' en cada carta del jugador humano en juego — sin
	necesidad de abrir el panel de inspección. Reutiliza exactamente la
	misma detección y validación que _build_ability_buttons()/_validate_ability()."""
	if not _main:
		return

	if not GameManager.is_game_active or GameManager.active_player_id != 0:
		_clear_all_activatable_glows()
		return

	var pm = get_node_or_null("/root/PriorityManager")
	var in_vigilia = GameManager.current_phase == Constants.Phase.VIGILIA
	var has_priority_window = pm != null and pm.priority_window_active and pm.can_act(0)
	if not in_vigilia and not has_priority_window:
		_clear_all_activatable_glows()
		return

	var candidates: Array = []
	if _main.player_field:
		candidates.append_array(_main.player_field.get_children())
	if _main.player_gold:
		candidates.append_array(_main.player_gold.get_children())

	for card in candidates:
		if not (card is Card) or not is_instance_valid(card):
			continue
		if card.get("card_data") == null:
			continue
		var habilidad_text: String = card.card_data.get("habilidad", "")
		if habilidad_text.is_empty():
			card.set_activatable(false)
			continue
		var card_id: String = str(card.card_data.get("id", ""))
		var all_parsed := UniversalCardParser.parse_abilities(habilidad_text, card_id)
		var abilities: Array = all_parsed.filter(func(a): return a.get("ability_type", "") == "ACTIVATED")
		var can_activate_any := false
		for ability in abilities:
			if _validate_ability(ability, card).get("can", false):
				can_activate_any = true
				break
		card.set_activatable(can_activate_any)


func _clear_all_activatable_glows() -> void:
	if not _main:
		return
	for container in [_main.player_field, _main.player_gold]:
		if not container:
			continue
		for card in container.get_children():
			if card is Card:
				card.set_activatable(false)


func on_card_right_clicked(card: Node) -> void:
	if card.esta_oculta:
		return
	_open_card_inspection(card)


func _open_card_inspection(card: Node) -> void:
	if inspected_card:
		return
	_inspected_source_card = card
	inspected_card = CardScene.instantiate()
	inspected_card.load_from_data(card.card_data)
	inspected_card.can_interact = false
	inspected_card.esta_oculta = card.esta_oculta
	inspected_card.scale = Vector2(0.1, 0.1)
	inspected_card.modulate.a = 0.0
	inspected_card.pivot_offset = inspected_card.custom_minimum_size / 2
	_main.inspection_container.add_child(inspected_card)
	_main.inspection_layer.visible = true
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(inspected_card, "scale", Vector2(2.5, 2.5), 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tween.tween_property(inspected_card, "modulate:a", 1.0, 0.2)
	tween.chain().tween_callback(_build_ability_buttons.bind(card))
	if not _main.inspection_blur.gui_input.is_connected(_on_inspection_blur_input):
		_main.inspection_blur.gui_input.connect(_on_inspection_blur_input)


func _on_inspection_blur_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		close_card_inspection()


func close_card_inspection() -> void:
	if not inspected_card:
		return
	if _ability_buttons_panel and is_instance_valid(_ability_buttons_panel):
		_ability_buttons_panel.queue_free()
		_ability_buttons_panel = null
	_inspected_source_card = null
	var card_to_remove = inspected_card
	inspected_card = null
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(card_to_remove, "scale", Vector2(0.1, 0.1), 0.2).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_BACK)
	tween.tween_property(card_to_remove, "modulate:a", 0.0, 0.15)
	await tween.finished
	card_to_remove.queue_free()
	_main.inspection_layer.visible = false


func _build_ability_buttons(source_card: Node) -> void:
	if not is_instance_valid(source_card):
		return
	if not GameManager.is_game_active:
		return
	if GameManager.active_player_id != 0:
		return
	if source_card.get_meta("owner_id", -1) != 0:
		return

	# Permitir en Vigilia O cuando hay ventana de prioridad activa
	var pm = get_node_or_null("/root/PriorityManager")
	var in_vigilia = GameManager.current_phase == Constants.Phase.VIGILIA
	var has_priority_window = pm != null and pm.priority_window_active and pm.can_act(0)
	if not in_vigilia and not has_priority_window:
		return

	# parse_abilities() es el Compilador Fase 1: detecta TRIGGER y ACTIVATED por Regex.
	# Solo mostramos botones para habilidades ACTIVATED (las que el jugador activa manualmente).
	var card_id: String = str(source_card.card_data.get("id", ""))
	var habilidad_text: String = source_card.card_data.get("habilidad", "")
	var all_parsed := UniversalCardParser.parse_abilities(habilidad_text, card_id)
	var abilities: Array = all_parsed.filter(func(a): return a.get("ability_type", "") == "ACTIVATED")

	if abilities.is_empty():
		return

	var panel = VBoxContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	panel.set_offset(SIDE_TOP, -160)
	panel.set_offset(SIDE_BOTTOM, -24)
	panel.add_theme_constant_override("separation", 6)
	panel.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.modulate.a = 0.0
	_main.inspection_layer.add_child(panel)
	_ability_buttons_panel = panel

	var title = Label.new()
	title.text = "⚡ Habilidades Activadas"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	title.add_theme_font_size_override("font_size", 13)
	panel.add_child(title)

	var context = {"controller_id": 0}
	for ability in abilities:
		var validation = _validate_ability(ability, source_card)
		var btn = _create_ability_button(ability, validation, source_card.card_data.get("nombre", ""))
		if validation.get("can", true):
			var captured           = ability.duplicate()
			var captured_card_data = source_card.card_data.duplicate()
			var card_for_glow      = source_card  # capturado antes del cierre
			# Un solo click: cerrar inspección → empujar a la Pila → Paso D automático
			btn.pressed.connect(func():
				close_card_inspection()
				await _activate_ability_via_pipeline(card_for_glow, captured_card_data, captured, context)
			)
		panel.add_child(btn)

	var tween = create_tween()
	tween.tween_property(panel, "modulate:a", 1.0, 0.15)


func _validate_ability(ability: Dictionary, source_card: Node) -> Dictionary:
	"""Valida si una habilidad activada puede ejecutarse ahora.
	Comprueba: prioridad, oro disponible, cartas en mano, carta girada, ActionPipeline."""
	var pm = get_node_or_null("/root/PriorityManager")
	if pm and pm.priority_window_active and not pm.can_act(0):
		return {"can": false, "reason": "Sin prioridad ahora"}

	var cost_type   = ability.get("cost_type",   UniversalCardParser.CostType.NONE)
	var cost_amount = ability.get("cost_amount", 0)

	match cost_type:
		UniversalCardParser.CostType.GOLD:
			if _main._gold_manager:
				var available = _main._gold_manager.get_oro_disponible()
				if not _main._gold_manager.puede_pagar(cost_amount):
					return {"can": false, "reason": "Oro insuficiente (%d/%d)" % [available, cost_amount]}

		UniversalCardParser.CostType.DISCARD:
			var hand = _main.player_hand
			var count = hand.cards.size() if hand and hand.get("cards") != null else hand.get_child_count() if hand else 0
			if count == 0:
				return {"can": false, "reason": "Mano vacía"}

		UniversalCardParser.CostType.TAP:
			if source_card.get("is_tapped") == true:
				return {"can": false, "reason": "Carta ya girada"}

		UniversalCardParser.CostType.ONCE_PER_TURN:
			var card_id: String = str(source_card.card_data.get("id", ""))
			var ability_idx: int = ability.get("ability_index", 0)
			var gm := get_node_or_null("/root/GameManager")
			var turn: int = gm.current_turn if gm else 0
			if UniversalCardParser.turn_registry.was_used(card_id, ability_idx, turn):
				return {"can": false, "reason": "Ya usada este turno"}

	# Flag once_per_turn desde parse_abilities() (puede venir sin cost_type ONCE_PER_TURN)
	if ability.get("once_per_turn", false) and cost_type != UniversalCardParser.CostType.ONCE_PER_TURN:
		var card_id: String = str(source_card.card_data.get("id", ""))
		var ability_idx: int = ability.get("ability_index", 0)
		var gm := get_node_or_null("/root/GameManager")
		var turn: int = gm.current_turn if gm else 0
		if UniversalCardParser.turn_registry.was_used(card_id, ability_idx, turn):
			return {"can": false, "reason": "Ya usada este turno"}

	# Verificación adicional con ActionPipeline
	var ap = get_node_or_null("/root/ActionPipeline")
	if ap and ap.has_method("can_activate_ability"):
		var context = {"controller_id": 0}
		var check = ap.can_activate_ability(source_card.card_data, ability, context)
		if not check.get("can", true):
			return {"can": false, "reason": check.get("reason", "No disponible")}

	return {"can": true, "reason": ""}


func _create_ability_button(ability: Dictionary, validation: Dictionary, card_name: String = "") -> Button:
	"""Crea un botón estilizado para una habilidad activada."""
	var cost_type   = ability.get("cost_type",   UniversalCardParser.CostType.NONE)
	var cost_amount = ability.get("cost_amount", 0)
	var effect_text = ability.get("effect_text", "")
	var is_optional = ability.get("is_optional", false)
	var can_use     = validation.get("can", true)
	var reason      = validation.get("reason", "")

	# Icono y etiqueta del costo según tipo
	var cost_label: String
	match cost_type:
		UniversalCardParser.CostType.GOLD:
			cost_label = "⭕ Paga %d Oro" % cost_amount
		UniversalCardParser.CostType.ONCE_PER_TURN:
			cost_label = "🔵 Una vez por turno"
		UniversalCardParser.CostType.DISCARD:
			cost_label = "🗑 Descarta una carta"
		UniversalCardParser.CostType.TAP:
			cost_label = "↩ Gira esta carta"
		_:
			cost_label = ability.get("cost_text", "?")

	# Texto del efecto: "Puedes..." → "Activar: [nombre derivado]" para dejar claro que es opcional
	var display_effect: String
	if is_optional:
		var derived = _derive_ability_name(effect_text, card_name)
		display_effect = "✨ Activar: %s" % derived
	else:
		display_effect = effect_text.substr(0, 72)

	var btn = Button.new()
	btn.text = "%s\n%s" % [cost_label, display_effect]
	btn.tooltip_text = ability.get("raw_text", "")
	btn.disabled = not can_use
	btn.custom_minimum_size = Vector2(340, 0)
	btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	if not can_use and not reason.is_empty():
		btn.tooltip_text = "%s\n⛔ %s" % [ability.get("raw_text", ""), reason]
		btn.text += "\n⛔ %s" % reason

	# Estilo visual: verde = disponible, gris-rojo = bloqueado
	var style = StyleBoxFlat.new()
	style.set_corner_radius_all(8)
	style.set_border_width_all(2)
	if can_use:
		style.bg_color     = Color(0.10, 0.18, 0.12, 0.95)
		style.border_color = Color(0.3, 0.85, 0.45, 0.9)
		btn.add_theme_color_override("font_color", Color(0.85, 1.0, 0.88))
		var style_h = style.duplicate()
		style_h.bg_color     = Color(0.18, 0.30, 0.20, 1.0)
		style_h.border_color = Color(0.5, 1.0, 0.6, 1.0)
		style_h.shadow_color = Color(0.3, 0.9, 0.45, 0.4)
		style_h.shadow_size  = 8
		btn.add_theme_stylebox_override("hover", style_h)
	else:
		style.bg_color     = Color(0.14, 0.10, 0.10, 0.90)
		style.border_color = Color(0.5, 0.3, 0.3, 0.6)
		btn.add_theme_color_override("font_color", Color(0.55, 0.45, 0.45))
	btn.add_theme_stylebox_override("normal", style)
	btn.add_theme_stylebox_override("disabled", style)

	return btn


func _derive_ability_name(effect_text: String, card_name: String) -> String:
	"""Deriva un nombre corto para una habilidad opcional (quita 'Puedes', capitaliza)."""
	var text = effect_text.strip_edges()
	# Quitar el prefijo "Puedes " o "Puedes:"
	for prefix in ["Puedes ", "puedes ", "Puedes: ", "puedes: "]:
		if text.begins_with(prefix):
			text = text.substr(prefix.length())
			break
	# Capitalizar primera letra
	if text.length() > 0:
		text = text[0].to_upper() + text.substr(1)
	# Truncar a 48 chars para no desbordarse
	if text.length() > 48:
		text = text.substr(0, 45) + "…"
	return text if not text.is_empty() else card_name


func _activate_ability_via_pipeline(card_node: Node, card_data: Dictionary, ability: Dictionary, context: Dictionary) -> void:
	"""Envía la habilidad a la Pila LIFO y arranca el flujo Paso D.
	ActionPipeline se encarga de: Paso B (pagar), Paso C (triggers), añadir a pila, Paso D (ventana respuesta)."""
	var ap = get_node_or_null("/root/ActionPipeline")
	if not ap:
		push_warning("[CardInspection] ActionPipeline no disponible")
		return
	print("[CardInspection] Activando habilidad '%s' vía Pila" % ability.get("cost_text", "?"))
	var result = await ap.activate_ability(card_data, ability, context)
	if not result.get("success", false):
		_main._update_debug("Habilidad no pudo activarse: %s" % result.get("reason", "?"))
		return
	# Brillo en la carta fuente mientras la habilidad está en la pila
	if is_instance_valid(card_node):
		_start_card_glow(card_node)


func _activate_ability_with_glow(card_node: Node, card_data: Dictionary, ability: Dictionary, context: Dictionary) -> void:
	# Alias mantenido por compatibilidad — delega al nuevo método
	await _activate_ability_via_pipeline(card_node, card_data, ability, context)


func _start_card_glow(card_node: Node) -> void:
	if not is_instance_valid(card_node):
		return
	if card_node in _glowing_cards:
		_glowing_cards[card_node].kill()
	var tween = create_tween().set_loops()
	tween.tween_property(card_node, "modulate", Color(1.5, 1.2, 0.2, 1.0), 0.45)
	tween.tween_property(card_node, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.45)
	_glowing_cards[card_node] = tween


func _stop_card_glow(card_node: Node) -> void:
	if card_node in _glowing_cards:
		_glowing_cards[card_node].kill()
		_glowing_cards.erase(card_node)
	if is_instance_valid(card_node):
		var tw = create_tween()
		tw.tween_property(card_node, "modulate", Color.WHITE, 0.25)


func _on_ability_glow_resolved(stack_obj: Dictionary, _result: Dictionary) -> void:
	if not stack_obj.get("card_data", {}).get("_is_activated_ability", false):
		return
	var source_id = stack_obj.get("card_data", {}).get("id", "")
	if source_id.is_empty():
		return
	for card_node in _glowing_cards.keys():
		if not is_instance_valid(card_node):
			_glowing_cards.erase(card_node)
			continue
		var cd = card_node.get("card_data") if card_node.get("card_data") != null else {}
		if cd.get("id", "") == source_id:
			_stop_card_glow(card_node)
			break


func _show_puedes_confirm(effect_text: String, on_confirm: Callable) -> void:
	var overlay = ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.55)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_main.inspection_layer.add_child(overlay)
	var panel = PanelContainer.new()
	panel.set_anchor(SIDE_LEFT,   0.5)
	panel.set_anchor(SIDE_TOP,    0.5)
	panel.set_anchor(SIDE_RIGHT,  0.5)
	panel.set_anchor(SIDE_BOTTOM, 0.5)
	panel.set_offset(SIDE_LEFT,  -185)
	panel.set_offset(SIDE_TOP,   -75)
	panel.set_offset(SIDE_RIGHT,  185)
	panel.set_offset(SIDE_BOTTOM, 75)
	overlay.add_child(panel)
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)
	var lbl = Label.new()
	lbl.text = "¿Deseas activar esta habilidad?"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 13)
	vbox.add_child(lbl)
	var effect_lbl = Label.new()
	effect_lbl.text = effect_text.substr(0, 90)
	effect_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	effect_lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	effect_lbl.add_theme_font_size_override("font_size", 11)
	effect_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(effect_lbl)
	var btn_row = HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 20)
	vbox.add_child(btn_row)
	var btn_yes = Button.new()
	btn_yes.text = "Sí, activar"
	btn_yes.pressed.connect(func():
		overlay.queue_free()
		on_confirm.call()
	)
	btn_row.add_child(btn_yes)
	var btn_no = Button.new()
	btn_no.text = "No"
	btn_no.pressed.connect(func(): overlay.queue_free())
	btn_row.add_child(btn_no)


func _on_step_d_waiting(stack_obj: Dictionary, _priority_player: int) -> void:
	if _step_d_overlay and is_instance_valid(_step_d_overlay):
		_step_d_overlay.queue_free()
	var ability_name = stack_obj.get("name", "Habilidad")
	var layer = CanvasLayer.new()
	layer.layer = 90
	_main.add_child(layer)
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
	get_tree().create_timer(2.0).timeout.connect(func():
		if _step_d_overlay and is_instance_valid(_step_d_overlay):
			_pass_both_priority(null)
	)
	panel.modulate.a = 0.0
	var tw = create_tween()
	tw.tween_property(panel, "modulate:a", 1.0, 0.2)


func _pass_both_priority(status_label) -> void:
	var pm = get_node_or_null("/root/PriorityManager")
	if not pm or not pm.priority_window_active:
		return
	pm.pass_priority()
	if status_label and is_instance_valid(status_label):
		status_label.text = "Resolviendo..."
	await get_tree().create_timer(0.35).timeout
	if pm.priority_window_active:
		pm.pass_priority()


func _on_step_d_completed(_stack_obj: Dictionary, _had_response: bool) -> void:
	if _step_d_overlay and is_instance_valid(_step_d_overlay):
		_step_d_overlay.queue_free()
		_step_d_overlay = null
