extends RefCounted
## DrawShuffleResolver — Familia de patrones compuestos "roba N / baraja M /
## busca..." que combinan más de una acción en una sola oración (El Rey y el
## Verdugo, Aaru, Tempilcahue, Manuel Bulnes, Espada Vikinga, Legión Paladín,
## Espada de O'Higgins). Cada uno detecta su propio texto por regex y
## resuelve las acciones encadenadas que extract_action() no puede manejar
## solo (esa función reconoce UNA acción por texto, la primera que matchea).
## Opera sobre TriggerSystem via _executor._main (mismo Node que
## TargetedEffectExecutor._main — ver ese archivo).
## Extraído de TargetedEffectExecutor.gd (2026-08-30, "módulos gordos" —
## mismo corte que ya separó LookAndPlayResolver.gd).

var _executor: TargetedEffectExecutor


func setup(executor: TargetedEffectExecutor) -> void:
	_executor = executor


# =============================================================================
# PATRÓN "BARAJA TODAS LAS X DE TU DESTIERRO Y ROBA N CARTA(S)" (El Rey y
# el Verdugo)
# =============================================================================
func try_execute_shuffle_exile_and_draw_pattern(ability_text: String, controller_id: int) -> bool:
	"""Detecta 'Baraja todas las X de tu Destierro y Roba N carta(s)'
	(2026-08-29, p.ej. El Rey y el Verdugo: '...todas las Armas de tu
	Destierro...') — mueve del Destierro de vuelta al Castillo las cartas
	que cumplan el tipo, baraja, y roba. Sin 'puedes': mandatorio.
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("de tu destierro" in lower and "baraja" in lower):
		return false
	if controller_id != 0:
		return true

	var wanted_type: int = -1
	if "arma" in lower:
		wanted_type = Constants.CardType.ARMA
	elif "aliado" in lower:
		wanted_type = Constants.CardType.ALIADO
	elif "talismán" in lower or "talisman" in lower:
		wanted_type = Constants.CardType.TALISMAN
	elif "tótem" in lower or "totem" in lower:
		wanted_type = Constants.CardType.TOTEM
	elif "oro" in lower:
		wanted_type = Constants.CardType.ORO

	var exile: Array = CardManager.get_exile(controller_id)
	var deck: Array = CardManager.get_deck(controller_id)
	var moved := 0
	var i := exile.size() - 1
	while i >= 0:
		var card_data: Dictionary = exile[i]
		if wanted_type == -1 or card_data.get("tipo", -1) == wanted_type:
			exile.remove_at(i)
			deck.append(card_data)
			moved += 1
		i -= 1
	if moved > 0:
		CardManager.shuffle_deck(controller_id)
		var main := _executor._main.get_node_or_null("/root/Main")
		if main and main.get("_zone_manager"):
			main._zone_manager._update_castillo_counts()

	var draw_rx := RegEx.new()
	draw_rx.compile("(?i)roba[s]?\\s+(\\w+)\\s+cartas?")
	var m_draw := draw_rx.search(ability_text)
	var draw_amount: int = UniversalCardParser._parse_amount(m_draw.get_string(1)) if m_draw else 0
	if draw_amount > 0:
		await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)

	return true


func try_execute_shuffle_hand_and_draw_plus_two_pattern(ability_text: String, controller_id: int) -> bool:
	"""Detecta 'Baraja cualquier cantidad de cartas de tu mano en tu
	Castillo. Luego, pon la misma cantidad de cartas de la parte superior
	de tu Castillo en tu mano más dos cartas' (2026-08-30, Aaru — Talismán,
	se resuelve directo al jugarse vía TriggerSystem.resolve_talisman(), no
	dispara). Sin 'puedes': mandatorio, pero 'cualquier cantidad' incluye
	0 como resolución COMPLETA (no parcial) — el 'Luego' siempre corre,
	sin importar cuántas cartas se hayan barajado (incluso ninguna).
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("baraja cualquier cantidad de cartas de tu mano" in lower
			and "la misma cantidad de cartas de la parte superior" in lower):
		return false

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main:
		return true

	var shuffled_amount := 0
	if controller_id == 0 and main.player_hand and not main.player_hand.cards.is_empty():
		var hand_cards: Array = main.player_hand.cards.duplicate()
		var card_data_list: Array = []
		for c in hand_cards:
			card_data_list.append(c.card_data)
		var result: Dictionary = await SelectionManager.await_multi_pick(
			card_data_list, "Baraja cualquier cantidad de cartas de tu mano en tu Castillo (puedes no elegir ninguna)",
			hand_cards.size(), 0, false)
		for picked_data in result.picked:
			for c in hand_cards:
				if is_instance_valid(c) and c.card_data == picked_data:
					main.player_hand.remove_card(c, true)
					CardManager.get_deck(controller_id).append(picked_data)
					shuffled_amount += 1
					break
		if shuffled_amount > 0:
			CardManager.shuffle_deck(controller_id)

	# El bot todavía no usa la elección interactiva (2026-08-30) — equivale
	# a barajar 0, sigue siendo una resolución completa según el texto.
	await ActionModule.draw(controller_id, shuffled_amount + 2, "talisman_resolve", true)
	return true


