extends RefCounted
## PlayFromCemeteryPatterns — 6 de 7 mitades de LookAndPlayResolver.gd,
## dividido por tamaño el 2026-09-06 ("módulos gordos"). Cubre patrones de
## jugar un Aliado directo del Cementerio, gratis o con descuento: Titán
## Abismal, aku aku, sumi el terrible. Llamada solo desde
## LookAndPlayResolver.gd (facade) — ver ese archivo para la lista completa de
## las 7 mitades hermanas.

var _main: Node


func setup(main: Node) -> void:
	_main = main


func try_execute_titan_abismal_conditional_play_or_draw_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Cuando entra en juego, si sólo controlas Aliados Titán o Ignis,
	juega una carta Titán de coste 1 o menos de tu Cementerio sin pagar su
	coste o Roba una carta' (Titán Abismal, 2026-09-06) — solo esta
	cláusula condicional A/B; 'Cuando entra en juego o ataca, una carta en
	juego aumenta o reduce su coste en un Oro' NO implementada."""
	var lower := ability_text.to_lower()
	if not ("si sólo controlas aliados titán o ignis" in lower or "si solo controlas aliados titan o ignis" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true

	var only_titan_ignis := true
	for field in [main.player_field, main.player_linea_ataque]:
		if not field:
			continue
		for c in field.get_children():
			if is_instance_valid(c) and c.get("card_type") == Constants.CardType.ALIADO:
				var raza: String = str(c.get("card_raza")).to_lower()
				if not ("titan" in raza or "titán" in raza or "ignis" in raza):
					only_titan_ignis = false
	if not only_titan_ignis:
		return true

	var choose_play: bool = await SelectionManager.await_two_choice(
		main, "Titán Abismal", "Jugar un Aliado Titán de coste 1 o menos de tu Cementerio sin pagar su coste", "Robar una carta")
	if choose_play:
		var own_cemetery: Array = CardManager.get_cemetery(controller_id)
		var eligible: Array = own_cemetery.filter(func(d): return (d.get("tipo", -1) == Constants.CardType.ALIADO
			and int(d.get("coste", 99)) <= 1 and "tit" in str(d.get("raza", "")).to_lower()))
		if eligible.is_empty():
			if await TriggerSystem.open_response_window(card, "Titán Abismal", controller_id):
				return true
			await ActionModule.draw(controller_id, 1, "etb_trigger", true)
			return true
		var picked_data: Dictionary = await SelectionManager.await_single_pick(
			eligible, "Juega un Aliado Titán de coste 1 o menos de tu Cementerio sin pagar su coste", false)
		if picked_data.is_empty():
			return true
		if await TriggerSystem.open_response_window(card, "Titán Abismal", controller_id):
			return true
		var idx: int = own_cemetery.find(picked_data)
		if idx < 0:
			return true
		CardManager.remove_from_cemetery(controller_id, idx)
		await main._gold_manager.play_card_for_free(picked_data)
	else:
		if await TriggerSystem.open_response_window(card, "Titán Abismal", controller_id):
			return true
		await ActionModule.draw(controller_id, 1, "etb_trigger", true)
	return true




func try_execute_play_cemetery_ally_discounted_min1_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando entra en juego, puedes jugar un Aliado de tu Cementerio
	reduciendo su coste en un Oro, hasta un mínimo de 1' (aku aku,
	2026-09-04) — mismo mecanismo de búsqueda-a-mano + descuento que
	_activate_kuchiku_cazador_search_and_play_discount() (SearchAbility
	Handler.gd), pero DISPARADO (ETB) y desde el propio Cementerio sin
	elección de zona."""
	var lower := ability_text.to_lower()
	if not ("puedes jugar un aliado de tu cementerio reduciendo su coste en un oro, hasta un mínimo de 1" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager or not main.player_hand:
		return true
	var own_cemetery: Array = CardManager.get_cemetery(controller_id)
	if own_cemetery.filter(func(d): return d.get("tipo", -1) == Constants.CardType.ALIADO).is_empty():
		return true
	var confirm: bool = await SelectionManager.await_two_choice(
		main, "aku aku", "Jugar un Aliado de tu Cementerio (-1 Oro, mínimo 1)", "No hacer nada")
	if not confirm:
		return true
	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return true

	var hand_before: Array = main.player_hand.cards.duplicate()
	var result: Dictionary = await ActionModule.search(
		controller_id, Constants.Zone.CEMENTERIO, {"type": Constants.CardType.ALIADO}, 1, true, false, false, card, Constants.Zone.MANO)
	if result.get("selected", []).is_empty():
		return true

	var card_node: Node = null
	for c in main.player_hand.cards:
		if c not in hand_before:
			card_node = c
			break
	if not is_instance_valid(card_node):
		return true

	var applies_to_this_card := func(c: Node) -> bool:
		return c == card_node
	PaymentManager.agregar_modificador_coste(card_node, -1, applies_to_this_card, false)
	if card_node.has_method("refresh_cost_badge"):
		card_node.refresh_cost_badge()
	await main._gold_manager.play_card(card_node)
	return true




func try_execute_play_cemetery_ally_free_or_draw_three_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Cuando entra en juego, puedes jugar un Aliado de coste 2 o menos de
	tu Cementerio sin pagar su coste o Roba tres cartas' (sumi el
	terrible, 2026-09-04) — elección A/B."""
	var lower := ability_text.to_lower()
	if not ("puedes jugar un aliado de coste 2 o menos de tu cementerio sin pagar su coste o roba tres cartas" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true
	var choose_play: bool = await SelectionManager.await_two_choice(
		main, "sumi el terrible", "Jugar un Aliado de coste 2 o menos de tu Cementerio sin pagar su coste", "Robar tres cartas")

	if choose_play:
		var own_cemetery: Array = CardManager.get_cemetery(controller_id)
		var eligible: Array = own_cemetery.filter(func(d): return d.get("tipo", -1) == Constants.CardType.ALIADO and int(d.get("coste", 99)) <= 2)
		if eligible.is_empty():
			if await TriggerSystem.open_response_window(card, "sumi el terrible", controller_id):
				return true
			await ActionModule.draw(controller_id, 3, "etb_trigger", true)
			return true
		var picked_data: Dictionary = await SelectionManager.await_single_pick(
			eligible, "Juega un Aliado de coste 2 o menos de tu Cementerio sin pagar su coste", false)
		if picked_data.is_empty():
			return true
		if await TriggerSystem.open_response_window(card, "sumi el terrible", controller_id):
			return true
		var idx: int = own_cemetery.find(picked_data)
		if idx < 0:
			return true
		CardManager.remove_from_cemetery(controller_id, idx)
		await main._gold_manager.play_card_for_free(picked_data)
	else:
		if await TriggerSystem.open_response_window(card, "sumi el terrible", controller_id):
			return true
		await ActionModule.draw(controller_id, 3, "etb_trigger", true)
	return true




