extends RefCounted
## DSR_CemeteryBanishDraw — Slice de DrawShuffleResolver.gd: patrones que
## operan sobre uno o ambos Cementerios (Destierro, Barajado de vuelta al
## Castillo, o subida a la mano), a veces encadenados con un Robo de cartas
## (aku aku, Espada de O'Higgins, Campanita, Tamales, Quantum Megumi, Hanta
## el Samurai, Mariano Osorio). Uno de 4 hermanos separados de
## DrawShuffleResolver.gd (2026-09-06, "módulos gordos") — ver también
## DSR_ShuffleDrawCombos.gd, DSR_SearchGoldCombos.gd y
## DSR_DiscardChoicePatterns.gd. Opera sobre TriggerSystem via
## _executor._main (mismo Node que TargetedEffectExecutor._main — ver ese
## archivo). DrawShuffleResolver.gd queda como FACADE — cada función de este
## archivo es llamada por un reenvío de una sola línea desde ahí, con el
## mismo nombre y firma de siempre, así que TriggerResolution.gd (único
## llamador) no necesitó cambiar una sola línea por este split.

var _executor: TargetedEffectExecutor


func setup(executor: TargetedEffectExecutor) -> void:
	_executor = executor


func try_execute_banish_cemeteries_equal_to_own_strength_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando hagas daño de combate, Destierra tantas cartas de los
	Cementerios como Fuerza tenga un Aliado' (aku aku, 2026-09-04) — 'un
	Aliado' sin más calificador se interpreta como la propia carta (la que
	hizo el daño), autoreferencial como el resto de disparadores 'cuando
	hagas/haga daño' de una sola carta. También cubre 'puedes Desterrar
	hasta tantas cartas de los Cementerios como Fuerza tenga este Aliado'
	(kaitai, En tu Fase Final — autoreferencial explícito con 'este')."""
	var lower := ability_text.to_lower()
	if not ("destierra tantas cartas de los cementerios como fuerza tenga un aliado" in lower
			or "desterrar hasta tantas cartas de los cementerios como fuerza tenga este aliado" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var amount: int = ContinuousEffectManager.get_modified_strength(card)
	if amount <= 0:
		return true

	var candidates: Array = []
	for owner_id in [0, 1]:
		for d in CardManager.get_cemetery(owner_id):
			candidates.append({"data": d, "owner": owner_id})
	if candidates.is_empty():
		return true
	var display_data: Array = []
	for c in candidates:
		display_data.append(c.data)
	var result: Dictionary = await SelectionManager.await_multi_pick(
		display_data, "Destierra hasta %d carta(s) de los Cementerios" % amount, amount, 0, true)
	if not result.get("picked", []).is_empty() and await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return true
	for picked_data in result.get("picked", []):
		var owner_of_picked: int = 0
		for c in candidates:
			if c.data == picked_data:
				owner_of_picked = c.owner
				break
		var idx: int = CardManager.get_cemetery(owner_of_picked).find(picked_data)
		if idx < 0:
			continue
		CardManager.remove_from_cemetery(owner_of_picked, idx)
		CardManager.add_to_exile(owner_of_picked, picked_data)
	return true


func try_execute_banish_up_to_n_cemeteries_then_draw_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'En tu Fase Final, Destierra hasta tres cartas de los Cementerios y
	Roba dos cartas' (Espada de O'Higgins, 2026-09-04) — sin 'puedes'
	(a diferencia de try_execute_banish_up_to_n_cemeteries_pattern), pero
	'hasta N' ya implica 0..N opcional igual; agrega el Robo fijo al final."""
	var lower := ability_text.to_lower()
	var rx := RegEx.new()
	rx.compile("destierra hasta (\\w+) cartas? de los cementerios y roba (\\w+) cartas?")
	var m := rx.search(lower)
	if not m:
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var max_amount: int = UniversalCardParser._parse_amount(m.get_string(1))
	var draw_amount: int = UniversalCardParser._parse_amount(m.get_string(2))

	var candidates: Array = []
	for owner_id in [0, 1]:
		for d in CardManager.get_cemetery(owner_id):
			candidates.append({"data": d, "owner": owner_id})
	if not candidates.is_empty():
		var display_data: Array = []
		for c in candidates:
			display_data.append(c.data)
		var result: Dictionary = await SelectionManager.await_multi_pick(
			display_data, "Destierra hasta %d carta(s) de los Cementerios" % max_amount, max_amount, 0, true)
		if not result.get("picked", []).is_empty() and await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Espada de O'Higgins", controller_id):
			return true
		for picked_data in result.get("picked", []):
			var owner_of_picked: int = 0
			for c in candidates:
				if c.data == picked_data:
					owner_of_picked = c.owner
					break
			var idx: int = CardManager.get_cemetery(owner_of_picked).find(picked_data)
			if idx < 0:
				continue
			CardManager.remove_from_cemetery(owner_of_picked, idx)
			CardManager.add_to_exile(owner_of_picked, picked_data)

	if draw_amount > 0:
		await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)
	return true