func try_execute_tempilcahue_choice_pattern(full_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando lo juegues, Destiérralo. Elige un efecto:
	- Busca una carta en tu Castillo, ponla en tu mano y Roba una carta. No
	  puedes jugar más cartas este turno.
	- Paga dos Oros para Barajar cartas cuyos costes sumen hasta 4 y Robar
	  dos cartas.' (Tempilcahue, 2026-08-30) — Talismán, se resuelve directo
	  vía TriggerSystem.resolve_talisman(). El autodestierro ya lo maneja
	  GoldManager._play_talisman() genérico (self_exile detecta 'destierr'
	  en el texto completo de la carta) — acá solo se resuelve la elección
	  entre las dos ramas. 'Barajar cartas cuyos costes sumen...' sin 'de tu
	  mano' = cartas EN JUEGO de cualquier lado (ver
	  [[project_no_zone_means_in_play]]), no de la mano — a diferencia de
	  try_execute_shuffle_hand_and_draw_plus_two_pattern() (Aaru), cuyo texto
	  SÍ dice 'de tu mano' explícito."""
	var lower := full_text.to_lower()
	if not ("elige un efecto" in lower and "no puedes jugar más cartas" in lower and "paga dos oros" in lower):
		return false
	if controller_id != 0:
		return false  # el bot no usa esta habilidad todavía

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true

	var choose_search: bool = await SelectionManager.await_two_choice(
		main, "Tempilcahue",
		"Buscar una carta en tu Castillo y robar una (no juegas más cartas este turno)",
		"Pagar 2 Oros: barajar cartas en juego (coste ≤4) y robar 2")

	if choose_search:
		await ActionModule.search(controller_id, Constants.Zone.CASTILLO, {}, 1, true, false, false, card, Constants.Zone.MANO, false)
		await ActionModule.draw(controller_id, 1, "talisman_resolve", true)
		main._gold_manager.set_no_more_cards_this_turn(controller_id)
		return true

	if not main._gold_manager.puede_pagar(2):
		main._update_debug("No tienes 2 Oros disponibles para esta opción")
		return true
	await main._gold_manager.pagar_coste(2)

	var candidates: Array = []
	for field in [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
			main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]:
		if not field:
			continue
		for c in field.get_children():
			if is_instance_valid(c) and c != card:
				candidates.append(c)

	var chosen: Array = await _executor._select_cards_by_cost_budget(candidates, 4,
		"Baraja cualquier cantidad de cartas en juego cuyos costes sumen hasta 4 (puedes no elegir ninguna)")
	for c in chosen:
		if not is_instance_valid(c):
			continue
		var owner_id: int = c.owner_id if c.get("owner_id") != null else controller_id
		ActionModule.return_to_deck(c, owner_id, true)
		CardManager.shuffle_deck(owner_id)

	await ActionModule.draw(controller_id, 2, "talisman_resolve", true)
	return true


func try_execute_draw_and_shuffle_hand_pattern(ability_text: String, controller_id: int) -> bool:
	"""Detecta 'Roba N carta(s) y Baraja M carta(s) de tu mano en tu
	Castillo' (2026-08-30, p.ej. Manuel Bulnes: 'Cuando entra en juego,
	Roba una carta y Baraja una carta de tu mano en tu Castillo') — dos
	acciones encadenadas con 'y' que extract_action() no puede resolver
	juntas (solo reconoce UNA acción, la primera que matchea). El jugador
	elige QUÉ carta(s) barajar de la mano. Sin 'puedes': mandatorio en las
	dos partes, en el orden impreso (roba primero, después baraja).
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("roba" in lower and "baraja" in lower and "de tu mano en tu castillo" in lower):
		return false

	var draw_rx := RegEx.new()
	draw_rx.compile("(?i)roba[s]?\\s+(\\w+)\\s+cartas?")
	var m_draw := draw_rx.search(ability_text)
	var draw_amount: int = UniversalCardParser._parse_amount(m_draw.get_string(1)) if m_draw else 0

	var shuffle_rx := RegEx.new()
	shuffle_rx.compile("(?i)baraja[s]?\\s+(\\w+)\\s+cartas?\\s+de\\s+tu\\s+mano")
	var m_shuffle := shuffle_rx.search(ability_text)
	var shuffle_amount: int = UniversalCardParser._parse_amount(m_shuffle.get_string(1)) if m_shuffle else 0

	if draw_amount > 0:
		await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)

	if shuffle_amount > 0 and controller_id == 0:
		var main := _executor._main.get_node_or_null("/root/Main")
		if main and main.player_hand and not main.player_hand.cards.is_empty():
			var hand_cards: Array = main.player_hand.cards.duplicate()
			var card_data_list: Array = []
			for c in hand_cards:
				card_data_list.append(c.card_data)
			var pick_amount: int = mini(shuffle_amount, hand_cards.size())
			var result: Dictionary = await SelectionManager.await_multi_pick(
				card_data_list, "Baraja %d carta(s) de tu mano en tu Castillo" % shuffle_amount,
				pick_amount, pick_amount, false)
			var shuffled := 0
			for picked_data in result.picked:
				for c in hand_cards:
					if is_instance_valid(c) and c.card_data == picked_data:
						main.player_hand.remove_card(c, true)
						CardManager.get_deck(controller_id).append(picked_data)
						shuffled += 1
						break
			if shuffled > 0:
				CardManager.shuffle_deck(controller_id)

	return true


