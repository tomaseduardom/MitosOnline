extends Control
class_name DropZone
## DropZone - Zona de detección para soltar cartas
## Detecta cuando una carta es arrastrada y soltada sobre esta zona
## Incluye feedback visual rúnico para cartas legales

# =============================================================================
# SEÑALES
# =============================================================================
signal card_dropped_on_zone(card: Node, zone: DropZone)
signal card_entered_zone(card: Node)
signal card_exited_zone(card: Node)

# =============================================================================
# CONFIGURACIÓN
# =============================================================================
@export var zone_name: String = "Campo"
@export var zone_type: int = 0  # Constants.Zone value
@export var accepts_card_types: Array[int] = []  # Tipos de carta aceptados (vacío = todos)
@export var player_id: int = 0  # 0 = jugador, 1 = oponente
@export var highlight_on_hover: bool = true
@export var highlight_color: Color = Color(0.3, 0.6, 0.3, 0.3)
@export var highlight_color_invalid: Color = Color(0.6, 0.2, 0.2, 0.3)
@export var runic_glow_color: Color = Color(0.4, 0.7, 0.3, 0.6)

# =============================================================================
# ESTADO
# =============================================================================
var is_highlighted: bool = false
var card_hovering: Node = null
var _original_modulate: Color = Color.WHITE
var _is_card_legal: bool = false  # Si la carta puede ser jugada legalmente

# =============================================================================
# REFERENCIAS
# =============================================================================
var _highlight_rect: ColorRect = null
var _runic_border: Panel = null
var _glow_tween: Tween = null

# =============================================================================
# INICIALIZACIÓN
# =============================================================================
func _ready() -> void:
	# Agregar al grupo de zonas de drop
	add_to_group("drop_zones")

	# Guardar modulate original
	_original_modulate = modulate

	# Crear rect de highlight si no existe
	if highlight_on_hover:
		_create_highlight_rect()

	mouse_filter = Control.MOUSE_FILTER_PASS
	print("[DropZone] '%s' inicializada (player %d)" % [zone_name, player_id])


func _create_highlight_rect() -> void:
	"""Crea elementos visuales para el highlight y el brillo rúnico"""
	# Fondo de highlight
	_highlight_rect = ColorRect.new()
	_highlight_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_highlight_rect.color = highlight_color
	_highlight_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_highlight_rect.visible = false
	add_child(_highlight_rect)
	move_child(_highlight_rect, 0)

	# Borde rúnico brillante (solo para cartas legales)
	_runic_border = Panel.new()
	_runic_border.set_anchors_preset(Control.PRESET_FULL_RECT)
	_runic_border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_runic_border.visible = false

	var border_style = StyleBoxFlat.new()
	border_style.bg_color = Color(0, 0, 0, 0)  # Transparente
	border_style.border_color = runic_glow_color
	border_style.set_border_width_all(4)
	border_style.set_corner_radius_all(8)
	# Efecto de glow con expansión
	border_style.shadow_color = runic_glow_color
	border_style.shadow_size = 12
	_runic_border.add_theme_stylebox_override("panel", border_style)

	add_child(_runic_border)


# =============================================================================
# DETECCIÓN DE DROP
# =============================================================================
func on_card_dropped(card: Node) -> void:
	"""Llamado cuando una carta es soltada sobre esta zona"""
	_hide_highlight()

	# Verificar si la carta es válida para esta zona
	if not _can_accept_card(card):
		print("[DropZone] '%s' rechaza carta '%s'" % [zone_name, card.card_name if card.get("card_name") else "?"])
		card.return_to_hand()
		return

	print("[DropZone] '%s' acepta carta '%s'" % [zone_name, card.card_name if card.get("card_name") else "?"])

	# Emitir señal
	emit_signal("card_dropped_on_zone", card, self)

	# Buscar Main.gd
	var main = get_tree().current_scene

	# Manejar zona de oro especialmente
	if zone_type == Constants.Zone.RESERVA_ORO:
		if main and main.has_method("_place_card_as_gold"):
			main._place_card_as_gold(card)
		else:
			card.return_to_hand()
		return

	# Zona de batalla: declarar atacante (Furia en Vigilia, o normal en Ataque)
	if zone_type == Constants.Zone.LINEA_ATAQUE:
		var card_interaction = main.get("_card_interaction") if main else null
		if card_interaction and card_interaction.has_method("_declare_attacker"):
			card_interaction._declare_attacker(card)
		else:
			card.return_to_hand()
		return

	# Si la carta ya está en el campo (p.ej. un Aliado con Furia que se
	# arrastró un poco al hacerle clic y terminó soltándose sobre esta zona
	# de "jugar carta"), NO volver a jugarla — eso la pagaba de nuevo y la
	# dejaba en un estado visual roto (se "desaparecía"). Solo se juega
	# desde la mano; si ya está en juego, se la devuelve a su lugar.
	var card_zone = card.get("current_zone")
	if card_zone != null and card_zone in Constants.ZONES_IN_PLAY:
		card.return_to_hand()
		return

	# Para otras zonas, usar play_card
	var gold_mgr = main.get("_gold_manager") if main else null
	if gold_mgr and gold_mgr.has_method("play_card"):
		gold_mgr.play_card(card)
	else:
		# Fallback: intentar con método alternativo
		_play_card_fallback(card)


