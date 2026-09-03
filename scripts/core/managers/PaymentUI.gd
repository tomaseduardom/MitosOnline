extends RefCounted
class_name PaymentUI
## PaymentUI — Popup de selección de método de pago y su procesamiento
## (Normal/Exhumar/Sacrificio/Descarte/Vida/Alternativo/X). El estado
## compartido (_current_card/_current_player_id/_current_cost_info/
## _selected_method/_payment_popup/_state) se queda en PaymentManager —
## ExhumarSystem.gd y XCostSelector.gd lo leen/escriben directo sobre
## PaymentManager como blackboard compartido, así que moverlo hubiera
## significado reescribir ese acceso en los 3 archivos para nada (esta
## clase igual lo lee/escribe vía _main, sin ganar nada con relocarlo).
## Opera sobre PaymentManager via _main.
## Extraído de PaymentManager.gd (2026-08-28, "módulos gordos" — mismo corte
## que ya separó ExhumarSystem/CostModifiers/XCostSelector/PaymentValidation).

var _main: Node


func setup(main: Node) -> void:
	_main = main


# =============================================================================
# INTERFAZ DE PAGO - Menú emergente
# =============================================================================
func show_payment_options(card_data: Dictionary, player_id: int, options: Array = []) -> void:
	"""Muestra menú de opciones de pago para una carta

	Args:
		card_data: Datos de la carta a jugar
		options: Métodos de pago disponibles (auto-detecta si vacío)
	"""
	# ─────────────────────────────────────────────────────────────────────────
	# VALIDACIÓN ÚNICA: Bloquear si carta Única ya existe en juego/pila
	# ─────────────────────────────────────────────────────────────────────────
	if _main._validation._card_is_unique(card_data):
		var unique_check = _main._validation._validate_unique_card(card_data, player_id)
		if not unique_check.can_play:
			print("[PaymentManager] ⛔ BLOQUEADO: %s" % unique_check.reason)
			_main.emit_signal("payment_failed", card_data, unique_check.reason)
			_show_unique_blocked_message(card_data, unique_check.reason)
			return

	_main._current_card = card_data
	_main._current_player_id = player_id
	_main._state = PaymentManager.PaymentState.AWAITING_SELECTION

	# Auto-detectar opciones si no se proporcionan
	if options.is_empty():
		options = _detect_payment_options(card_data, player_id)

	_main._current_cost_info = {
		"base_cost": card_data.get("coste", 0),
		"options": options,
		"player_id": player_id,
		"is_unique": _main._validation._card_is_unique(card_data)
	}

	# Crear y mostrar popup
	_create_payment_popup(card_data, options)

	_main.emit_signal("payment_ui_opened", options)
	_main.emit_signal("payment_requested", card_data, _main._current_cost_info)


func _show_unique_blocked_message(card_data: Dictionary, reason: String) -> void:
	"""Muestra mensaje cuando una carta Única está bloqueada"""
	var card_name = card_data.get("nombre", card_data.get("name", "???"))

	# Crear popup de error
	var popup = AcceptDialog.new()
	popup.title = "⛔ Carta Única Bloqueada"
	popup.dialog_text = "%s\n\n%s" % [card_name, reason]
	popup.confirmed.connect(popup.queue_free)
	_main.add_child(popup)
	popup.popup_centered()

	print("[PaymentManager] Carta Única '%s' bloqueada: %s" % [card_name, reason])


func _detect_payment_options(card_data: Dictionary, player_id: int) -> Array:
	"""Detecta métodos de pago disponibles para una carta"""
	var options: Array = []
	var available_gold = _main._validation._get_player_available_gold(player_id)

	# ─────────────────────────────────────────────────────────────────────────
	# Detectar Coste Variable X
	# ─────────────────────────────────────────────────────────────────────────
	if _main._x_cost.has_variable_x_cost(card_data):
		var x_info = _main._x_cost.parse_x_cost(card_data)
		var can_afford_min = available_gold >= x_info.base_cost

		options.append({
			"method": PaymentManager.PaymentMethod.VARIABLE_X,
			"label": "Pagar %s (Variable)" % x_info.formula,
			"cost": x_info.base_cost,
			"available": can_afford_min,
			"has_x": true,
			"x_info": x_info,
			"description": "Coste variable - elige cuánto pagar"
		})

		# Si tiene coste X, esta es la única opción válida
		return options

	# ─────────────────────────────────────────────────────────────────────────
	# Coste Normal (no variable)
	# ─────────────────────────────────────────────────────────────────────────
	var base_cost = card_data.get("coste", 0)
	if base_cost is String:
		base_cost = 0  # Fallback si es string sin X

	# Opción 1: Pago normal
	if available_gold >= base_cost:
		options.append({
			"method": PaymentManager.PaymentMethod.NORMAL,
			"label": "Pagar %d Oro" % base_cost,
			"cost": base_cost,
			"available": true,
			"description": "Pago estándar con Oros de la Reserva"
		})
	else:
		options.append({
			"method": PaymentManager.PaymentMethod.NORMAL,
			"label": "Pagar %d Oro (Insuficiente)" % base_cost,
			"cost": base_cost,
			"available": false,
			"description": "Necesitas %d Oros más" % (base_cost - available_gold)
		})

	# Opción 2: Coste alternativo (si existe)
	var alt_cost = card_data.get("alternative_cost", card_data.get("coste_alternativo", {}))
	if not alt_cost.is_empty():
		var alt_option = _parse_alternative_cost(alt_cost, player_id)
		if alt_option:
			options.append(alt_option)

	# Opción 3: Costes especiales de keywords
	options.append_array(_get_keyword_payment_options(card_data, player_id))

	return options