func try_execute_draw_and_shuffle_opponent_card_pattern(ability_text: String, controller_id: int) -> bool:
	"""Detecta 'Roba N carta(s) y Baraja una carta oponente de coste igual
	o menor a la cantidad de Aliados que controles' (2026-08-30, p.ej.
	Espada Vikinga). El texto NO dice 'de tu mano' ni 'de tu Castillo' —
	regla general confirmada por el usuario (2026-08-30): si un efecto de
	'barajar'/'destierra'/etc. no menciona una zona explícita, sucede sobre
	una carta EN JUEGO, no en la mano (mismo criterio ya corregido antes
	para 'Barajar una carta que no sea Oro' de Espada de O'Higgins). Como
	las cartas en juego son información PÚBLICA (a diferencia de una mano
	oculta), el jugador humano elige con clic en vez de al azar.
	A diferencia del resto de la familia 'y' de esta sesión (Manuel
	Bulnes, Aaru — ambas partes ocurren siempre), acá el orden LÓGICO real
	es al revés del orden impreso: el 'Barajar' es la parte que puede
	fallar (si el rival no controla ninguna carta de ese coste o menos), y
	si falla, el 'Robar' NO se ejecuta — regla confirmada explícitamente
	por el usuario (2026-08-30), mismo espíritu que 'Luego' (DAR: el
	siguiente efecto solo corre si el anterior resolvió al 100%) aunque el
	texto una las dos partes con 'y'.
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("baraja una carta oponente" in lower and "cantidad de aliados que controles" in lower):
		return false

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main:
		return true

	var draw_rx := RegEx.new()
	draw_rx.compile("(?i)roba[s]?\\s+(\\w+)\\s+cartas?")
	var m_draw := draw_rx.search(ability_text)
	var draw_amount: int = UniversalCardParser._parse_amount(m_draw.get_string(1)) if m_draw else 0

	var ally_fields: Array = [main.player_field, main.player_linea_ataque] if controller_id == 0 \
		else [main.opponent_field, main.opponent_linea_ataque]
	var ally_count := 0
	for field in ally_fields:
		if not field:
			continue
		for c in field.get_children():
			if is_instance_valid(c) and c.get("card_type") == Constants.CardType.ALIADO:
				ally_count += 1

	# Reserva de Oro / Oro Pagado quedan FUERA (2026-08-30, a pedido del
	# usuario): un Oro ahí "es Oro" nomás, no tiene un coste comparable
	# para este tipo de filtro — solo cuenta si por algún efecto raro
	# terminara en Línea de Defensa/Ataque/Apoyo, donde sí valdría 0.
	var opponent_id: int = 1 - controller_id
	var opp_fields: Array = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo] if opponent_id == 0 \
		else [main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]

	var candidates: Array = []
	for field in opp_fields:
		if not field:
			continue
		for c in field.get_children():
			if not is_instance_valid(c):
				continue
			if c.get("card_cost") != null and int(c.card_cost) <= ally_count:
				candidates.append(c)
			var weapons = c.get("equipped_weapons")
			if weapons is Array:
				for w in weapons:
					if is_instance_valid(w) and w.get("card_cost") != null and int(w.card_cost) <= ally_count:
						candidates.append(w)

	if candidates.is_empty():
		# 'Barajar' no encuentra objetivo válido — 'Robar' NO corre (regla
		# del usuario, 2026-08-30).
		return true

	var chosen: Node = null
	if controller_id == 0 and main._card_interaction:
		var filter := func(c: Node) -> bool:
			return c in candidates
		chosen = await main._card_interaction.await_target(
			"Elige una carta rival en juego (coste %d o menos) para barajar" % ally_count, filter)
	else:
		candidates.shuffle()
		chosen = candidates[0]

	if not chosen or not is_instance_valid(chosen):
		return true

	var true_owner: int = chosen.owner_id if chosen.get("owner_id") != null else opponent_id
	ActionModule.return_to_deck(chosen, true_owner, true)
	CardManager.shuffle_deck(true_owner)

	if draw_amount > 0:
		await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)

	return true


# =============================================================================
# PATRÓN "CUANDO JUEGUES ESTA CARTA, DESTIÉRRALO. DESCARTA HASTA DOS CARTAS Y
# JUEGA UN ALIADO DE TU MANO O CEMENTERIO REDUCIENDO SU COSTE... BARAJA HASTA
# UNA CARTA OPONENTE DE COSTE 2 O MENOS" (Golpe Solar)
# =============================================================================
func try_execute_golpe_solar_pattern(full_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando juegues esta carta, Destiérralo. Descarta hasta dos cartas y
	juega un Aliado de tu mano o Cementerio reduciendo su coste en tantos
	Oros como cartas hayas Descartado, hasta un mínimo de 0. Baraja hasta
	una carta oponente de coste 2 o menos.' (Golpe Solar, 2026-08-31,
	confirmado contra la API — Ángeles y Demonios: Vigilantes / su Mazo
	Dragón / Kaiju vs Mecha: Titanes, mismo texto en las tres). Talismán,
	se resuelve directo vía TriggerSystem.resolve_talisman(). El
	autodestierro ya lo maneja GoldManager._play_talisman() genérico
	(self_exile detecta 'destierr' en el texto completo de la carta) — acá
	solo se resuelve el efecto en sí, en el orden impreso.

	El descuento de coste reusa el mismo molde que
	TargetedEffectExecutor._execute_play_weapon_discount_draw() (Lobo
	Sagrado): calcular con un modificador temporal, sacarlo enseguida, y
	pagar el número fijo resultante a mano — pero para un Aliado (sin
	elegir portador) en vez de un Arma.

	'Baraja... una carta oponente...' sin 'de tu mano'/'de tu Castillo' =
	carta EN JUEGO (ver [[project_no_zone_means_in_play]]), mismo criterio
	y candidatos que Espada Vikinga
	(try_execute_draw_and_shuffle_opponent_card_pattern), pero con umbral
	de coste fijo (2) en vez de por cantidad de Aliados, y OPCIONAL ('hasta
	una', no 'una') — se puede declinar con ESC (await_target)."""
	var lower := full_text.to_lower()
	if not ("descarta hasta dos cartas" in lower and "reduciendo su coste" in lower
			and "baraja hasta una carta oponente" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true

	# --- "Descarta hasta dos cartas" (0-2, elección del jugador) ---
	var discount := 0
	var just_discarded_data: Array = []
	if main.player_hand and not main.player_hand.cards.is_empty():
		var hand_cards: Array = main.player_hand.cards.duplicate()
		var card_data_list: Array = []
		for c in hand_cards:
			card_data_list.append(c.card_data)
		var discard_result: Dictionary = await SelectionManager.await_multi_pick(
			card_data_list, "Descarta hasta dos cartas (reduce el coste del Aliado por cada una)", 2, 0, true)
		var to_discard: Array = []
		for picked_data in discard_result.picked:
			for c in hand_cards:
				if is_instance_valid(c) and c.card_data == picked_data:
					to_discard.append(c)
					just_discarded_data.append(picked_data)
					break
		if not to_discard.is_empty():
			await ActionModule.discard(controller_id, to_discard, "talisman_resolve")
			discount = to_discard.size()

	# --- "juega un Aliado de tu mano o Cementerio" con ese descuento ---
	# Un Aliado recién descartado por ESTE mismo efecto no puede ser el
	# elegido acá (2026-08-31, a pedido del usuario): _discard() lo manda
	# directo al Cementerio, así que sin esta exclusión aparecía como
	# candidata de 'Cementerio' en la misma resolución que lo descartó.
	var hand_allies: Array = []
	for c in main.player_hand.cards:
		if is_instance_valid(c) and c.get("card_type") == Constants.CardType.ALIADO:
			hand_allies.append(c)
	var cemetery_allies: Array = []
	for d in CardManager.get_cemetery(controller_id):
		if d.get("tipo") == Constants.CardType.ALIADO and not (d in just_discarded_data):
			cemetery_allies.append(d)

	if hand_allies.is_empty() and cemetery_allies.is_empty():
		main._update_debug("No tienes ningún Aliado en tu mano o Cementerio para jugar")
	else:
		var ally_data_list: Array = []
		for c in hand_allies:
			ally_data_list.append(c.card_data)
		for d in cemetery_allies:
			ally_data_list.append(d)

		var title: String = "Juega un Aliado con -%d Oro (mín 0)" % discount
		var picked_ally: Dictionary = await SelectionManager.await_single_pick(ally_data_list, title, true, 0)
		if not picked_ally.is_empty():
			var ally_node: Node = null
			var from_hand := false
			for c in hand_allies:
				if is_instance_valid(c) and c.card_data == picked_ally:
					ally_node = c
					from_hand = true
					break
			if not ally_node:
				ally_node = main._create_card(picked_ally, false)
				main._connect_card_signals(ally_node)

			var applies_to_this_ally := func(c: Node) -> bool:
				return c == ally_node
			PaymentManager.agregar_modificador_coste(ally_node, -discount, applies_to_this_ally, true)
			var coste_real: int = PaymentManager.calcular_coste_real(ally_node)
			var puede_pagar: bool = PaymentManager.puede_jugar_carta(ally_node, controller_id)
			PaymentManager.remover_modificador_coste(ally_node)

			if not puede_pagar:
				main._update_debug("No puedes pagar el Aliado con descuento (%d Oro)" % coste_real)
				if not from_hand:
					ally_node.queue_free()
			else:
				if from_hand:
					var hidx = main.player_hand.cards.find(ally_node)
					if hidx >= 0:
						main.player_hand.cards.remove_at(hidx)
					if ally_node.get_parent() == main.player_hand:
						main.player_hand.remove_child(ally_node)
				else:
					var cidx: int = CardManager.get_cemetery(controller_id).find(picked_ally)
					if cidx >= 0:
						CardManager.remove_from_cemetery(controller_id, cidx)

				if coste_real > 0:
					var ally_race: String = str(ally_node.get("card_raza")) if ally_node.get("card_raza") != null else ""
					await main._gold_manager.pagar_coste(coste_real, ally_node.card_type, ally_race, ally_node.card_cost)
					PaymentManager.registrar_pago(coste_real)

				await main._gold_manager._play_card_to_field(ally_node)

	# --- "Baraja hasta una carta oponente de coste 2 o menos" ---
	var opponent_id: int = 1 - controller_id
	var opp_fields: Array = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo] if opponent_id == 0 \
		else [main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
	var shuffle_candidates: Array = []
	for field in opp_fields:
		if not field:
			continue
		for c in field.get_children():
			if not is_instance_valid(c):
				continue
			if c.get("card_cost") != null and int(c.card_cost) <= 2:
				shuffle_candidates.append(c)
			var weapons = c.get("equipped_weapons")
			if weapons is Array:
				for w in weapons:
					if is_instance_valid(w) and w.get("card_cost") != null and int(w.card_cost) <= 2:
						shuffle_candidates.append(w)

	if not shuffle_candidates.is_empty() and main._card_interaction:
		var shuffle_filter := func(c: Node) -> bool:
			return c in shuffle_candidates
		var chosen: Node = await main._card_interaction.await_target(
			"Baraja hasta una carta rival en juego (coste 2 o menos) — ESC para no barajar ninguna", shuffle_filter)
		if chosen and is_instance_valid(chosen):
			var true_owner: int = chosen.owner_id if chosen.get("owner_id") != null else opponent_id
			ActionModule.return_to_deck(chosen, true_owner, true)
			CardManager.shuffle_deck(true_owner)

	return true


# =============================================================================
# PATRÓN "CUANDO ENTRA EN JUEGO, ROBA N, GENERA UN ORO PARA JUGAR X DE COSTE
# Y O MÁS Y SUBE HASTA M CARTA(S) DE TU CEMENTERIO A TU MANO" (Legión Paladín)
# =============================================================================
func try_execute_draw_gold_search_pattern(ability_text: String, controller_id: int) -> bool:
	"""Detecta 'Roba N carta(s), genera un Oro para jugar Aliados o Armas de
	coste X o más y sube hasta M carta(s) de tu Cementerio a tu mano' (Legión
	Paladín — 2026-08-29: texto reconfirmado en vivo contra la API, que
	resultó ser INESTABLE entre fetches para esta carta específica; esta es
	la versión que la API devolvió recién ahora, la misma que ya se había
	usado en una implementación anterior de este mismo desarrollo. Ver
	[[feedback_api_is_source_of_truth]] — se sincronizó también el cache
	local (user://card_cache/cards.json, id 20857) a este texto). Tres
	efectos encadenados SIN 'puedes' (no son opcionales, y el trigger es
	SOLO 'cuando entra en juego' — no incluye salir del juego). Se detecta
	por texto y se ejecutan los tres en orden.
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("genera un oro para jugar" in lower and "sube hasta" in lower and "cementerio" in lower):
		return false

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main:
		return true

	var draw_rx := RegEx.new()
	draw_rx.compile("(?i)roba[s]?\\s+(\\w+)\\s+cartas?")
	var m_draw := draw_rx.search(ability_text)
	var draw_amount: int = UniversalCardParser._parse_amount(m_draw.get_string(1)) if m_draw else 0

	var cost_rx := RegEx.new()
	cost_rx.compile("(?i)coste\\s+(\\w+)\\s+o\\s+m[aá]s")
	var m_cost := cost_rx.search(ability_text)
	var min_cost: int = UniversalCardParser._parse_amount(m_cost.get_string(1)) if m_cost else 0

	var search_rx := RegEx.new()
	search_rx.compile("(?i)sube\\s+hasta\\s+(\\w+)\\s+cartas?\\s+de\\s+tu\\s+cementerio\\s+a\\s+tu\\s+mano")
	var m_search := search_rx.search(ability_text)
	var search_amount: int = UniversalCardParser._parse_amount(m_search.get_string(1)) if m_search else 0

	if draw_amount > 0:
		await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)

	if min_cost > 0 and main._gold_manager:
		var predicate := func(card_type: int, _card_race: String, card_cost: int) -> bool:
			return card_type in [Constants.CardType.ALIADO, Constants.CardType.ARMA] and card_cost >= min_cost
		main._gold_manager.generar_oro_virtual_restringido(1, predicate, "Aliados o Armas de coste %d o más" % min_cost)

	if search_amount > 0 and controller_id == 0:
		await _executor._resolve_search_cemetery_to_hand(controller_id, search_amount)

	return true


func try_execute_draw_reveal_talisman_gold_pattern(ability_text: String, controller_id: int) -> bool:
	"""Detecta 'Roba una carta y puedes mostrar tu mano. Si no tienes más de
	un Talismán, genera un Oro para jugar Armas y Roba una carta adicional'
	(Levisterio, 2026-08-31). El 'mostrar tu mano' es cómo el jugador
	demuestra que cumple la condición del Talismán — no hay sistema de
	revelado-verificable de mano en este motor (SelectionCanvas.
	reveal_hand_cards() existe pero está huérfana/sin instanciar, ver
	arquitectura.md), así que se resuelve leyendo la mano directamente y
	dejando constancia en el log en vez de abrir una UI de revelado nueva
	para un único caso. El bonus condicional solo se evalúa para
	controller_id == 0 (mismo alcance ya usado por search_amount en
	try_execute_draw_gold_search_pattern) — no hay mano de IA modelada
	carta por carta para poder contar sus Talismanes.
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("puedes mostrar tu mano" in lower and "genera un oro para jugar armas" in lower and "roba una carta adicional" in lower):
		return false

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main:
		return true

	await ActionModule.draw(controller_id, 1, "etb_trigger", true)

	if controller_id == 0 and main.player_hand:
		var talisman_count: int = 0
		for c in main.player_hand.cards:
			if is_instance_valid(c) and c.card_type == Constants.CardType.TALISMAN:
				talisman_count += 1
		main._update_debug("Levisterio: mano mostrada (%d Talismán%s)" % [talisman_count, "" if talisman_count == 1 else "es"])
		if talisman_count <= 1 and main._gold_manager:
			var predicate := func(card_type: int, _card_race: String, _card_cost: int) -> bool:
				return card_type == Constants.CardType.ARMA
			main._gold_manager.generar_oro_virtual_restringido(1, predicate, "Armas")
			await ActionModule.draw(controller_id, 1, "etb_trigger", true)

	return true


func try_execute_deck_top_or_bottom_to_hand_pattern(ability_text: String, controller_id: int) -> bool:
	"""Detecta 'pon la primera o la última carta de tu Castillo en tu mano'
	(La Ouija, 2026-08-31 — carta promocional de 'IMP - Chile Oscuro 2', sin
	myl_id real, no está en la API externa; ver nota de fuente en
	_activate_ouija_play_from_cemetery_or_deck_top(), HandCementerioAbilityHandler.gd).
	Sin 'puedes': mandatorio, pero con una elección real entre las dos
	cartas (no 'la que sea al azar'). 'primera' = tope (índice 0, ver
	convención real documentada en CardManager.add_to_deck_top()), 'última'
	= fondo.
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("primera o la última carta de tu castillo" in lower and "en tu mano" in lower):
		return false
	if controller_id != 0:
		return false  # el bot no usa esta habilidad todavía

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main or main.player_deck.is_empty():
		return true

	# El revelado del tope (segunda mitad del texto de La Ouija: 'Juega
	# mostrando la primera carta de tu Castillo') arranca DESDE EL PRIMER
	# SEGUNDO que entra en juego (2026-08-31, corrección a pedido del
	# usuario: antes esto solo se aplicaba a la habilidad de una vez por
	# turno) — refrescar ACÁ, antes de ofrecer la elección tope/fondo, para
	# que el jugador ya sepa cuál es la del tope al decidir (la de fondo
	# sigue a ciegas). La carta ya es hija de player_gold con zona
	# RESERVA_ORO en este punto (_trigger_enter_play() se llama después de
	# _place_card_as_gold() la deja en su lugar), así que la detección por
	# texto en refresh_castillo_top_reveal() ya la encuentra.
	if main._zone_viewer:
		main._zone_viewer.refresh_castillo_top_reveal()

	var choose_top: bool = true
	if main.player_deck.size() > 1:
		choose_top = await SelectionManager.await_two_choice(
			main, "La Ouija",
			"Poner la primera carta de tu Castillo (tope) en tu mano",
			"Poner la última carta de tu Castillo (fondo) en tu mano")

	var card_data: Dictionary = main.player_deck.pop_front() if choose_top else main.player_deck.pop_back()
	var card_node: Node = main._create_card(card_data, false)
	main.player_hand.add_card(card_node)
	main._connect_card_signals(card_node)
	if main._zone_manager:
		main._zone_manager._update_castillo_counts()

	return true


func try_execute_banish_from_cemeteries_and_draw_pattern(ability_text: String, controller_id: int) -> bool:
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
		await _executor._resolve_banish_from_both_cemeteries(banish_amount)

	if draw_amount > 0:
		await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)

	return true


func try_execute_weapon_count_banish_cemetery_pattern(ability_text: String, controller_id: int) -> bool:
	"""Detecta 'En tu Fase Final, Destierra hasta tantas cartas de un
	Cementerio como Armas controles, más uno' (Hanta el Samurai,
	2026-09-02 — bug reportado por el usuario: sin patrón propio, esta
	habilidad caía al extractor genérico de UniversalCardParser, que no
	entiende una cantidad DINÁMICA 'tantas...como...' ni 'de un
	Cementerio' en esta forma exacta, y terminaba desterrando cartas EN
	JUEGO — se llevó puesta la Espada de O'Higgins equipada, con su bono
	de Fuerza y todo). 'Un Cementerio' sin posesivo = elegís CUÁL de los
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
	if result.cancelled:
		return true
	for picked_data in result.picked:
		var idx: int = CardManager.get_cemetery(target_owner).find(picked_data)
		if idx >= 0:
			CardManager.remove_from_cemetery(target_owner, idx)
			CardManager.add_to_exile(target_owner, picked_data)

	return true