func _can_accept_card(card: Node) -> bool:
	"""Verifica si la carta puede ser jugada en esta zona"""
	# Verificar que sea del jugador correcto
	var card_owner = card.get("owner_id") if card.get("owner_id") != null else 0
	if card_owner != player_id:
		return false

	# Verificar estado (solo desde mano o arrastrando; LINEA_ATAQUE también acepta desde campo)
	var card_state = card.get("current_state")
	if card_state != null and card_state != card.CardState.IN_HAND and card_state != card.CardState.DRAGGING:
		if zone_type != Constants.Zone.LINEA_ATAQUE:
			return false

	# Verificar tipo de carta si hay restricción
	if not accepts_card_types.is_empty():
		var card_type = card.get("card_type") if card.get("card_type") != null else -1
		if card_type not in accepts_card_types:
			return false

	return true


func _play_card_fallback(card: Node) -> void:
	"""Intento alternativo de jugar la carta (2026-08-28, "módulos gordos"
	punto 1: antes intentaba GameManager.play_card(), que nunca existió —
	esta rama era inalcanzable siempre. GoldManager.play_card() es el
	camino real, ya intentado antes de llegar acá — ver el llamador)."""
	push_warning("[DropZone] No se encontró sistema para jugar carta")
	card.return_to_hand()


# =============================================================================
# HIGHLIGHT VISUAL CON BRILLO RÚNICO
# =============================================================================
func show_highlight_for_card(card: Node) -> void:
	"""Muestra el highlight con brillo rúnico si la carta es legal"""
	if not highlight_on_hover or is_highlighted:
		return

	is_highlighted = true
	_is_card_legal = _check_card_legality(card)

	# Color según legalidad
	var color = highlight_color if _is_card_legal else highlight_color_invalid

	if _highlight_rect:
		_highlight_rect.color = color
		_highlight_rect.visible = true
		_highlight_rect.modulate.a = 0

		var tween = create_tween()
		tween.tween_property(_highlight_rect, "modulate:a", 1.0, 0.15)

	# Brillo rúnico solo si es legal
	if _is_card_legal and _runic_border:
		_runic_border.visible = true
		_runic_border.modulate.a = 0
		_start_runic_glow_animation()


func show_highlight() -> void:
	"""Muestra el highlight básico (sin verificar carta)"""
	show_highlight_for_card(null)


func _start_runic_glow_animation() -> void:
	"""Anima el brillo rúnico pulsante"""
	if _glow_tween and _glow_tween.is_valid():
		_glow_tween.kill()

	_glow_tween = create_tween()
	_glow_tween.set_loops()  # Loop infinito

	# Pulso de brillo
	_glow_tween.tween_property(_runic_border, "modulate:a", 0.9, 0.4).set_ease(Tween.EASE_IN_OUT)
	_glow_tween.tween_property(_runic_border, "modulate:a", 0.4, 0.4).set_ease(Tween.EASE_IN_OUT)


func _hide_highlight() -> void:
	"""Oculta el highlight y el brillo rúnico"""
	if not is_highlighted:
		return

	is_highlighted = false
	_is_card_legal = false

	# Detener animación de glow
	if _glow_tween and _glow_tween.is_valid():
		_glow_tween.kill()
		_glow_tween = null

	if _highlight_rect:
		var tween = create_tween()
		tween.tween_property(_highlight_rect, "modulate:a", 0.0, 0.15)
		tween.tween_callback(func(): _highlight_rect.visible = false)

	if _runic_border:
		var tween2 = create_tween()
		tween2.tween_property(_runic_border, "modulate:a", 0.0, 0.15)
		tween2.tween_callback(func(): _runic_border.visible = false)


func _player_has_ally_in_play(p_id: int) -> bool:
	"""Verifica si el jugador p_id tiene al menos un Aliado libre para portar
	un Arma (sin una ya equipada) — mismo criterio que
	GoldManager._player_has_ally_in_play(), para que el highlight del
	arrastre no diga 'legal' cuando GoldManager lo va a rechazar."""
	var main = get_tree().current_scene
	if not main:
		return false
	if p_id == 0 and main.get("_gold_manager") and main._gold_manager.has_method("_player_has_ally_in_play"):
		return main._gold_manager._player_has_ally_in_play()
	var fields = [main.player_field, main.player_linea_ataque] if p_id == 0 else [main.opponent_field, main.opponent_linea_ataque]
	for field in fields:
		if not field:
			continue
		for card in field.get_children():
			if card.get("card_type") != Constants.CardType.ALIADO:
				continue
			var already_armed := false
			for child in card.get_children():
				if child is Card and child.get("card_type") == Constants.CardType.ARMA:
					already_armed = true
					break
			if not already_armed:
				return true
	return false


