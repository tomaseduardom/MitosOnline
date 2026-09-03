extends RefCounted
class_name TestUIBuilder
## TestUIBuilder — UI dinámica de selección de opciones y ventana de respuesta
## del escenario de pruebas. Opera sobre el estado de TestScene via _main.
## Extraído de TestScene.gd (Fase 4 de reestructuración).

var _main: Control


func setup(main: Control) -> void:
	_main = main


# =============================================================================
# UI DE ELECCIÓN
# =============================================================================
func show_choice_ui(title: String, options: Array, amount: int) -> void:
	"""Muestra la UI de selección de opciones"""
	if not _main.choice_panel or not _main.choice_title or not _main.choice_container:
		_main._log("[ERROR] UI de elección no disponible")
		return

	_main.choice_title.text = title
	_main._choice_amount = amount
	_main._selected_choices.clear()

	# Limpiar opciones anteriores
	for child in _main.choice_container.get_children():
		child.queue_free()

	# Crear botones de opción
	for opt in options:
		var btn = Button.new()
		btn.text = opt.get("text", "???")
		btn.custom_minimum_size = Vector2(300, 40)
		btn.set_meta("option_id", opt.get("id", ""))
		btn.pressed.connect(_on_choice_selected.bind(btn))
		_main.choice_container.add_child(btn)

	# Botón confirmar
	var confirm_btn = Button.new()
	confirm_btn.text = "Confirmar Selección"
	confirm_btn.custom_minimum_size = Vector2(300, 50)
	confirm_btn.pressed.connect(_on_choice_confirmed)
	confirm_btn.set_meta("is_confirm", true)
	_main.choice_container.add_child(confirm_btn)

	_main.choice_panel.visible = true

	# Esperar a que el usuario confirme
	await _wait_for_choice()


func _on_choice_selected(btn: Button) -> void:
	"""Maneja selección de opción"""
	var opt_id = btn.get_meta("option_id", "")

	if opt_id in _main._selected_choices:
		_main._selected_choices.erase(opt_id)
		btn.modulate = Color.WHITE
	else:
		if _main._selected_choices.size() < _main._choice_amount:
			_main._selected_choices.append(opt_id)
			btn.modulate = Color(0.5, 1.0, 0.5)
		else:
			_main._log("[INFO] Ya seleccionaste %d opción(es)" % _main._choice_amount)


func _on_choice_confirmed() -> void:
	"""Confirma la selección"""
	if _main._selected_choices.size() < _main._choice_amount:
		_main._log("[WARN] Debes seleccionar %d opción(es)" % _main._choice_amount)
		return

	if _main.choice_panel:
		_main.choice_panel.visible = false


func _wait_for_choice() -> void:
	"""Espera hasta que el panel de elección se cierre"""
	if not _main.choice_panel:
		return
	while _main.choice_panel.visible:
		await _main.get_tree().process_frame


# =============================================================================
# PASO D - VENTANA DE RESPUESTA
# =============================================================================
func open_response_window(card_name: String, pending_effects: Array) -> Dictionary:
	"""Abre la ventana de respuesta para el oponente (Paso D)

	Returns: {had_response, response_card, passed, is_annullment}
	"""
	_main._response_result = {
		"had_response": false,
		"response_card": null,
		"passed": false,
		"is_annullment": false
	}

	_main._waiting_for_response = true

	# Emitir señal para sistemas externos
	_main._get_action_executor_emit("waiting_for_opponent_response", null, {
		"card_name": card_name,
		"effects": pending_effects
	})

	# Mostrar UI de respuesta
	_show_response_ui(card_name, pending_effects)

	# Esperar decisión
	await _wait_for_response()

	return _main._response_result


