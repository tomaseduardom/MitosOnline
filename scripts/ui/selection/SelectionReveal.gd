extends RefCounted
class_name SelectionReveal
## SelectionReveal — Revelar cartas al oponente (DAR Sección 8: modo SHOW,
## mano revelada, tope del mazo). Opera sobre SelectionCanvas via _main.
## Extraído de SelectionCanvas.gd (Fase 4 de reestructuración).

var _main: CanvasLayer


func setup(main: CanvasLayer) -> void:
	_main = main


func reveal_to_opponent(cards: Array) -> void:
	"""Revela las cartas seleccionadas al oponente
	Emite señales para que OpponentUI las muestre
	"""
	var opponent_id = 1 - _main.player_id
	var context = _get_reveal_context()

	print("[SelectionCanvas] Revelando %d cartas al oponente (contexto: %s)" % [cards.size(), context])

	# Preparar datos de revelación
	var reveal_data = {
		"player_id": _main.player_id,
		"opponent_id": opponent_id,
		"cards": cards,
		"context": context,
		"card_names": [],
		"timestamp": Time.get_ticks_msec()
	}

	for card in cards:
		reveal_data.card_names.append(card.card_name if card.get("card_name") else "Carta")

	# Emitir señal global para OpponentUI
	_main.emit_signal("cards_revealed_to_opponent", _main.player_id, cards, context)

	# Notificar a GameManager para logging/historial
	if GameManager and GameManager.has_method("log_card_reveal"):
		GameManager.log_card_reveal(reveal_data)

	# Revelar cada carta con pausa dramática
	for i in range(cards.size()):
		var card = cards[i]

		# Emitir señal individual
		_main.emit_signal("card_shown_to_opponent", _main.player_id, card)

		# Llamar al OpponentUI directamente si existe
		var opponent_ui = _get_opponent_ui()
		if opponent_ui and opponent_ui.has_method("show_revealed_card"):
			opponent_ui.show_revealed_card(card, context, i, cards.size())

		# Pausa dramática entre revelaciones
		await _main.get_tree().create_timer(0.4).timeout

	# Mantener cartas visibles un momento
	await _main.get_tree().create_timer(1.0).timeout

	_main.emit_signal("reveal_ended", _main.player_id)

	# Notificar fin de revelación al OpponentUI
	var opponent_ui = _get_opponent_ui()
	if opponent_ui and opponent_ui.has_method("hide_revealed_cards"):
		opponent_ui.hide_revealed_cards()


func _get_opponent_ui() -> Node:
	"""Obtiene referencia al OpponentUI"""
	# Intentar obtener desde el árbol de escena
	var ui = _main.get_tree().get_first_node_in_group("opponent_ui")
	if ui:
		return ui

	# Intentar ruta conocida
	return _main.get_node_or_null("/root/Main/OpponentUI")


func _get_reveal_context() -> String:
	"""Genera contexto para la revelación"""
	match _main.current_mode:
		SelectionCanvas.SelectionMode.SHOW:
			return "mostrar_efecto"
		SelectionCanvas.SelectionMode.SEARCH:
			return "buscar_resultado"
		SelectionCanvas.SelectionMode.DISCARD:
			return "descarte"
		_:
			return "revelado"


func show_cards_to_opponent(cards: Array, player: int, context: String = "mostrar") -> void:
	"""Función pública para mostrar cartas al oponente desde otros scripts
	Uso: await selection_canvas.show_cards_to_opponent(cards, 0, "efecto")
	"""
	_main.player_id = player
	await reveal_to_opponent(cards)


func reveal_hand_cards(cards: Array, player: int) -> void:
	"""Revela cartas de la mano al oponente (para efectos de "revelar mano")"""
	_main.player_id = player
	_main.is_public = true

	_main.emit_signal("cards_revealed_to_opponent", player, cards, "mano_revelada")

	var opponent_ui = _get_opponent_ui()
	if opponent_ui and opponent_ui.has_method("show_opponent_hand"):
		opponent_ui.show_opponent_hand(cards)

	# Las cartas de mano permanecen visibles hasta que el efecto termine
	await _main.get_tree().create_timer(2.0).timeout

	_main.emit_signal("reveal_ended", player)


func reveal_deck_top(cards: Array, player: int, keep_order: bool = true) -> void:
	"""Revela las cartas del tope del mazo al oponente
	Para efectos como "Revela las 3 primeras cartas de tu Castillo"
	"""
	_main.player_id = player
	_main.is_public = true

	var context = "tope_castillo"
	_main.emit_signal("cards_revealed_to_opponent", player, cards, context)

	var opponent_ui = _get_opponent_ui()
	if opponent_ui and opponent_ui.has_method("show_deck_reveal"):
		opponent_ui.show_deck_reveal(cards, keep_order)

	# Revelar cada carta
	for card in cards:
		_main.emit_signal("card_shown_to_opponent", player, card)
		await _main.get_tree().create_timer(0.3).timeout

	await _main.get_tree().create_timer(1.5).timeout
	_main.emit_signal("reveal_ended", player)


func await_show_to_opponent(cards: Array, reveal_context: String = "") -> void:
	"""Interfaz simplificada para mostrar cartas al oponente

	DAR Sección 8 - Mostrar: Las cartas son información pública.

	Args:
		cards: Cartas a mostrar
		reveal_context: Contexto de la revelación (para OpponentUI)
	"""
	if reveal_context.is_empty():
		reveal_context = "mostrar_efecto"

	# No necesita selección del usuario, solo mostrar
	await reveal_to_opponent(cards)
