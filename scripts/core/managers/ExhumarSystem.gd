extends RefCounted
class_name ExhumarSystem
## ExhumarSystem — Escaneo de cementerio, cache y UI para jugar cartas con
## Exhumar (DAR). Opera sobre PaymentManager via _main (validación de
## únicas, oro disponible, popup de pago). Extraído de PaymentManager.gd
## (Fase 4 de reestructuración).

var _main: Node

## Cartas con Exhumar detectadas por jugador: {player_id: [card_data, ...]}
var _exhumar_cache: Dictionary = {}
var _cache_dirty: bool = true

var _exhumar_popup: Window = null


func setup(main: Node) -> void:
	_main = main


# =============================================================================
# SCANNER DE CEMENTERIO - Detecta cartas con Exhumar
# =============================================================================
func scan_cemetery_for_exhumar(player_id: int) -> Array[Dictionary]:
	"""Escanea el cementerio del jugador buscando cartas con Exhumar

	Identifica cartas con el trait has_exhumar o keyword EXHUMAR
	y las marca como 'Jugables' si el jugador puede pagarlas.

	Args:
		player_id: ID del jugador cuyo cementerio escanear

	Returns:
		Array de cartas jugables via Exhumar con info de coste
	"""
	# Usar cache si está disponible
	if not _cache_dirty and _exhumar_cache.has(player_id):
		return _exhumar_cache[player_id]

	var playable_cards: Array[Dictionary] = []
	var cemetery = _main._validation._get_player_cemetery(player_id)

	for card in cemetery:
		if _card_has_exhumar(card):
			var card_info = _create_exhumar_card_info(card, player_id)
			if card_info.can_play:
				playable_cards.append(card_info)

	# Guardar en cache
	_exhumar_cache[player_id] = playable_cards
	_cache_dirty = false

	print("[PaymentManager] Cementerio J%d: %d cartas con Exhumar disponibles" % [
		player_id + 1, playable_cards.size()
	])

	return playable_cards


func get_all_exhumar_cards() -> Dictionary:
	"""Obtiene cartas con Exhumar de todos los jugadores

	Returns:
		{player_id: [card_info, ...]}
	"""
	var result: Dictionary = {}

	for player_id in range(2):  # 2 jugadores
		result[player_id] = scan_cemetery_for_exhumar(player_id)

	return result


func _card_has_exhumar(card_data: Dictionary) -> bool:
	"""Verifica si una carta tiene la habilidad Exhumar"""
	# Verificar trait directo
	var traits = card_data.get("traits", {})
	if traits.get("has_exhumar", false):
		return true

	# Verificar keywords
	var keywords = card_data.get("keywords", [])
	for kw in keywords:
		if kw is String and kw.to_upper() == "EXHUMAR":
			return true
		if kw is int and kw == Constants.Keyword.EXHUMAR:
			return true

	# Verificar texto de habilidad
	var ability = str(card_data.get("habilidad", card_data.get("ability", "")))
	if "exhumar" in ability.to_lower():
		return true

	return false


func _create_exhumar_card_info(card_data: Dictionary, player_id: int) -> Dictionary:
	"""Crea estructura de info para carta con Exhumar"""
	var base_cost = card_data.get("coste", 0)
	var exhumar_cost = _calculate_exhumar_cost(card_data, base_cost)
	var can_afford = _can_player_afford(player_id, exhumar_cost)

	# ─────────────────────────────────────────────────────────────────────────
	# VALIDACIÓN ÚNICA: Bloquear si ya existe copia en juego o pila
	# ─────────────────────────────────────────────────────────────────────────
	var is_unique = _main._validation._card_is_unique(card_data)
	var unique_blocked = false
	var block_reason = ""

	if is_unique:
		var unique_check = _main._validation._validate_unique_card(card_data, player_id)
		if not unique_check.can_play:
			unique_blocked = true
			block_reason = unique_check.reason

	# Determinar si se puede jugar
	var can_play = can_afford and not unique_blocked
	var playable_reason = ""

	if unique_blocked:
		playable_reason = block_reason
	elif not can_afford:
		playable_reason = "Oro insuficiente"
	else:
		playable_reason = "Exhumar disponible"

	return {
		"card_data": card_data,
		"card_id": card_data.get("id", card_data.get("card_id", -1)),
		"name": card_data.get("nombre", card_data.get("name", "???")),
		"base_cost": base_cost,
		"exhumar_cost": exhumar_cost,
		"can_play": can_play,
		"can_afford": can_afford,
		"is_unique": is_unique,
		"unique_blocked": unique_blocked,
		"player_id": player_id,
		"source_zone": Constants.Zone.CEMENTERIO,
		"payment_method": PaymentManager.PaymentMethod.EXHUMAR,
		"is_playable": can_play,
		"playable_reason": playable_reason
	}