func _parse_alternative_cost(alt_cost: Dictionary, player_id: int) -> Dictionary:
	"""Parsea un coste alternativo"""
	var cost_type = alt_cost.get("type", "gold")
	var amount = alt_cost.get("amount", alt_cost.get("value", 0))
	var available = false
	var label = ""
	var description = ""

	match cost_type:
		"gold", "oro":
			available = _main._validation._get_player_available_gold(player_id) >= amount
			label = "Coste Alternativo: %d Oro" % amount
			description = "Pagar coste reducido/aumentado"

		"sacrifice", "sacrificio":
			# TODO: Verificar si tiene cartas para sacrificar
			available = true
			label = "Sacrificar %d carta(s)" % amount
			description = "Sacrificar cartas en lugar de pagar Oro"

		"discard", "descartar":
			# TODO: Verificar cartas en mano
			available = true
			label = "Descartar %d carta(s)" % amount
			description = "Descartar cartas de la mano"

		"life", "vida":
			available = true
			label = "Pagar %d de daño al Castillo" % amount
			description = "Infligirte daño en lugar de pagar Oro"

	return {
		"method": PaymentManager.PaymentMethod.ALTERNATIVE,
		"label": label,
		"cost": amount,
		"cost_type": cost_type,
		"available": available,
		"description": description
	}


func _get_keyword_payment_options(card_data: Dictionary, player_id: int) -> Array:
	"""Obtiene opciones de pago basadas en keywords de la carta"""
	var options: Array = []
	var keywords = card_data.get("keywords", [])

	for kw in keywords:
		var kw_int = kw if kw is int else -1

		# Detectar keywords que afectan pago
		if kw_int == Constants.Keyword.EXHUMAR or (kw is String and kw.to_upper() == "EXHUMAR"):
			# Exhumar ya se maneja por separado desde cementerio
			pass

		# Agregar más keywords que afecten costes aquí

	return options


func _create_payment_popup(card_data: Dictionary, options: Array) -> void:
	"""Crea el popup de selección de pago"""
	# Limpiar popup anterior
	if _main._payment_popup and is_instance_valid(_main._payment_popup):
		_main._payment_popup.queue_free()

	_main._payment_popup = Window.new()
	_main._payment_popup.name = "PaymentPopup"
	_main._payment_popup.title = "Seleccionar Método de Pago"
	_main._payment_popup.size = Vector2i(350, 300)
	_main._payment_popup.unresizable = true
	_main._payment_popup.close_requested.connect(_on_payment_cancelled)
	_main.add_child(_main._payment_popup)

	# Contenido
	var panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_main._payment_popup.add_child(panel)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 15)
	margin.add_theme_constant_override("margin_right", 15)
	margin.add_theme_constant_override("margin_top", 15)
	margin.add_theme_constant_override("margin_bottom", 15)
	panel.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	# Título de la carta
	var title = Label.new()
	title.text = "💰 %s" % card_data.get("nombre", card_data.get("name", "???"))
	title.add_theme_font_size_override("font_size", 16)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# Separador
	vbox.add_child(HSeparator.new())

	# Info de coste base
	var cost_label = Label.new()
	cost_label.text = "Coste base: %d Oro" % card_data.get("coste", 0)
	cost_label.add_theme_font_size_override("font_size", 12)
	cost_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	vbox.add_child(cost_label)

	# Opciones de pago
	for i in range(options.size()):
		var option = options[i]
		var btn = Button.new()
		btn.text = option.label
		btn.disabled = not option.available
		btn.tooltip_text = option.description
		btn.pressed.connect(_on_payment_option_selected.bind(i))

		if option.available:
			btn.add_theme_color_override("font_color", Color.WHITE)
		else:
			btn.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))

		vbox.add_child(btn)

	# Separador
	vbox.add_child(HSeparator.new())

	# Botón cancelar
	var cancel_btn = Button.new()
	cancel_btn.text = "Cancelar"
	cancel_btn.pressed.connect(_on_payment_cancelled)
	vbox.add_child(cancel_btn)

	_main._payment_popup.popup_centered()


func _on_payment_option_selected(option_index: int) -> void:
	"""Callback cuando el jugador selecciona una opción de pago"""
	var options = _main._current_cost_info.get("options", [])

	if option_index < 0 or option_index >= options.size():
		return

	var selected = options[option_index]

	if not selected.available:
		print("[PaymentManager] Opción no disponible")
		return

	_main._selected_method = selected.method

	# Cerrar popup de pago
	if _main._payment_popup:
		_main._payment_popup.hide()

	# ─────────────────────────────────────────────────────────────────────────
	# Si es coste variable X, redirigir a selección de X
	# ─────────────────────────────────────────────────────────────────────────
	if selected.method == PaymentManager.PaymentMethod.VARIABLE_X:
		_main._x_cost.request_x_value_input(_main._current_card, _main._current_player_id)
		return

	_main._state = PaymentManager.PaymentState.AWAITING_PAYMENT

	# Procesar pago según método
	_process_payment(selected)