func _show_response_ui(card_name: String, effects: Array) -> void:
	"""Muestra la UI para que el oponente responda o pase"""
	# Crear panel de respuesta si no existe
	if not _main.response_panel:
		_create_response_panel()

	if not _main.response_panel:
		# Fallback: usar timer automático
		_main._log("[INFO] Panel de respuesta no disponible - auto-pass en 3s")
		await _main.get_tree().create_timer(3.0).timeout
		_main._waiting_for_response = false
		return

	# Verificar cartas con Exhumar disponibles
	var executor = _main._get_action_executor()
	var exhumar_available = false
	var exhumar_text = ""

	if executor:
		var exhumable = executor.get_exhumable_cards(1, _main.opp_grave)
		if not exhumable.is_empty():
			exhumar_available = true
			exhumar_text = "\n\n💀 EXHUMAR disponible:\n"
			for card in exhumable:
				exhumar_text += "• %s (desde Cementerio)\n" % card.get("name", "???")

	# Verificar coste de carta en pipeline para mostrar si Hacer el Bien puede usarse
	var target_cost = 0
	var can_annul = false
	if executor and executor.is_pipeline_active():
		var target = executor.get_card_in_pipeline()
		target_cost = target.get("cost", target.get("coste", 0))
		can_annul = target_cost <= 3

	# Configurar texto
	var effects_text = ""
	for eff in effects:
		effects_text += "• %s\n" % eff.get("text", "???")

	var cost_info = "\n\nCoste de %s: %d %s" % [
		card_name,
		target_cost,
		"(puede anularse ≤3)" if can_annul else "(NO puede anularse >3)"
	]

	if _main.response_label:
		_main.response_label.text = "OPONENTE: %s jugó\n\n%s\n\nEfectos:\n%s%s%s" % [
			"Jugador 1",
			card_name,
			effects_text,
			cost_info,
			exhumar_text
		]

	_main.response_panel.visible = true


func _create_response_panel() -> void:
	"""Crea el panel de respuesta dinámicamente"""
	var ui = _main.get_node_or_null("UI")
	if not ui:
		return

	var response_panel = Panel.new()
	response_panel.name = "ResponsePanel"
	# Tamaño y posición centrada en el área de juego (no en el panel lateral)
	# Viewport: 1920x1080, Panel lateral derecho: 340px
	# Área de juego: 1580x1080, centro del área de juego: x=790
	var panel_width = 520
	var panel_height = 400
	response_panel.size = Vector2(panel_width, panel_height)
	response_panel.position = Vector2(
		(1580 - panel_width) / 2,  # Centrado en área de juego
		(1080 - panel_height) / 2  # Centrado verticalmente
	)

	# Estilo con fondo más opaco
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.15, 0.98)
	style.border_color = Color(1.0, 0.8, 0.2)
	style.set_border_width_all(4)
	style.set_corner_radius_all(12)
	style.shadow_color = Color(0, 0, 0, 0.5)
	style.shadow_size = 8
	response_panel.add_theme_stylebox_override("panel", style)

	# Contenedor vertical con scroll para contenido largo
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 12)
	vbox.set_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 20)

	# Título
	var title = Label.new()
	title.text = "⚔️ VENTANA DE RESPUESTA"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
	vbox.add_child(title)

	# ScrollContainer para contenido largo
	var scroll = ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(400, 160)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	# Label de info
	var response_label = Label.new()
	response_label.name = "ResponseLabel"
	response_label.text = "Esperando..."
	response_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	response_label.custom_minimum_size = Vector2(380, 0)
	response_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	response_label.add_theme_font_size_override("font_size", 13)

	scroll.add_child(response_label)
	vbox.add_child(scroll)

	# Botones
	var btn_container = HBoxContainer.new()
	btn_container.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_container.add_theme_constant_override("separation", 10)

	# Botón Hacer el Bien (para probar Sección 8)
	var annul_btn = Button.new()
	annul_btn.text = "🚫 Hacer el Bien"
	annul_btn.custom_minimum_size = Vector2(130, 45)
	annul_btn.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	annul_btn.tooltip_text = "Anula cartas de coste ≤3"
	annul_btn.pressed.connect(_on_opponent_annul)
	btn_container.add_child(annul_btn)

	var respond_btn = Button.new()
	respond_btn.text = "🎴 Responder"
	respond_btn.custom_minimum_size = Vector2(110, 45)
	respond_btn.pressed.connect(_on_opponent_respond)
	btn_container.add_child(respond_btn)

	var pass_btn = Button.new()
	pass_btn.text = "⏭️ Pasar"
	pass_btn.custom_minimum_size = Vector2(110, 45)
	pass_btn.pressed.connect(_on_opponent_pass)
	btn_container.add_child(pass_btn)

	vbox.add_child(btn_container)
	response_panel.add_child(vbox)
	ui.add_child(response_panel)

	_main.response_panel = response_panel
	_main.response_label = response_label


