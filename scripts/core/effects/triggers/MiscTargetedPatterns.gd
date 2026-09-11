extends RefCounted
## MiscTargetedPatterns — Slice de TargetedEffectExecutor.gd dividido por
## tamaño (2026-09-06, "módulos gordos"). Agrupa los patrones sueltos que no
## encajan ni en el toolkit genérico de selección de un solo objetivo (que se
## quedó en TargetedEffectExecutor.gd) ni en el cluster compuesto de
## Arma/Buscar/Barajar (WeaponSearchShuffleExecutor.gd):
## _resolve_search_cemetery_to_hand, _resolve_banish_from_both_cemeteries y
## _refresh_rotation_for_name. Ninguna de las tres depende de otro método de
## TargetedEffectExecutor — cada una opera directo sobre CardManager/
## SelectionManager o recibe 'main' como parámetro, así que no hace falta el
## back-reference _main salvo para el primer caso. Opera sobre TriggerSystem
## via _main (mismo Node que TargetedEffectExecutor._main — ver ese archivo
## para el facade que reune este slice y el resto del split).

var _main: Node


func setup(main: Node) -> void:
	_main = main


func _resolve_search_cemetery_to_hand(controller_id: int, max_amount: int, type_filter: Array = []) -> bool:
	"""Elige hasta max_amount cartas del Cementerio propio (filtradas por
	tipo si se pasa type_filter) y las sube a la mano — mismo patrón de
	selección que el resto de esta familia de funciones (state Dictionary
	por el bug ya conocido de los lambdas de GDScript capturando por
	valor).
	Returns: false si el jugador Canceló la selección entera (declinó el
	'puedes'), true si la aceptó — incluso si terminó eligiendo 0 cartas."""
	var cemetery: Array = CardManager.get_cemetery(controller_id)
	if not type_filter.is_empty():
		cemetery = cemetery.filter(func(d): return d.get("tipo", -1) in type_filter)
	if cemetery.is_empty():
		return true  # Nada que elegir, pero el 'puedes' no se declinó — no bloquea el resto del efecto
	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return false

	var result: Dictionary = await SelectionManager.await_multi_pick(
		cemetery, "Sube hasta %d carta(s) de tu Cementerio a tu mano" % max_amount, max_amount)
	if result.cancelled:
		return false

	var full_cemetery: Array = CardManager.get_cemetery(controller_id)
	for picked_data in result.picked:
		var idx: int = full_cemetery.find(picked_data)
		if idx < 0:
			continue
		CardManager.remove_from_cemetery(controller_id, idx)
		full_cemetery = CardManager.get_cemetery(controller_id)
		if controller_id == 0 and main.player_hand:
			var node = main._create_card(picked_data, false)
			main._connect_card_signals(node)
			main.player_hand.add_card(node)
	return true


# =============================================================================
# PATRÓN "TU OPONENTE DESCARTA N... Y TÚ ROBAS [HASTA] M CARTAS" (p.ej. Miguel)
# =============================================================================
func _resolve_banish_from_both_cemeteries(max_amount: int, card: Node = null, controller_id: int = 0) -> void:
	"""Destierra hasta max_amount cartas combinadas entre ambos Cementerios
	(2026-08-30, Espada de O'Higgins). DOS selecciones SEPARADAS (primero
	el Cementerio RIVAL, después el propio — orden a pedido del usuario,
	2026-08-30) en vez de un solo pool mezclado, que confundía de cuál
	Cementerio salía cada carta al elegir. El tope de la segunda selección
	se descuenta de lo ya elegido en la primera, así el total combinado
	sigue respetando max_amount. Cada carta se destierra al Destierro de
	SU DUEÑO real.

	Reordenado (2026-09-09, Pila de Respuesta Universal): las 2 selecciones
	se declaran primero, sin tocar nada — recién con las 2 ya decididas se
	abre UNA ventana de respuesta, y solo si nadie anula/cancela se
	ejecutan los 2 destierros."""
	var own_cemetery: Array = CardManager.get_cemetery(0)
	var opp_cemetery: Array = CardManager.get_cemetery(1)
	if own_cemetery.is_empty() and opp_cemetery.is_empty():
		return

	var picked_opp: Array = []
	if not opp_cemetery.is_empty():
		var result_opp: Dictionary = await SelectionManager.await_multi_pick(
			opp_cemetery, "Destierra hasta %d carta(s) del Cementerio RIVAL" % max_amount, max_amount)
		if not result_opp.cancelled:
			picked_opp = result_opp.picked

	var remaining: int = max_amount - picked_opp.size()
	var picked_own: Array = []
	if remaining > 0 and not own_cemetery.is_empty():
		var result_own: Dictionary = await SelectionManager.await_multi_pick(
			own_cemetery, "Destierra hasta %d carta(s) de TU Cementerio" % remaining, remaining)
		if not result_own.cancelled:
			picked_own = result_own.picked

	if picked_opp.is_empty() and picked_own.is_empty():
		return
	if await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Espada de O'Higgins", controller_id):
		return

	for picked_data in picked_opp:
		var idx: int = CardManager.get_cemetery(1).find(picked_data)
		if idx >= 0:
			CardManager.remove_from_cemetery(1, idx)
			CardManager.add_to_exile(1, picked_data)

	for picked_data in picked_own:
		var idx: int = CardManager.get_cemetery(0).find(picked_data)
		if idx >= 0:
			CardManager.remove_from_cemetery(0, idx)
			CardManager.add_to_exile(0, picked_data)


# =============================================================================
# PATRÓN "NOMBRA UNA CARTA PARA QUE PIERDA(N) SU HABILIDAD EN TODAS LAS
# ZONAS" (p.ej. Alicia en Wonderland)
# =============================================================================
func _refresh_rotation_for_name(main: Node, card_name: String) -> void:
	"""Aplica el indicador visual (giro 180°, vía
	Card._refresh_disabled_rotation()) a toda copia YA EXISTENTE del nombre
	recién bloqueado — mano, campo y Oro (Reserva + Pagado) de ambos
	jugadores. Una copia que se cree DESPUÉS (p.ej. robada del mazo) ya
	queda cubierta por el hook en Card.load_from_data()."""
	var name_lower := card_name.to_lower()
	var all_cards: Array = []
	if main.player_hand and main.player_hand.get("cards") != null:
		all_cards.append_array(main.player_hand.cards)
	if main.get("_opponent_fan") and main._opponent_fan and main._opponent_fan.has_method("get_cards"):
		all_cards.append_array(main._opponent_fan.get_cards())
	for field_name in ["player_field", "player_linea_ataque", "player_linea_apoyo",
			"opponent_field", "opponent_linea_ataque", "opponent_linea_apoyo",
			"player_gold", "opponent_gold", "player_oro_pagado", "opponent_oro_pagado"]:
		var container = main.get(field_name)
		if container:
			all_cards.append_array(container.get_children())

	for c in all_cards:
		if is_instance_valid(c) and c.has_method("_refresh_disabled_rotation") \
				and str(c.get("card_name")).to_lower() == name_lower:
			c._refresh_disabled_rotation()