func _process_payment(payment_option: Dictionary) -> void:
	"""Procesa el pago según el método seleccionado"""
	_main._state = PaymentManager.PaymentState.PROCESSING

	var method = payment_option.method
	var cost = payment_option.cost
	var success = false

	match method:
		PaymentManager.PaymentMethod.NORMAL:
			success = _pay_with_gold(cost)

		PaymentManager.PaymentMethod.EXHUMAR:
			success = _main._exhumar.pay_for_exhumar(cost)

		PaymentManager.PaymentMethod.SACRIFICE:
			success = await _pay_with_sacrifice_async(payment_option)

		PaymentManager.PaymentMethod.DISCARD:
			success = await _pay_with_discard_async(payment_option)

		PaymentManager.PaymentMethod.LIFE:
			success = _pay_with_life(cost)

		PaymentManager.PaymentMethod.ALTERNATIVE:
			success = await _pay_alternative_async(payment_option)

		PaymentManager.PaymentMethod.VARIABLE_X:
			# El coste ya fue calculado en _on_x_value_confirmed
			var x_value = payment_option.get("x_value", 0)
			success = _pay_with_gold(cost)
			if success:
				print("[PaymentManager] 💰 Pago X=%d completado (Total: %d)" % [x_value, cost])

		PaymentManager.PaymentMethod.FREE:
			success = true

	if success:
		_main._state = PaymentManager.PaymentState.COMPLETED
		_main.emit_signal("payment_completed", _main._current_card, PaymentManager.PaymentMethod.keys()[method], cost)
		print("[PaymentManager] ✓ Pago completado: %s (%d)" % [PaymentManager.PaymentMethod.keys()[method], cost])
	else:
		_main._state = PaymentManager.PaymentState.IDLE
		_main.emit_signal("payment_failed", _main._current_card, "Pago fallido")
		print("[PaymentManager] ✗ Pago fallido")

	_close_payment_ui()


func _pay_with_gold(amount: int) -> bool:
	"""Paga con Oro de la Reserva"""
	if GameManager.has_method("spend_gold"):
		return GameManager.spend_gold(_main._current_player_id, amount)

	if GameManager.has_method("pay_gold"):
		return GameManager.pay_gold(_main._current_player_id, amount)

	# Fallback: modificar directamente
	var gold_reserve = GameManager.get("_gold_reserves")
	if gold_reserve and gold_reserve.has(_main._current_player_id):
		if gold_reserve[_main._current_player_id] >= amount:
			gold_reserve[_main._current_player_id] -= amount
			return true

	return false


func _pay_with_sacrifice_async(payment_option: Dictionary) -> bool:
	"""Pago mediante sacrificio de cartas (async para UI de selección)"""
	# TODO: Implementar selección de cartas a sacrificar
	print("[PaymentManager] Pago por sacrificio no implementado aún")
	await _main.get_tree().process_frame  # Placeholder para async
	return false


func _pay_with_discard_async(payment_option: Dictionary) -> bool:
	"""Pago mediante descarte de cartas (async para UI de selección)"""
	# TODO: Implementar selección de cartas a descartar
	print("[PaymentManager] Pago por descarte no implementado aún")
	await _main.get_tree().process_frame  # Placeholder para async
	return false


func _pay_with_life(amount: int) -> bool:
	"""Pago mediante daño al propio Castillo"""
	if GameManager.has_method("deal_damage_to_castle"):
		GameManager.deal_damage_to_castle(_main._current_player_id, amount)
		return true

	return false


func _pay_alternative_async(payment_option: Dictionary) -> bool:
	"""Procesa pago alternativo según tipo (async para métodos que requieren UI)"""
	var cost_type = payment_option.get("cost_type", "gold")

	match cost_type:
		"gold", "oro":
			return _pay_with_gold(payment_option.cost)
		"sacrifice", "sacrificio":
			return await _pay_with_sacrifice_async(payment_option)
		"discard", "descartar":
			return await _pay_with_discard_async(payment_option)
		"life", "vida":
			return _pay_with_life(payment_option.cost)

	return false


func _on_payment_cancelled() -> void:
	"""Callback cuando el jugador cancela el pago"""
	_main._state = PaymentManager.PaymentState.CANCELLED
	_main.emit_signal("payment_cancelled", _main._current_card, "Cancelado por jugador")
	_close_payment_ui()
	print("[PaymentManager] Pago cancelado")


func _close_payment_ui() -> void:
	"""Cierra la UI de pago"""
	if _main._payment_popup and is_instance_valid(_main._payment_popup):
		_main._payment_popup.queue_free()
		_main._payment_popup = null

	_main.emit_signal("payment_ui_closed")
