extends RefCounted
## SearchOwnZonePatterns — 2 de 7 mitades de LookAndPlayResolver.gd, dividido
## por tamaño el 2026-09-06 ("módulos gordos"). Cubre patrones de "busca en tu
## Castillo/Cementerio (o el de cualquiera, sin apuntar al oponente)" que
## relocalizan o convierten cartas sin banish/destierro dirigido: Kuchiku Kan,
## La Torre, Dulce Canasta, Azi Sruvara, duelo espacial, alto prime, Belta,
## Aurora de Chile, Danza de Dragones, asedio naval. Llamada solo desde
## LookAndPlayResolver.gd (facade) — ver ese archivo para la lista completa de
## las 7 mitades hermanas.

var _main: Node


func setup(main: Node) -> void:
	_main = main


func try_execute_search_ally_castillo_or_cementerio_then_buff_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando entra en juego, busca un Aliado en tu Castillo o Cementerio,
	ponlo en tu mano y tus Aliados ganan 1 de Fuerza permanentemente'
	(Kuchiku Kan, custom_mig_15, edición 'Ángeles y Demonios: Vigilantes -
	Mazo Guerreros'). 'Castillo o Cementerio' es 'y/o' entre zonas
	(project_y_o_means_choose_one_zone) — el jugador elige UNA, no se
	combinan en un solo pool de búsqueda. El buff de Fuerza es un pump
	puntual sobre los Aliados que controlas EN ESE MOMENTO (dice
	'permanentemente', no 'los Aliados que controles' en presente
	continuo — mismo criterio ya usado en Espada del Juicio): se registra
	un modificador PERMANENT por cada Aliado en juego al resolver, con
	source=el Aliado mismo (sobrevive aunque Kuchiku Kan salga de juego,
	ya que el buff no dice 'mientras esta carta esté en juego').
	Returns: true si el patrón aplicaba (se haya encontrado algo o no)."""
	var lower := ability_text.to_lower()
	if not ("castillo o cementerio" in lower and "gana" in lower and "permanentemente" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true

	var search_castillo := true
	if controller_id == 0:
		search_castillo = await SelectionManager.await_two_choice(
			main, "¿Dónde buscar un Aliado?", "Tu Castillo", "Tu Cementerio")
	var zone := Constants.Zone.CASTILLO if search_castillo else Constants.Zone.CEMENTERIO

	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return true
	await ActionModule.search(controller_id, zone, {"type": Constants.CardType.ALIADO}, 1, true, false, false, card, Constants.Zone.MANO)

	var strength_rx := RegEx.new()
	strength_rx.compile("aliados ganan (\\d+|una|dos|tres) de fuerza")
	var m := strength_rx.search(lower)
	var buff_amount: int = UniversalCardParser._parse_amount(m.get_string(1)) if m else 1

	var fields = [main.player_field, main.player_linea_ataque] if controller_id == 0 \
		else [main.opponent_field, main.opponent_linea_ataque]
	for field in fields:
		if not field:
			continue
		for ally in field.get_children():
			if not is_instance_valid(ally) or ally.get("card_type") != Constants.CardType.ALIADO:
				continue
			ContinuousEffectManager.register_modifier({
				"source": ally,
				"target": ally,
				"type": ContinuousEffectManager.ModifierType.STRENGTH,
				"stat": "strength",
				"value": buff_amount,
				"operation": "add",
				"duration": ContinuousEffectManager.ModifierDuration.PERMANENT,
				"layer": ContinuousEffectManager.ModifierLayer.LAYER_7B_CHAR_MODIFY,
				"description": "Buff de Kuchiku Kan",
			})

	return true




func try_execute_search_ally_cost_max_free_play_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando entra en juego, busca en tu Castillo o Cementerio un Aliado
	de coste N o menos y juégalo sin pagar su coste' (La Torre, custom_
	mig_19, edición Ángeles y Demonios: Vigilantes - Mazo Guerreros).
	'Castillo o Cementerio' es 'y/o' entre zonas (project_y_o_means_
	choose_one_zone) — el jugador elige UNA. Gratis de verdad (Gold
	Manager.play_card_for_free()), no un descuento — a diferencia de
	Kuchiku El Cazador (SearchAbilityHandler._activate_kuchiku_cazador_
	search_and_play_discount, ACTIVADA con descuento), esta es DISPARADA
	(ETB) y sin costo alguno."""
	var lower := ability_text.to_lower()
	var cost_rx := RegEx.new()
	cost_rx.compile("busca en tu castillo o cementerio un aliado de coste (\\d+) o menos y ju[eé]galo sin pagar su coste")
	var m := cost_rx.search(lower)
	if not m:
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager or not main.player_hand:
		return true

	var max_cost: int = int(m.get_string(1))
	var search_castillo: bool = await SelectionManager.await_two_choice(
		main, "¿Dónde buscar un Aliado?", "Tu Castillo", "Tu Cementerio")
	var zone := Constants.Zone.CASTILLO if search_castillo else Constants.Zone.CEMENTERIO

	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return true
	var hand_before: Array = main.player_hand.cards.duplicate()
	var result: Dictionary = await ActionModule.search(
		controller_id, zone, {"type": Constants.CardType.ALIADO, "cost_max": max_cost}, 1, true, false, false, card, Constants.Zone.MANO)
	if result.get("selected", []).is_empty():
		main._update_debug("No se encontró ningún Aliado ahí")
		return true

	var found_node: Node = null
	for c in main.player_hand.cards:
		if c not in hand_before:
			found_node = c
			break
	if not is_instance_valid(found_node):
		return true

	var found_data: Dictionary = found_node.card_data
	main.player_hand.remove_card(found_node, true)
	found_node.queue_free()
	await main._gold_manager.play_card_for_free(found_data)
	return true




func try_execute_search_oro_castillo_or_cementerio_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Busca un Oro en tu Castillo o Cementerio y ponlo en tu mano'
	(2026-09-04, p.ej. Dulce Canasta) — 'Castillo o Cementerio' es 'y/o'
	entre zonas ([[project_y_o_means_choose_one_zone]]), el jugador elige
	UNA."""
	var lower := ability_text.to_lower()
	if not ("busca un oro en tu castillo o cementerio" in lower and "ponlo en tu mano" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true
	var search_castillo: bool = await SelectionManager.await_two_choice(
		main, "¿Dónde buscar un Oro?", "Tu Castillo", "Tu Cementerio")
	var zone := Constants.Zone.CASTILLO if search_castillo else Constants.Zone.CEMENTERIO
	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return true
	await ActionModule.search(controller_id, zone, {"type": Constants.CardType.ORO}, 1, true, false, false, card, Constants.Zone.MANO)
	return true




func try_execute_raise_up_to_one_ally_or_gold_from_cemetery_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Prevén un efecto y puedes subir hasta un Aliado u Oro de tu
	Cementerio a tu mano' (Danza de Dragones, 2026-09-06) — solo la parte
	de subir a la mano; 'Prevén un efecto' y la condición de juego
	'controlas y/o muestras al menos cinco Oros' NO implementadas."""
	var lower := ability_text.to_lower()
	if not ("prevén un efecto y puedes subir hasta un aliado u oro de tu cementerio a tu mano" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true
	var own_cemetery: Array = CardManager.get_cemetery(controller_id)
	var eligible: Array = own_cemetery.filter(func(d): return d.get("tipo", -1) in [Constants.CardType.ALIADO, Constants.CardType.ORO])
	if eligible.is_empty():
		return true
	var picked_data: Dictionary = await SelectionManager.await_single_pick(
		eligible, "Sube hasta un Aliado u Oro de tu Cementerio a tu mano", true)
	if picked_data.is_empty():
		return true
	if await TriggerSystem.open_response_window(card, "Danza de Dragones", controller_id):
		return true
	var idx: int = own_cemetery.find(picked_data)
	if idx < 0:
		return true
	CardManager.remove_from_cemetery(controller_id, idx)
	var card_node = main._create_card(picked_data, false)
	main.player_hand.add_card(card_node)
	main._connect_card_signals(card_node)
	return true




func try_execute_raise_same_type_gold_and_search_banish_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Sube una o dos cartas de un mismo tipo que no sea Talismán de tu
	Cementerio a tu mano. Genera un Oro para jugar cartas del mismo tipo y
	busca en un Castillo una carta y Destiérrala' (asedio naval,
	2026-09-06) — el jugador elige el TIPO implícitamente al elegir las
	cartas (deben compartir tipo); el Oro restringido queda atado a ese
	mismo tipo."""
	var lower := ability_text.to_lower()
	if not ("sube una o dos cartas de un mismo tipo que no sea talismán de tu cementerio a tu mano" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true
	var own_cemetery: Array = CardManager.get_cemetery(controller_id)
	var eligible: Array = own_cemetery.filter(func(d): return d.get("tipo", -1) != Constants.CardType.TALISMAN)
	var chosen_type: int = -1
	var raised: Array = []
	if not eligible.is_empty():
		var result: Dictionary = await SelectionManager.await_multi_pick(
			eligible, "Sube hasta dos cartas del MISMO tipo de tu Cementerio a tu mano", 2, 0, true)
		for picked_data in result.get("picked", []):
			var picked_type: int = picked_data.get("tipo", -1)
			if chosen_type == -1:
				chosen_type = picked_type
			if picked_type != chosen_type:
				continue  # no comparte tipo con la primera elegida — se ignora
			raised.append(picked_data)

	# Ventana única para todo el efecto (subir a mano + Oro Virtual +
	# buscar/desterrar), sin importar si se encontró algo que subir o no.
	if await TriggerSystem.open_response_window(card, "asedio naval", controller_id):
		return true

	for picked_data in raised:
		var idx: int = own_cemetery.find(picked_data)
		if idx >= 0:
			CardManager.remove_from_cemetery(controller_id, idx)
			var card_node = main._create_card(picked_data, false)
			main.player_hand.add_card(card_node)
			main._connect_card_signals(card_node)

	if chosen_type != -1:
		var predicate := func(card_type: int, _card_race: String, _card_cost: int) -> bool:
			return card_type == chosen_type
		main._gold_manager.generar_oro_virtual_restringido(1, predicate, "cartas del mismo tipo")

	var zone_owner: int = await _main._targeted_executor._choose_search_zone_owner(controller_id, Constants.Zone.CASTILLO)
	await ActionModule.search(zone_owner, Constants.Zone.CASTILLO, {}, 1, true, false, false, card, Constants.Zone.DESTIERRO)
	return true




func try_execute_search_azi_ally_to_hand_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Cuando entra en juego, busca en tu Castillo un Aliado Azi, ponlo en
	tu mano y convierte una carta de coste 1 o menos en un Oro con la
	habilidad "Cancelar la habilidad de tus Aliados de coste 4 o más
	cuesta un Oro adicional" y muévelo a tu Oro Pagado' (Azi Sruvara,
	2026-09-06) — solo la búsqueda del Aliado Azi (por nombre, ya que "Azi"
	es un prefijo compartido entre estos Aliados, no una Raza impresa); la
	conversión a Oro con una habilidad de texto NUEVA generada dinámicamente
	NO implementada (no hay precedente de crear una habilidad funcional
	desde cero en runtime en este motor)."""
	var lower := ability_text.to_lower()
	if not ("busca en tu castillo un aliado azi, ponlo en tu mano" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var deck: Array = CardManager.get_deck(controller_id)
	var found_idx: int = -1
	for i in range(deck.size()):
		if deck[i].get("tipo", -1) == Constants.CardType.ALIADO and str(deck[i].get("nombre", "")).to_lower().begins_with("azi"):
			found_idx = i
			break
	if found_idx == -1:
		return true
	if await TriggerSystem.open_response_window(card, "Azi Sruvara", controller_id):
		return true
	var found_data: Dictionary = deck[found_idx]
	deck.remove_at(found_idx)
	CardManager.shuffle_deck(controller_id)

	var main := _main.get_node_or_null("/root/Main")
	if main and main.player_hand:
		var card_node = main._create_card(found_data, false)
		main.player_hand.add_card(card_node)
		main._connect_card_signals(card_node)
	if main and main.get("_zone_manager"):
		main._zone_manager._update_castillo_counts()
	return true




func try_execute_search_castillo_or_cemetery_to_pagado_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Busca una carta en un Castillo o Cementerio y ponlo en tu Oro
	Pagado como un Oro sin habilidad. Este efecto no puede ser prevenido'
	(duelo espacial, 2026-09-04) — 'un Castillo o Cementerio' es elegir
	UNA zona ([[project_y_o_means_choose_one_zone]]), luego de quién. 'No
	puede ser prevenido' ya se cumple: search() no pasa por el sistema de
	prevención (solo destroy()/banish() lo consultan)."""
	var lower := ability_text.to_lower()
	if not ("busca una carta en un castillo o cementerio y ponlo en tu oro pagado" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true
	var search_castillo: bool = await SelectionManager.await_two_choice(
		main, str(card.get("card_name")), "Buscar en un Castillo", "Buscar en un Cementerio")
	var zone := Constants.Zone.CASTILLO if search_castillo else Constants.Zone.CEMENTERIO
	var zone_owner: int = await _main._targeted_executor._choose_search_zone_owner(controller_id, zone)
	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return true

	# Destino SIEMPRE es "tu Oro Pagado" (el controlador de esta habilidad),
	# sin importar de qué Castillo/Cementerio salió la carta — a diferencia
	# de DESTIERRO/CEMENTERIO en ActionModule.search(), que van al dueño DE
	# LA ZONA buscada. Por eso se busca a la mano primero y se reubica acá.
	if not main.player_hand:
		return true
	var hand_before: Array = main.player_hand.cards.duplicate()
	var result: Dictionary = await ActionModule.search(zone_owner, zone, {}, 1, true, false, false, card, Constants.Zone.MANO)
	if result.get("selected", []).is_empty():
		return true
	var found_node: Node = null
	for c in main.player_hand.cards:
		if c not in hand_before:
			found_node = c
			break
	if not is_instance_valid(found_node):
		return true
	var found_data: Dictionary = found_node.card_data.duplicate()
	main.player_hand.remove_card(found_node, true)
	await main._gold_manager.put_gold_directly_in_pagado(controller_id, found_data)
	return true




func try_execute_search_each_castillo_two_to_cemetery_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando entra o sale del juego, busca en cada Castillo dos cartas y
	ponlas en el Cementerio' (alto prime, 2026-09-04) — 'cada Castillo' =
	AMBOS jugadores, cada uno a su propio Cementerio (destino CEMENTERIO
	nuevo en ActionModule.search())."""
	var lower := ability_text.to_lower()
	if not ("busca en cada castillo dos cartas y ponlas en el cementerio" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return true
	for player_id in [0, 1]:
		await ActionModule.search(player_id, Constants.Zone.CASTILLO, {}, 2, true, false, false, card, Constants.Zone.CEMENTERIO)
	return true




func try_execute_optional_search_totem_castillo_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Puedes buscar un Tótem en tu Castillo y ponerlo en tu mano'
	(2026-09-04, p.ej. Belta)."""
	var lower := ability_text.to_lower()
	if not ("puedes buscar un tótem en tu castillo y ponerlo en tu mano" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true
	var confirm: bool = await SelectionManager.await_two_choice(
		main, "Belta", "Buscar un Tótem en tu Castillo", "No hacer nada")
	if confirm and not await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		await ActionModule.search(controller_id, Constants.Zone.CASTILLO, {"type": Constants.CardType.TOTEM}, 1, true, false, false, card, Constants.Zone.MANO)
	return true




func try_execute_search_two_oros_split_destination_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando salga del juego, busca en tu Castillo dos Oros que no sean
	Aurora de Chile, pon uno en tu Oro Pagado y otro en tu mano' (Aurora de
	Chile, 2026-09-04) — dos búsquedas secuenciales de a 1 (cada una remueve
	la carta encontrada del Castillo, así que la segunda nunca puede repetir
	la misma copia), con name_not para excluirse a sí misma."""
	var lower := ability_text.to_lower()
	if not ("busca en tu castillo dos oros que no sean" in lower and "oro pagado" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var self_name: String = str(card.get("card_name")) if card.get("card_name") != null else "Aurora de Chile"
	var filter := {"type": Constants.CardType.ORO, "name_not": self_name}
	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return true
	await ActionModule.search(controller_id, Constants.Zone.CASTILLO, filter, 1, true, false, false, card, Constants.Zone.ORO_PAGADO)
	await ActionModule.search(controller_id, Constants.Zone.CASTILLO, filter, 1, true, false, false, card, Constants.Zone.MANO)
	return true