func _calculate_exhumar_cost(card_data: Dictionary, base_cost: int) -> int:
	"""Calcula el coste de Exhumar (puede ser diferente al base)

	Por defecto Exhumar usa el mismo coste, pero algunas cartas
	pueden tener costes alternativos definidos.
	"""
	# Verificar si hay coste de Exhumar específico
	var exhumar_data = card_data.get("exhumar", {})
	if exhumar_data.has("cost"):
		return int(exhumar_data.cost)

	var traits = card_data.get("traits", {})
	if traits.has("exhumar_cost"):
		return int(traits.exhumar_cost)

	# Usar coste base por defecto
	return base_cost


func _can_player_afford(player_id: int, cost: int) -> bool:
	"""Verifica si el jugador tiene suficiente Oro"""
	if cost <= 0:
		return true

	var available_gold = _main._validation._get_player_available_gold(player_id)
	return available_gold >= cost


# =============================================================================
# MARCADO DE CARTAS JUGABLES
# =============================================================================
func mark_playable_exhumar_cards(player_id: int) -> void:
	"""Marca las cartas con Exhumar como jugables en la UI

	Llamar durante ventanas de prioridad legales.
	"""
	var exhumar_cards = scan_cemetery_for_exhumar(player_id)

	if exhumar_cards.is_empty():
		return

	_main.emit_signal("exhumar_cards_available", player_id, exhumar_cards)

	print("[PaymentManager] 💀 %d cartas con EXHUMAR disponibles para J%d" % [
		exhumar_cards.size(), player_id + 1
	])


func _on_priority_given(player_id: int) -> void:
	"""Callback cuando un jugador recibe prioridad"""
	# Verificar cartas con Exhumar disponibles
	mark_playable_exhumar_cards(player_id)


# =============================================================================
# PAGO ESPECÍFICO DE EXHUMAR
# =============================================================================
func pay_for_exhumar(cost: int) -> bool:
	"""Pago específico para Exhumar

	Marca la carta con flags necesarios para:
	- _exhumar_flag: Indica que fue jugada via Exhumar
	- _force_destination: DESTIERRO tras resolver/destruir
	"""
	var paid = _main._payment_ui._pay_with_gold(cost)

	if paid:
		# Asegurar que la carta tiene los flags de Exhumar
		_main._current_card["via_exhumar"] = true
		_main._current_card["_exhumar_flag"] = true
		_main._current_card["_force_destination"] = Constants.Zone.DESTIERRO

		print("[PaymentManager] 💀 Pago Exhumar completado - Destino forzado: DESTIERRO")

		# Notificar al ActionExecutor si existe
		if ActionExecutor.has_method("set_exhumar_flag"):
			ActionExecutor.set_exhumar_flag(true)

	return paid


# =============================================================================
# INTERFAZ DE EXHUMAR - Popup específico
# =============================================================================
func show_exhumar_options(player_id: int) -> void:
	"""Muestra popup con cartas disponibles para Exhumar"""
	var exhumar_cards = scan_cemetery_for_exhumar(player_id)

	if exhumar_cards.is_empty():
		print("[PaymentManager] No hay cartas con Exhumar disponibles")
		return

	_main._current_player_id = player_id
	_create_exhumar_popup(exhumar_cards)