func _on_opponent_annul() -> void:
	"""El oponente juega Hacer el Bien (Sección 8)

	Puede jugarse desde la mano O desde el Cementerio via Exhumar.
	"""
	var executor = _main._get_action_executor()
	var hacer_bien_data: Dictionary = {}
	var played_from_cemetery: bool = false

	# Buscar Hacer el Bien en el cementerio del oponente (Exhumar)
	if executor:
		var exhumable = executor.get_exhumable_cards(1, _main.opp_grave)
		for card in exhumable:
			if card.get("name", "") == "Hacer el Bien":
				hacer_bien_data = card
				played_from_cemetery = true
				break

	# Si no está en cementerio, cargar del archivo
	if hacer_bien_data.is_empty():
		hacer_bien_data = TestCardLoader.load_card_json("res://hacer_el_bien.json")

	if hacer_bien_data.is_empty():
		# Fallback a carta genérica
		hacer_bien_data = {
			"name": "Hacer el Bien",
			"type": "Talisman",
			"cost": 1,
			"traits": {"has_exhumar": true},
			"hability_blocks": [{
				"type": "RESPONSE",
				"target_type": "CARD_IN_STACK",
				"conditions": [{"attribute": "cost", "operator": "<=", "value": 3}],
				"effect": {"action": "ANNUL", "destination": "CEMENTERIO"}
			}],
			"resolution_rules": {
				"on_resolve": "MOVE_TO_CEMENTERIO",
				"on_exhumar_resolve": "MOVE_TO_DESTIERRO"
			}
		}

	# Log de origen
	if played_from_cemetery:
		_main._log("[EXHUMAR] ¡Oponente juega HACER EL BIEN desde el Cementerio!")
		_main._log("[EXHUMAR] Destino final forzado: DESTIERRO")
	else:
		_main._log("[SECCIÓN 8] ¡Oponente juega HACER EL BIEN!")

	# Validar coste de la carta objetivo (Sección 6)
	if executor:
		var validation = executor.validate_annul_target(hacer_bien_data, executor.get_card_in_pipeline())

		_main._log("[SECCIÓN 6] Validación de coste:")
		for check in validation.conditions_checked:
			var status = "✓" if check.met else "✗"
			_main._log("  %s %s %s %s (actual: %s)" % [
				status,
				check.attribute,
				check.operator,
				str(check.required_value),
				str(check.actual_value)
			])

		if not validation.valid:
			_main._log("[SECCIÓN 6] ✗ No puede anular: %s" % validation.reason)
			return

		_main._log("[SECCIÓN 6] ✓ Validación exitosa")

		# Ejecutar anulación
		var annul_result = executor.annul_card_in_pipeline(hacer_bien_data)

		if annul_result.success:
			_main._log("[SECCIÓN 8] ✓ %s ANULADA por Hacer el Bien" % annul_result.annulled_card.get("name", "???"))
			_main._log("[SECCIÓN 8] Efectos cancelados: %d" % annul_result.cancelled_effects.size())
			_main._log("[SECCIÓN 8] Destino de carta anulada: %s" % annul_result.destination)

			_main._response_result.had_response = true
			_main._response_result.is_annullment = true
			_main._response_result.response_card = hacer_bien_data

			# El destino ya respeta BANISH_SELF de la carta anulada
			_main._response_result.annul_destination = annul_result.destination

			# Determinar destino de Hacer el Bien
			var hacer_bien_destination = "CEMENTERIO"
			if played_from_cemetery:
				hacer_bien_destination = "DESTIERRO"
				# Remover del cementerio
				_main.opp_grave.erase(hacer_bien_data)
				_main.opp_exile.append(hacer_bien_data)
				_main._log("[EXHUMAR] Hacer el Bien → DESTIERRO (jugada via Exhumar)")
			else:
				_main.opp_grave.append(hacer_bien_data)
				_main._log("[RESOLUCIÓN] Hacer el Bien → CEMENTERIO")

			# Marcar anulación
			_main._was_annulled = true
			_main._pending_effects.clear()

			_main._update_state_display()

	_main._waiting_for_response = false
	if _main.response_panel:
		_main.response_panel.visible = false


func _on_opponent_respond() -> void:
	"""El oponente elige responder (no anulación)"""
	_main._log("[RESPUESTA] Oponente quiere responder")
	# TODO: Abrir selección de carta de respuesta del oponente
	# Por ahora simulamos que no tiene cartas válidas
	_main._log("[RESPUESTA] (Sin cartas de respuesta válidas - simulado)")
	_on_opponent_pass()


func _on_opponent_pass() -> void:
	"""El oponente pasa"""
	_main._response_result.passed = true
	_main._response_result.had_response = false

	_main._waiting_for_response = false
	if _main.response_panel:
		_main.response_panel.visible = false

	_main._get_action_executor_pass()


func _wait_for_response() -> void:
	"""Espera hasta que el oponente decida"""
	while _main._waiting_for_response:
		await _main.get_tree().process_frame