func try_execute_shuffle_cemeteries_or_raise_ally_totem_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Puedes Barajar hasta cuatro cartas de los Cementerios o subir un
	Aliado o Tótem de tu Cementerio a tu mano' (Campanita, 2026-09-04) —
	elección A/B."""
	var lower := ability_text.to_lower()
	if not ("barajar hasta cuatro cartas de los cementerios o subir un aliado o tótem de tu cementerio" in lower
			or "barajar hasta cuatro cartas de los cementerios o subir un aliado o totem de tu cementerio" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main:
		return true
	var choose_shuffle: bool = await SelectionManager.await_two_choice(
		main, "Campanita", "Barajar hasta cuatro cartas de los Cementerios", "Subir un Aliado o Tótem de tu Cementerio a tu mano")

	if choose_shuffle:
		var candidates: Array = []
		for owner_id in [0, 1]:
			for d in CardManager.get_cemetery(owner_id):
				candidates.append({"data": d, "owner": owner_id})
		if candidates.is_empty():
			return true
		var display_data: Array = []
		for c in candidates:
			display_data.append(c.data)
		var result: Dictionary = await SelectionManager.await_multi_pick(
			display_data, "Baraja hasta cuatro carta(s) de los Cementerios", 4, 0, true)
		if result.picked.is_empty() or await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Campanita", controller_id):
			return true
		for picked_data in result.picked:
			var owner_of_picked: int = 0
			for c in candidates:
				if c.data == picked_data:
					owner_of_picked = c.owner
					break
			var idx: int = CardManager.get_cemetery(owner_of_picked).find(picked_data)
			if idx < 0:
				continue
			CardManager.remove_from_cemetery(owner_of_picked, idx)
			CardManager.get_deck(owner_of_picked).append(picked_data)
			CardManager.shuffle_deck(owner_of_picked)
	else:
		var own_cemetery: Array = CardManager.get_cemetery(controller_id)
		var eligible: Array = own_cemetery.filter(func(d): return d.get("tipo", -1) in [Constants.CardType.ALIADO, Constants.CardType.TOTEM])
		if eligible.is_empty():
			return true
		var picked_data: Dictionary = await SelectionManager.await_single_pick(
			eligible, "Sube un Aliado o Tótem de tu Cementerio a tu mano")
		if picked_data.is_empty():
			return true
		if await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Campanita", controller_id):
			return true
		var idx: int = own_cemetery.find(picked_data)
		if idx < 0:
			return true
		CardManager.remove_from_cemetery(controller_id, idx)
		var card_node = main._create_card(picked_data, false)
		main.player_hand.add_card(card_node)
		main._connect_card_signals(card_node)
	return true


func try_execute_shuffle_up_to_n_cemeteries_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Puedes Barajar hasta N cartas de los Cementerios' (2026-09-04, p.ej.
	Tamales: 'En tu Fase Final, puedes Barajar hasta tres cartas de los
	Cementerios') — sin Desterrar (a diferencia de Armería del Guerrero/
	Colmillo de Vampiro, que ofrecen Barajar Y/O Desterrar). 'Los
	Cementerios' = ambos jugadores ([[project_no_zone_means_in_play]]),
	'puedes' = opcional, cancelar el picker = 0 elegidas."""
	var lower := ability_text.to_lower()
	if not ("puedes barajar" in lower and "cartas de los cementerios" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var amount_rx := RegEx.new()
	amount_rx.compile("barajar hasta (\\w+) cartas? de los cementerios")
	var m := amount_rx.search(lower)
	var max_amount: int = UniversalCardParser._parse_amount(m.get_string(1)) if m else 1

	var candidates: Array = []
	for owner_id in [0, 1]:
		for d in CardManager.get_cemetery(owner_id):
			candidates.append({"data": d, "owner": owner_id})
	if candidates.is_empty():
		return true

	var display_data: Array = []
	for c in candidates:
		display_data.append(c.data)
	var result: Dictionary = await SelectionManager.await_multi_pick(
		display_data, "Baraja hasta %d carta(s) de los Cementerios" % max_amount, max_amount, 0, true)
	if result.picked.is_empty() or await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Tamales", controller_id):
		return true
	for picked_data in result.picked:
		var owner_of_picked: int = 0
		for c in candidates:
			if c.data == picked_data:
				owner_of_picked = c.owner
				break
		var idx: int = CardManager.get_cemetery(owner_of_picked).find(picked_data)
		if idx < 0:
			continue
		CardManager.remove_from_cemetery(owner_of_picked, idx)
		CardManager.get_deck(owner_of_picked).append(picked_data)
		CardManager.shuffle_deck(owner_of_picked)
	return true


func try_execute_banish_up_to_n_cemeteries_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Puedes Desterrar hasta N cartas de los Cementerios' (2026-09-04,
	p.ej. Quantum Megumi: 'En tu Fase Final, puedes Desterrar hasta dos
	cartas de los Cementerios') — versión Desterrar (no Barajar) de
	try_execute_shuffle_up_to_n_cemeteries_pattern. 'Los Cementerios' =
	ambos jugadores ([[project_no_zone_means_in_play]]), 'puedes' =
	opcional, cancelar el picker = 0 elegidas."""
	var lower := ability_text.to_lower()
	if not ("puedes desterrar" in lower and "cartas de los cementerios" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var amount_rx := RegEx.new()
	amount_rx.compile("desterrar hasta (\\w+) cartas? de los cementerios")
	var m := amount_rx.search(lower)
	var max_amount: int = UniversalCardParser._parse_amount(m.get_string(1)) if m else 1

	var candidates: Array = []
	for owner_id in [0, 1]:
		for d in CardManager.get_cemetery(owner_id):
			candidates.append({"data": d, "owner": owner_id})
	if candidates.is_empty():
		return true

	var display_data: Array = []
	for c in candidates:
		display_data.append(c.data)
	var result: Dictionary = await SelectionManager.await_multi_pick(
		display_data, "Destierra hasta %d carta(s) de los Cementerios" % max_amount, max_amount, 0, true)
	if result.get("picked", []).is_empty() or await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Quantum Megumi", controller_id):
		return true
	for picked_data in result.get("picked", []):
		var owner_of_picked: int = 0
		for c in candidates:
			if c.data == picked_data:
				owner_of_picked = c.owner
				break
		var idx: int = CardManager.get_cemetery(owner_of_picked).find(picked_data)
		if idx < 0:
			continue
		CardManager.remove_from_cemetery(owner_of_picked, idx)
		CardManager.add_to_exile(owner_of_picked, picked_data)
	return true


func try_execute_banish_from_cemeteries_and_draw_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""Detecta 'Destierra hasta N cartas de los Cementerios y Roba M
	cartas' (2026-08-30, Espada de O'Higgins — primera carta con trigger
	'en tu Fase Final' que realmente resuelve algo). 'los Cementerios' en
	plural sin posesivo = AMBOS Cementerios en un solo pool combinado
	(mismo criterio ya confirmado por el usuario para 'un Cementerio' de
	Miguel: sin posesivo = cualquiera de los dos). Sin 'Luego' entre las
	dos partes (misma oración unida por 'y', no oraciones separadas por
	punto), así que Robar sucede siempre, sin importar cuántas cartas se
	hayan elegido Desterrar (incluso cero).
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("de los cementerios" in lower and "destierra" in lower):
		return false

	var banish_rx := RegEx.new()
	banish_rx.compile("(?i)destierra\\s+hasta\\s+(\\w+)\\s+cartas?\\s+de\\s+los\\s+cementerios")
	var m_banish := banish_rx.search(ability_text)
	var banish_amount: int = UniversalCardParser._parse_amount(m_banish.get_string(1)) if m_banish else 0

	var draw_rx := RegEx.new()
	draw_rx.compile("(?i)roba\\s+(\\w+)\\s+cartas?")
	var m_draw := draw_rx.search(ability_text)
	var draw_amount: int = UniversalCardParser._parse_amount(m_draw.get_string(1)) if m_draw else 0

	if banish_amount > 0 and controller_id == 0:
		await _executor._resolve_banish_from_both_cemeteries(banish_amount, card, controller_id)

	if draw_amount > 0:
		await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)

	return true


func try_execute_weapon_count_banish_cemetery_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""Detecta 'En tu Fase Final, Destierra hasta tantas cartas de un
	Cementerio como Armas controles, más uno' (Hanta el Samurai,
	2026-09-02 — bug reportado por el usuario: sin patrón propio, esta
	habilidad caía al extractor genérico de UniversalCardParser, que no
	entiende una cantidad DINÁMICA 'tantas...como...' ni 'de un
	Cementerio' en esta forma exacta, y terminaba desterrando cartas EN
	JUEGO — se llevó puesta la Espada de O'Higgins equipada, con su bono
	de Fuerza y todo). 'Un Cementerio' sin posesivo = eliges CUÁL de los
	dos (mismo criterio ya confirmado con Miguel — ver
	[[project_y_o_means_choose_one_zone]]), NO es un pool combinado como
	'los Cementerios' de Espada de O'Higgins (plural). La cantidad es
	dinámica: Armas equipadas en cualquiera de los Aliados en juego del
	controlador, más uno.
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("tantas cartas de un cementerio" in lower and "armas controles" in lower):
		return false
	if controller_id != 0:
		return false  # el bot no usa esta habilidad todavía

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main:
		return true

	var weapon_count: int = 0
	for field in [main.player_field, main.player_linea_ataque]:
		if not field:
			continue
		for c in field.get_children():
			if not is_instance_valid(c):
				continue
			var weapons = c.get("equipped_weapons")
			if weapons is Array:
				weapon_count += weapons.size()
	var amount: int = weapon_count + 1

	var own_cemetery: Array = CardManager.get_cemetery(0)
	var opp_cemetery: Array = CardManager.get_cemetery(1)
	if own_cemetery.is_empty() and opp_cemetery.is_empty():
		return true

	var choose_own: bool = true
	if not own_cemetery.is_empty() and not opp_cemetery.is_empty():
		choose_own = await SelectionManager.await_two_choice(
			main, "Hanta el Samurai",
			"Desterrar de TU Cementerio", "Desterrar del Cementerio RIVAL")
	elif own_cemetery.is_empty():
		choose_own = false

	var target_owner: int = 0 if choose_own else 1
	var cemetery: Array = CardManager.get_cemetery(target_owner)
	if cemetery.is_empty():
		return true

	var result: Dictionary = await SelectionManager.await_multi_pick(
		cemetery, "Destierra hasta %d carta(s) de %s" % [
			amount, "tu Cementerio" if choose_own else "el Cementerio rival"
		], amount)
	if result.cancelled or result.picked.is_empty():
		return true
	if await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Hanta el Samurai", controller_id):
		return true
	for picked_data in result.picked:
		var idx: int = CardManager.get_cemetery(target_owner).find(picked_data)
		if idx >= 0:
			CardManager.remove_from_cemetery(target_owner, idx)
			CardManager.add_to_exile(target_owner, picked_data)

	return true


func try_execute_vigilia_or_final_banish_opponent_cemetery_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""Detecta 'En tu Vigilia o Fase Final, Destierra hasta tres cartas
	del Cementerio oponente' (Mariano Osorio, custom_mig_14, 2026-09-03 —
	carta custom, sin myl_id real, no está en la API externa, el cache
	local es la única fuente). Dispara en AMBOS momentos por turno
	(Vigilia Y Fase Final, no 'una vez por turno' combinado) — cada vez
	que TriggerSystem.resolve_vigilia_triggers()/resolve_turn_end_
	triggers() llega hasta acá, el mismo texto completo se revisa de
	nuevo, así que el patrón matchea las dos veces por diseño. 'Cementerio
	oponente' con posesivo explícito = siempre el del rival, sin elección
	de zona.
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("destierra hasta tres cartas del cementerio oponente" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var opponent_id: int = 1 - controller_id
	var cemetery: Array = CardManager.get_cemetery(opponent_id)
	if cemetery.is_empty():
		return true

	var result: Dictionary = await SelectionManager.await_multi_pick(
		cemetery, "Destierra hasta 3 carta(s) del Cementerio rival", 3)
	if result.picked.is_empty() or await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Mariano Osorio", controller_id):
		return true
	for picked_data in result.picked:
		var idx: int = CardManager.get_cemetery(opponent_id).find(picked_data)
		if idx >= 0:
			CardManager.remove_from_cemetery(opponent_id, idx)
			CardManager.add_to_exile(opponent_id, picked_data)
	return true