func _create_exhumar_popup(cards: Array) -> void:
	"""Crea popup de selección de carta Exhumar"""
	if _exhumar_popup and is_instance_valid(_exhumar_popup):
		_exhumar_popup.queue_free()

	_exhumar_popup = Window.new()
	_exhumar_popup.name = "ExhumarPopup"
	_exhumar_popup.title = "💀 EXHUMAR - Jugar desde Cementerio"
	_exhumar_popup.size = Vector2i(400, 350)
	_exhumar_popup.close_requested.connect(_close_exhumar_popup)
	_main.add_child(_exhumar_popup)

	var panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_exhumar_popup.add_child(panel)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 15)
	margin.add_theme_constant_override("margin_right", 15)
	margin.add_theme_constant_override("margin_top", 15)
	margin.add_theme_constant_override("margin_bottom", 15)
	panel.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# Título
	var title = Label.new()
	title.text = "Cartas jugables desde el Cementerio:"
	title.add_theme_font_size_override("font_size", 14)
	vbox.add_child(title)

	# Scroll para cartas
	var scroll = ScrollContainer.new()
	scroll.custom_minimum_size.y = 200
	vbox.add_child(scroll)

	var cards_vbox = VBoxContainer.new()
	cards_vbox.add_theme_constant_override("separation", 5)
	scroll.add_child(cards_vbox)

	# Listar cartas
	for i in range(cards.size()):
		var card_info = cards[i]
		var card_btn = _create_exhumar_card_button(card_info, i)
		cards_vbox.add_child(card_btn)

	# Separador y botón cerrar
	vbox.add_child(HSeparator.new())

	var close_btn = Button.new()
	close_btn.text = "Cerrar"
	close_btn.pressed.connect(_close_exhumar_popup)
	vbox.add_child(close_btn)

	_exhumar_popup.popup_centered()


func _create_exhumar_card_button(card_info: Dictionary, index: int) -> Button:
	"""Crea botón para una carta con Exhumar"""
	var btn = Button.new()
	btn.custom_minimum_size.y = 50

	var name = card_info.get("name", "???")
	var cost = card_info.get("exhumar_cost", 0)
	var can_play = card_info.get("can_play", false)

	btn.text = "%s  |  Coste: %d 💰" % [name, cost]
	btn.disabled = not can_play

	if can_play:
		btn.tooltip_text = "Click para jugar via Exhumar"
		btn.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))
	else:
		btn.tooltip_text = card_info.get("playable_reason", "No se puede jugar")
		btn.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))

	btn.pressed.connect(_on_exhumar_card_selected.bind(index))

	return btn


func _on_exhumar_card_selected(index: int) -> void:
	"""Callback cuando se selecciona una carta para Exhumar"""
	var cards = _exhumar_cache.get(_main._current_player_id, [])

	if index < 0 or index >= cards.size():
		return

	var card_info = cards[index]

	if not card_info.can_play:
		return

	print("[PaymentManager] 💀 Carta seleccionada para Exhumar: %s" % card_info.name)

	_main.emit_signal("exhumar_card_selected", card_info.card_data, _main._current_player_id)

	# Mostrar confirmación de pago
	_close_exhumar_popup()
	_show_exhumar_confirmation(card_info)


func _show_exhumar_confirmation(card_info: Dictionary) -> void:
	"""Muestra confirmación final para jugar via Exhumar"""
	var card_data = card_info.card_data
	var cost = card_info.exhumar_cost

	# Crear opciones específicas de Exhumar
	var options = [{
		"method": PaymentManager.PaymentMethod.EXHUMAR,
		"label": "💀 Exhumar por %d Oro" % cost,
		"cost": cost,
		"available": card_info.can_afford,
		"description": "Jugar desde el Cementerio. Irá al DESTIERRO tras resolver."
	}]

	_main._current_card = card_data
	_main._current_card["via_exhumar"] = true

	_main._payment_ui.show_payment_options(card_data, _main._current_player_id, options)


func _close_exhumar_popup() -> void:
	"""Cierra el popup de Exhumar"""
	if _exhumar_popup and is_instance_valid(_exhumar_popup):
		_exhumar_popup.queue_free()
		_exhumar_popup = null


# =============================================================================
# CACHE MANAGEMENT
# =============================================================================
func invalidate_cache() -> void:
	"""Invalida el cache de Exhumar (llamar cuando cambia el cementerio)"""
	_cache_dirty = true
	_exhumar_cache.clear()


func _on_card_moved_to_zone(_card: Node, from_zone: int, to_zone: int, _player_id: int) -> void:
	"""Callback cuando una carta cambia de zona"""
	# Invalidar si involucra el cementerio
	if from_zone == Constants.Zone.CEMENTERIO or to_zone == Constants.Zone.CEMENTERIO:
		invalidate_cache()


func _on_zone_changed(zone: int, player_id: int) -> void:
	"""Callback cuando una zona cambia"""
	if zone == Constants.Zone.CEMENTERIO:
		invalidate_cache()


func has_exhumar_available(player_id: int) -> bool:
	"""Verifica si hay cartas con Exhumar disponibles"""
	var cards = scan_cemetery_for_exhumar(player_id)
	return not cards.is_empty()
