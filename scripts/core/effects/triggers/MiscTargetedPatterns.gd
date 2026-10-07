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
	tipo si se pasa type_filter) y las sube a la mano.
	2026-09-13, a pedido del usuario: click directo con ZoneViewerModule.
	open_cemetery_target_picker() en vez del modal de lista viejo — filtro
	restringido al lado propio (mismo criterio que la rama "Subir" de
	Campanita, ver arquitectura.md §10.18/§10.21). El único llamador
	(DSR_SearchGoldCombos.gd) ignora el valor de retorno, así que la vieja
	distinción 'false=canceló del todo / true=aceptó eligiendo 0' ya no
	tenía ningún efecto real — se simplifica a bool fijo true salvo el
	caso 'no hay Main'.
	Returns: false solo si no se pudo resolver Main (error), true en
	cualquier otro caso, incluso sin candidatos o sin elegir nada."""
	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._zone_viewer:
		return false
	if CardManager.get_cemetery(controller_id).is_empty():
		return true  # Nada que elegir, pero el 'puedes' no se declinó — no bloquea el resto del efecto

	var filter := func(c: Node) -> bool:
		if c.owner_id != controller_id:
			return false
		return type_filter.is_empty() or c.get("card_type") in type_filter
	var picked: Array = await main._zone_viewer.open_cemetery_target_picker(
		"Sube hasta %d carta(s) de tu Cementerio a tu mano" % max_amount, filter, max_amount, "cemetery", false, false, controller_id)

	var hand_container = main.player_hand if controller_id == 0 else main._opponent_fan
	for entry in picked:
		var idx: int = CardManager.get_cemetery(controller_id).find(entry.data)
		if idx < 0:
			continue
		CardManager.remove_from_cemetery(controller_id, idx)
		if hand_container:
			var node = main._create_card(entry.data, false)
			main._connect_card_signals(node)
			hand_container.add_card(node)
	return true


# =============================================================================
# PATRÓN "TU OPONENTE DESCARTA N... Y TÚ ROBAS [HASTA] M CARTAS" (p.ej. Miguel)
# =============================================================================
func _resolve_banish_from_both_cemeteries(max_amount: int, card: Node = null, controller_id: int = 0) -> void:
	"""Destierra hasta max_amount cartas combinadas entre ambos Cementerios
	(Espada de O'Higgins — VERIFICADO 2026-09-13: esta es la función que
	realmente se ejecuta para "Destierra hasta N cartas de los Cementerios y
	Roba M cartas", ver arquitectura.md §10.21 — try_execute_banish_up_to_n_
	cemeteries_then_draw_pattern(), convertida antes en §10.14 pensando que
	era esta, resultó ser código muerto por orden de chequeo).

	2026-09-13, a pedido del usuario: reemplaza las DOS selecciones
	SEPARADAS (primero rival, después propio, con modales de lista — así se
	evitaba la confusión de "¿de cuál Cementerio salió esta carta?") por
	ZoneViewerModule.open_cemetery_target_picker(), que ya muestra ambos
	Cementerios en columnas separadas y etiquetadas — resuelve esa misma
	confusión mostrando de dónde es cada carta, sin necesitar dos pasos.

	Reordenado (2026-09-09, Pila de Respuesta Universal): la selección se
	declara primero, sin tocar nada — solo con lo elegido se abre UNA
	ventana de respuesta, y solo si nadie anula/cancela se ejecutan los
	destierros."""
	if CardManager.get_cemetery(0).is_empty() and CardManager.get_cemetery(1).is_empty():
		return
	var main := _main.get_node_or_null("/root/Main") if _main else null
	if not main or not main._zone_viewer:
		return

	var no_filter := func(_c: Node) -> bool: return true
	var picked: Array = await main._zone_viewer.open_cemetery_target_picker(
		"Destierra hasta %d carta(s) de los Cementerios" % max_amount, no_filter, max_amount, "cemetery", false, false, controller_id)
	if picked.is_empty():
		return
	if await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Espada de O'Higgins", controller_id):
		return

	for entry in picked:
		var owner_of_picked: int = entry.owner_id
		var idx: int = CardManager.get_cemetery(owner_of_picked).find(entry.data)
		if idx >= 0:
			CardManager.remove_from_cemetery(owner_of_picked, idx)
			CardManager.add_to_exile(owner_of_picked, entry.data)


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
