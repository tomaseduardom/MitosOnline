extends RefCounted
## GoldConversionPatterns — 5 de 7 mitades de LookAndPlayResolver.gd, dividido
## por tamaño el 2026-09-06 ("módulos gordos"). Cubre generación de Oro
## Virtual restringido y conversión carta-a-carta: Acabar la Esperanza,
## Garfio Pirata, manuel rodriguez (Oro/Barajar), leon indiferente,
## peripillan, almirante akari, Espíritu de la Máquina. Incluye una copia
## privada de _remove_data_from_array (idéntica a la de LookRevealPatterns.gd
## — duplicada a propósito porque try_execute_convert_then_reveal_until_
## same_type_pattern es la única función de este archivo que la necesita, y
## las 7 mitades no se referencian entre sí). Llamada solo desde
## LookAndPlayResolver.gd (facade) — ver ese archivo para la lista completa de
## las 7 mitades hermanas.

var _main: Node


func setup(main: Node) -> void:
	_main = main


func try_execute_convert_then_reveal_until_same_type_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Convierte un Oro o carta de coste N o menos en una carta del mismo
	tipo, sin habilidad. Muestra cartas del tope de tu Castillo hasta
	mostrar hasta dos cartas de ese tipo, ponlas en tu mano y Baraja el
	resto.' (Acabar la Esperanza, myl_id 20613, edición kvsm_titanes /
	reprint promo custom_mid_33, 'Ángeles y Demonios: Vigilantes - Mazo
	Dragón'). Las dos oraciones están LIGADAS: 'ese tipo' en la segunda es
	el tipo de la carta elegida como objetivo de Convertir en la primera
	(Oro, Aliado, Arma, Talismán o Tótem) — no se puede resolver aparte con
	el patrón genérico 'muestra/mira N...', necesita el objetivo ya
	elegido. 'Hasta mostrar hasta DOS' = revela de a una del tope hasta
	encontrar 2 de ese tipo o vaciar el Castillo (mismo molde que Alicia en
	Wonderland, try_execute_reveal_until_distinct_cost_allies_pattern más
	arriba), el resto se baraja de vuelta.

	'Si es Anulado, genera un Oro y Roba una carta' (primera cláusula real
	de esta carta, antes de 'Exhumar') queda SIN implementar a propósito:
	los Talismanes en este motor resuelven directo (TriggerSystem.
	resolve_talisman(), sin pasar por la Pila/una ventana de respuesta
	real), así que hoy no existe ningún punto en el que un Talismán pueda
	ser Anulado A MITAD de su propia resolución — esa cláusula no tiene
	todavía un evento real al que engancharse (mismo hueco que el sistema
	de Prevención real, diseño pendiente en docs/plans/2026-09-02-
	prevention-response-window-design.md)."""
	var lower := ability_text.to_lower()
	if not ("convierte un oro o carta de coste" in lower and "muestra cartas del tope de tu castillo" in lower
			and "hasta mostrar hasta dos cartas de ese tipo" in lower):
		return false

	var cost_rx := RegEx.new()
	cost_rx.compile("convierte un oro o carta de coste (\\d+) o menos")
	var cm := cost_rx.search(lower)
	var max_cost: int = int(cm.get_string(1)) if cm else 3

	var chosen_target: Node = await _main._targeted_executor._select_convert_target(max_cost, card)
	if not chosen_target or not is_instance_valid(chosen_target):
		return true

	var main := _main.get_node_or_null("/root/Main")
	if _main._targeted_executor._target_text_denies(chosen_target, ["no puede ser convertida", "no puede ser convertido"]):
		if main:
			main._update_debug("%s no puede ser convertida" % str(chosen_target.card_name))
		return true

	var target_type: int = chosen_target.card_type
	# Sin ventana genérica acá (2026-09-09): Acabar la Esperanza es un
	# Talismán — TriggerSystem.resolve_talisman() ya abrió UNA ventana para
	# toda la carta antes de siquiera llegar a este patrón.
	chosen_target.is_converted = true
	await KeywordManager.silence_card(chosen_target, card, "permanent")

	if controller_id != 0 or not main:
		return true  # el bot no usa esta habilidad todavía (revelado interactivo)

	var deck: Array = CardManager.get_deck(controller_id)
	var revealed: Array = []
	var matches: Array = []
	while not deck.is_empty() and matches.size() < 2:
		var top: Dictionary = deck.pop_front()
		revealed.append(top)
		if top.get("tipo", -1) == target_type:
			matches.append(top)

	if main.has_method("_create_card"):
		for picked_data in matches:
			var card_node = main._create_card(picked_data, false)
			main.player_hand.add_card(card_node)
			main._connect_card_signals(card_node)

	for picked_data in matches:
		_remove_data_from_array(revealed, picked_data)
	for c in revealed:
		deck.append(c)
	CardManager.shuffle_deck(controller_id)

	if main.get("_zone_manager"):
		main._zone_manager._update_castillo_counts()

	return true




func try_execute_wielder_attack_gold_or_draw_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando el portador ataque, si es de coste 1 o más, genera un Oro o
	Roba una carta' (Garfio Pirata, 2026-09-06, bug reportado por el
	usuario) — 'es' se refiere al PORTADOR (el Aliado que porta esta
	Arma), no a esta Arma misma. Elección A/B."""
	var lower := ability_text.to_lower()
	if not ("si es de coste 1 o más, genera un oro o roba una carta" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var wielder: Node = card.get("wielder") if card.get("wielder") != null else null
	if not is_instance_valid(wielder) or ContinuousEffectManager.get_modified_cost(wielder) < 1:
		return true  # condición de coste no cumplida (o no hay portador)

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true
	var choose_gold: bool = await SelectionManager.await_two_choice(
		main, str(card.get("card_name")), "Generar un Oro", "Robar una carta")
	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return true
	if choose_gold:
		main._gold_manager.generar_oros_virtuales(1)
	else:
		await ActionModule.draw(controller_id, 1, "on_attack_trigger", true)
	return true




func try_execute_gold_for_allies_or_shuffle_cost_max_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Al comienzo del turno, genera un Oro para Aliados o Baraja una
	carta de coste 3 o menos' (manuel rodriguez, 2026-09-04) — elección
	A/B. Dispara en CUALQUIER 'al comienzo del turno' (propio o rival, sin
	calificador 'tu' en el texto — TriggerSystem.resolve_agrupacion_
	triggers() solo llama esto para el jugador activo, así que en la
	práctica equivale a 'en tu turno')."""
	var lower := ability_text.to_lower()
	var cost_rx := RegEx.new()
	cost_rx.compile("genera un oro para aliados o baraja una carta de coste (\\d+) o menos")
	var m := cost_rx.search(lower)
	if not m:
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager or not main._card_interaction:
		return true
	var max_cost: int = int(m.get_string(1))
	var choose_gold: bool = await SelectionManager.await_two_choice(
		main, "manuel rodriguez", "Generar un Oro para Aliados", "Barajar una carta de coste %d o menos" % max_cost)

	if choose_gold:
		if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
			return true
		var predicate := func(card_type: int, _card_race: String, _card_cost: int) -> bool:
			return card_type == Constants.CardType.ALIADO
		main._gold_manager.generar_oro_virtual_restringido(1, predicate, "Aliados")
	else:
		var filter := func(c: Node) -> bool:
			if c.get("card_type") not in [Constants.CardType.ALIADO, Constants.CardType.ARMA, Constants.CardType.TOTEM]:
				return false
			var parent = c.get_parent()
			var valid_zones = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
				main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
			if parent not in valid_zones:
				return false
			return ContinuousEffectManager.get_modified_cost(c) <= max_cost
		var target: Node = await main._card_interaction.await_target("Elige una carta de coste %d o menos para barajar" % max_cost, filter)
		# Sin ventana genérica acá (2026-09-09): return_to_deck() ya consulta
		# Prevención adentro por su cuenta.
		if target and is_instance_valid(target):
			var target_owner: int = target.controller_id if target.get("controller_id") != null else 0
			if await ActionModule.return_to_deck(target, target_owner, true, card):
				CardManager.shuffle_deck(target_owner)
	return true




func try_execute_convert_two_top_castillo_to_allies_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Convierte dos cartas del tope de un Castillo en Aliados de Fuerza 2
	sin habilidad, ponlos bajo tu control y no pueden salir del juego ni
	cambiar de controlador hasta tu próximo turno' (leon indiferente,
	2026-09-04) — mismo mecanismo de conversión real que Sherlock Holmes/
	Biblioteca de Caballería (is_converted + silence_card + Fuerza fijada
	por modificador). 'No pueden cambiar de controlador' queda satisfecho
	por construcción: no hay ningún efecto de robo de control que pueda
	tocarlos en el medio de resolver este mismo Talismán."""
	var lower := ability_text.to_lower()
	if not ("convierte dos cartas del tope de un castillo en aliados de fuerza 2 sin habilidad" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true
	var zone_owner: int = await _main._targeted_executor._choose_search_zone_owner(controller_id, Constants.Zone.CASTILLO)
	# Sin ventana genérica acá (2026-09-09): silence_card() (dentro del loop
	# de abajo) ya consulta Prevención adentro por su cuenta.
	var deck: Array = CardManager.get_deck(zone_owner)
	var converted := 0
	while converted < 2 and not deck.is_empty():
		var top_data: Dictionary = deck.pop_front()
		var new_data: Dictionary = top_data.duplicate()
		new_data["tipo"] = Constants.CardType.ALIADO
		new_data["esta_oculta"] = false
		var token_node = main._create_card(new_data, false)
		token_node.owner_id = controller_id
		main._connect_card_signals(token_node)
		var target_field: HBoxContainer = main.player_field if controller_id == 0 else main.opponent_field
		target_field.add_child(token_node)
		token_node.can_interact = (controller_id == 0)
		token_node.set_zone(Constants.Zone.LINEA_DEFENSA)

		token_node.is_converted = true
		await KeywordManager.silence_card(token_node, card, "permanent")
		ContinuousEffectManager.register_modifier({
			"source": null,
			"target": token_node,
			"type": ContinuousEffectManager.ModifierType.STRENGTH,
			"stat": "strength",
			"value": 2,
			"operation": "set",
			"duration": ContinuousEffectManager.ModifierDuration.PERMANENT,
			"layer": ContinuousEffectManager.ModifierLayer.LAYER_7A_CHAR_SETTING,
			"description": "leon indiferente: Fuerza fijada en 2",
		})
		token_node.refresh_strength_badge()
		EffectController.add_single_card_leave_play_immunity(token_node, controller_id)

		if CardFactory and CardFactory.has_method("on_card_enters_play"):
			CardFactory.on_card_enters_play(token_node)
		if token_node.has_method("play_enter_animation"):
			token_node.play_enter_animation()
		converted += 1
	if converted > 0 and main.get("_zone_manager"):
		main._zone_manager._update_castillo_counts()
	return true




func try_execute_convert_gold_or_opponent_cost_max_draw_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando entra en juego, convierte un Oro o una carta oponente de
	coste 2 o menos en una carta del mismo tipo sin habilidad y Roba una
	carta' (peripillan, 2026-09-04) — 'un Oro' sin calificador (cualquier
	jugador), 'una carta' SÍ calificada 'oponente'."""
	var lower := ability_text.to_lower()
	var cost_rx := RegEx.new()
	cost_rx.compile("convierte un oro o una carta oponente de coste (\\d+) o menos en una carta del mismo tipo sin habilidad")
	var m := cost_rx.search(lower)
	if not m:
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		return true
	var max_cost: int = int(m.get_string(1))
	var opponent_id: int = 1 - controller_id
	var in_play_zones = [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO,
		Constants.Zone.RESERVA_ORO, Constants.Zone.ORO_PAGADO]
	var filter := func(c: Node) -> bool:
		if c.get("current_zone") not in in_play_zones:
			return false
		if c.get("card_type") == Constants.CardType.ORO:
			return true
		if c.get("owner_id") != opponent_id:
			return false
		return ContinuousEffectManager.get_modified_cost(c) <= max_cost
	var target: Node = await main._card_interaction.await_target("Elige un Oro (cualquiera) o una carta oponente de coste %d o menos para convertir" % max_cost, filter)
	# Ventana única para todo el efecto (convertir + robar) — silence_card()
	# abajo consulta Prevención por su cuenta para el objetivo puntual, pero
	# el Robo no está cubierto por nada más.
	if await TriggerSystem.open_response_window(card, str(card.get("card_name")), controller_id):
		return true
	if target and is_instance_valid(target):
		if TriggerSystem._targeted_executor._target_text_denies(target, ["no puede ser convertida", "no puede ser convertido"]):
			main._update_debug("%s no puede ser convertida" % str(target.get("card_name")))
		else:
			target.is_converted = true
			await KeywordManager.silence_card(target, card, "permanent")

	await ActionModule.draw(controller_id, 1, "etb_trigger", true)
	return true




func try_execute_gold_for_allies_or_weapons_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Al comienzo del Ataque, genera un Oro por el turno para jugar
	Aliados o Armas' (almirante akari, 2026-09-04)."""
	var lower := ability_text.to_lower()
	if not ("genera un oro por el turno para jugar aliados o armas" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía
	if await TriggerSystem.open_response_window(card, str(card.get("card_name")) if card else "almirante akari", controller_id):
		return true

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true
	var predicate := func(card_type: int, _card_race: String, _card_cost: int) -> bool:
		return card_type == Constants.CardType.ALIADO or card_type == Constants.CardType.ARMA
	main._gold_manager.generar_oro_virtual_restringido(1, predicate, "Aliados o Armas")
	return true




func try_execute_espiritu_maquina_conditional_gold_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Cuando entra en juego, si no es tu primer turno, genera un Oro
	para jugar Armas o Tótem de coste 2 o más' (Espíritu de la Máquina,
	2026-09-04). 'Tu primer turno' = GameManager.current_turn == 1 (el
	contador solo avanza cuando el turno vuelve al jugador 0, así que
	turno 1 cubre el primer turno de AMBOS jugadores por igual)."""
	var lower := ability_text.to_lower()
	if not ("si no es tu primer turno" in lower and "genera un oro para jugar armas o tótem" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía
	if GameManager.current_turn <= 1:
		return true
	if await TriggerSystem.open_response_window(card, str(card.get("card_name")) if card else "Espíritu de la Máquina", controller_id):
		return true

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true
	var predicate := func(card_type: int, _card_race: String, card_cost: int) -> bool:
		if card_type == Constants.CardType.ARMA or card_type == Constants.CardType.TOTEM:
			return card_cost >= 2
		return false
	main._gold_manager.generar_oro_virtual_restringido(1, predicate, "Armas o Tótem de coste 2 o más")
	return true




func _remove_data_from_array(array: Array, data: Dictionary) -> void:
	"""Quita de 'array' el diccionario de carta que coincide por id/uuid con 'data'."""
	if data.is_empty():
		return
	var search_id = data.get("id", "")
	var search_uuid = data.get("uuid", "")
	for i in range(array.size()):
		var item = array[i]
		if (search_id and item.get("id") == search_id) or (search_uuid and item.get("uuid") == search_uuid):
			array.remove_at(i)
			return