func _check_card_legality(card: Node) -> bool:
	"""Verifica si la carta puede ser jugada legalmente (tiene oro suficiente)"""
	if card == null:
		return true

	# ARMAS: necesitan un Aliado en juego para poder equiparse — sin
	# portador no tienen sentido (DAR). Se revisa acá, antes que nada más,
	# porque las Armas comparten drop zone (LINEA_DEFENSA) con Aliados,
	# Talismanes y Tótems.
	if card.get("card_type") == Constants.CardType.ARMA:
		if not _player_has_ally_in_play(player_id):
			return false

	# ZONA DE BATALLA: Aliados desde LINEA_DEFENSA, sin enfermedad de
	# invocación, durante el paso de Ataque (DAR 5.3.1) — ya sin atajo de
	# Vigilia (2026-08-28). El drop en sí (on_card_dropped → _can_accept_card)
	# ya lo aceptaba; esto solo hace que el brillo de "legal/ilegal" diga la
	# verdad. Ver hallazgo 5.
	if zone_type == Constants.Zone.LINEA_ATAQUE:
		var ct = card.get("card_type") if card.get("card_type") != null else -1
		if ct != Constants.CardType.ALIADO:
			return false
		var cz = card.get("current_zone") if card.get("current_zone") != null else -1
		if cz != Constants.Zone.LINEA_DEFENSA:
			return false
		# Ya no hay atajo Vigilia→Ataque (2026-08-28, a pedido del usuario):
		# declarar atacantes requiere el botón "Atacar" primero, incluso con
		# Furia — ese keyword solo evita la enfermedad de invocación.
		if GameManager.current_phase == Constants.Phase.ATAQUE:
			return TurnManager.can_attack(card).get("can_attack", false)
		return false

	# Verificar tipo aceptado
	if not _can_accept_card(card):
		return false

	# Verificar fase (con la misma excepción de Arma/Talismán en Guerra de
	# Talismanes que GoldManager.play_card() — si no, el borde se veía en
	# rojo/ilegal para una jugada que en realidad sí se iba a aceptar).
	if GameManager.current_phase != Constants.Phase.VIGILIA:
		var main = get_tree().current_scene
		var gold_mgr = main.get("_gold_manager") if main else null
		var ct = card.get("card_type") if card.get("card_type") != null else -1
		if not (gold_mgr and gold_mgr.has_method("has_phase_exception") and gold_mgr.has_phase_exception(ct)):
			return false

	# Oros siempre son legales (no tienen coste)
	var card_type = card.get("card_type") if card.get("card_type") != null else -1
	if card_type == Constants.CardType.ORO:
		return true

	# Obtener coste de la carta
	var card_cost = card.get("card_cost") if card.get("card_cost") != null else 0

	# Verificar oro disponible usando GameState
	return GameState.get_oro_reserva(player_id) >= card_cost


# =============================================================================
# DETECCIÓN DE HOVER (para highlight durante arrastre)
# =============================================================================
func _process(_delta: float) -> void:
	# Solo procesar si hay una carta siendo arrastrada
	var dragging_card = _get_dragging_card()

	if dragging_card:
		var mouse_pos = get_global_mouse_position()
		var rect = get_global_rect()

		if rect.has_point(mouse_pos):
			if card_hovering != dragging_card:
				card_hovering = dragging_card
				show_highlight_for_card(dragging_card)  # Verificar legalidad
				emit_signal("card_entered_zone", dragging_card)
		else:
			if card_hovering == dragging_card:
				card_hovering = null
				_hide_highlight()
				emit_signal("card_exited_zone", dragging_card)
	elif card_hovering:
		card_hovering = null
		_hide_highlight()


func _get_dragging_card() -> Node:
	"""Busca si hay alguna carta siendo arrastrada"""
	var cards = get_tree().get_nodes_in_group("cards")
	for card in cards:
		if card.get("is_dragging") == true:
			return card
	return null


# =============================================================================
# API
# =============================================================================
func set_accepts_types(types: Array) -> void:
	"""Configura qué tipos de carta acepta la zona"""
	accepts_card_types.clear()
	for t in types:
		accepts_card_types.append(t)


func set_player(pid: int) -> void:
	"""Configura el jugador dueño de la zona"""
	player_id = pid
