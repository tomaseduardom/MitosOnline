extends RefCounted
## DSR_ShuffleDrawCombos — Slice de DrawShuffleResolver.gd: patrones compuestos
## "baraja... y roba..." / "roba... y baraja..." que combinan barajar cartas
## (de la mano, del Destierro, o una carta oponente en juego) con un robo de
## cartas en la misma oración (El Rey y el Verdugo, Aaru, Manuel Bulnes,
## Espada Vikinga, Trono del Dragón). Uno de 4 hermanos separados de
## DrawShuffleResolver.gd (2026-09-06, "módulos gordos") — ver también
## DSR_CemeteryBanishDraw.gd, DSR_SearchGoldCombos.gd y
## DSR_DiscardChoicePatterns.gd. Opera sobre TriggerSystem via
## _executor._main (mismo Node que TargetedEffectExecutor._main — ver ese
## archivo). DrawShuffleResolver.gd queda como FACADE — cada función de este
## archivo es llamada por un reenvío de una sola línea desde ahí, con el
## mismo nombre y firma de siempre, así que TriggerResolution.gd (único
## llamador) no necesitó cambiar una sola línea por este split.

var _executor: TargetedEffectExecutor


func setup(executor: TargetedEffectExecutor) -> void:
	_executor = executor


# =============================================================================
# PATRÓN "BARAJA TODAS LAS X DE TU DESTIERRO Y ROBA N CARTA(S)" (El Rey y
# el Verdugo)
# =============================================================================
func try_execute_shuffle_exile_and_draw_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""Detecta 'Baraja todas las X de tu Destierro y Roba N carta(s)'
	(2026-08-29, p.ej. El Rey y el Verdugo: '...todas las Armas de tu
	Destierro...') — mueve del Destierro de vuelta al Castillo las cartas
	que cumplan el tipo, baraja, y roba. Sin 'puedes': mandatorio.
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("de tu destierro" in lower and "baraja" in lower):
		return false
	if await TriggerSystem.open_response_window(card, str(card.get("card_name")) if card else "El Rey y el Verdugo", controller_id):
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
		# 2026-09-30, mismo criterio que el fix de Azi Sruvara: sin esto no
		# había ninguna retroalimentación visual del barajado.
		AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
			"callable": Callable(AnimationQueue, "animate_shuffle").bind(controller_id),
			"description": "Barajar mazo (El Rey y el Verdugo)"
		})
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
	# 2026-09-30, bug real expuesto al convertir esto a la Fase 3: 'main.
	# player_hand' hardcodeado sin mirar controller_id — para el jugador 1
	# (bot/Remoto) había que usar _opponent_fan en su lugar.
	var hand_container = main.player_hand if controller_id == 0 else main.get("_opponent_fan")
	if hand_container and main._card_interaction:
		var hand_cards: Array = (main.player_hand.cards if controller_id == 0 else hand_container.get_cards()).duplicate()
		if not hand_cards.is_empty():
			# 2026-09-13, a pedido del usuario: click directo en la mano en vez
			# del modal de lista viejo.
			var chosen: Array = await main._card_interaction.await_multi_target(
				"Baraja cualquier cantidad de cartas de tu mano en tu Castillo", hand_cards, -1, Callable(), Callable(), true, null, controller_id)
			for c in chosen:
				if is_instance_valid(c):
					var data: Dictionary = c.card_data
					hand_container.remove_card(c, true)
					CardManager.get_deck(controller_id).append(data)
					shuffled_amount += 1
			if shuffled_amount > 0:
				CardManager.shuffle_deck(controller_id)
				AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
					"callable": Callable(AnimationQueue, "animate_shuffle").bind(controller_id),
					"description": "Barajar mazo (Aaru)"
				})

	# Equivale a barajar 0 si no había candidatos — sigue siendo una
	# resolución completa según el texto ('cualquier cantidad' incluye 0).
	await ActionModule.draw(controller_id, shuffled_amount + 2, "talisman_resolve", true)
	return true


func try_execute_draw_and_shuffle_hand_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
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

	if await TriggerSystem.open_response_window(card, str(card.get("card_name")) if card else "Manuel Bulnes", controller_id):
		return true

	if draw_amount > 0:
		await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)

	if shuffle_amount > 0:
		var main := _executor._main.get_node_or_null("/root/Main")
		# 2026-09-30, mismo bug que Aaru más arriba: hardcodeado a player_hand
		# sin mirar controller_id.
		var hand_container = main.player_hand if (main and controller_id == 0) else (main.get("_opponent_fan") if main else null)
		if main and hand_container and main._card_interaction:
			var hand_cards: Array = (main.player_hand.cards if controller_id == 0 else hand_container.get_cards()).duplicate()
			if not hand_cards.is_empty():
				# 2026-09-13, a pedido del usuario: click directo en la mano en
				# vez del modal de lista viejo. Mandatorio (sin "puedes"): se
				# pide sin ESC ("cancellable=false", mismo criterio que
				# _select_hand_cards_for_discard(), §10.29) — no debería poder
				# esquivarse un barajado mandatorio de la mano.
				var pick_amount: int = mini(shuffle_amount, hand_cards.size())
				var chosen: Array = await main._card_interaction.await_multi_target(
					"Baraja %d carta(s) de tu mano en tu Castillo" % shuffle_amount, hand_cards, pick_amount,
					Callable(), Callable(), false, null, controller_id)
				var shuffled := 0
				for c in chosen:
					if is_instance_valid(c):
						var data: Dictionary = c.card_data
						hand_container.remove_card(c, true)
						CardManager.get_deck(controller_id).append(data)
						shuffled += 1
				if shuffled > 0:
					CardManager.shuffle_deck(controller_id)
					AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
						"callable": Callable(AnimationQueue, "animate_shuffle").bind(controller_id),
						"description": "Barajar mazo (Manuel Bulnes)"
					})

	return true


func try_execute_draw_and_shuffle_opponent_card_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
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
	Bulnes, Aaru — ambas partes ocurren siempre), aquí el orden LÓGICO real
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
			if ContinuousEffectManager.get_modified_cost(c) <= ally_count:
				candidates.append(c)
			var weapons = c.get("equipped_weapons")
			if weapons is Array:
				for w in weapons:
					if is_instance_valid(w) and ContinuousEffectManager.get_modified_cost(w) <= ally_count:
						candidates.append(w)

	if candidates.is_empty():
		# 'Barajar' no encuentra objetivo válido — 'Robar' NO corre (regla
		# del usuario, 2026-08-30).
		return true

	var chosen: Node = null
	if main._card_interaction:
		var filter := func(c: Node) -> bool:
			return c in candidates
		chosen = await main._card_interaction.await_target(
			"Elige una carta rival en juego (coste %d o menos) para barajar" % ally_count, filter, true, controller_id)
	else:
		candidates.shuffle()
		chosen = candidates[0]

	if not chosen or not is_instance_valid(chosen):
		return true
	# Sin ventana genérica aquí (2026-09-09): return_to_deck() ya consulta
	# Prevención adentro por su cuenta.
	var true_owner: int = chosen.owner_id if chosen.get("owner_id") != null else opponent_id
	await ActionModule.return_to_deck(chosen, true_owner, true, card)
	CardManager.shuffle_deck(true_owner)

	if draw_amount > 0:
		await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)

	return true


func try_execute_shuffle_hand_then_draw_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""Detecta 'Baraja N carta(s) de tu mano y Roba M carta(s)' (2026-09-03,
	p.ej. Trono del Dragón: 'Cuando entra en juego, Baraja dos cartas de tu
	mano y Roba tres cartas') — orden INVERSO al ya existente try_execute_
	draw_and_shuffle_hand_pattern() (Manuel Bulnes: 'Roba... y Baraja... de
	tu mano EN TU CASTILLO', roba primero) — aquí el texto imprime Barajar
	primero, así que se resuelve en ese orden (el jugador elige QUÉ cartas
	barajar antes de robar; DAR: sin 'puedes', mandatorio en las dos
	partes). Gate distinto ('de tu mano y roba', sin 'en tu castillo') para
	no colisionar con el patrón de Manuel Bulnes.
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("baraja" in lower and "de tu mano y roba" in lower):
		return false

	var shuffle_rx := RegEx.new()
	shuffle_rx.compile("(?i)baraja[s]?\\s+(\\w+)\\s+cartas?\\s+de\\s+tu\\s+mano")
	var m_shuffle := shuffle_rx.search(ability_text)
	var shuffle_amount: int = UniversalCardParser._parse_amount(m_shuffle.get_string(1)) if m_shuffle else 0

	var draw_rx := RegEx.new()
	draw_rx.compile("(?i)roba[s]?\\s+(\\w+)\\s+cartas?")
	var m_draw := draw_rx.search(ability_text)
	var draw_amount: int = UniversalCardParser._parse_amount(m_draw.get_string(1)) if m_draw else 0

	if await TriggerSystem.open_response_window(card, str(card.get("card_name")) if card else "Trono del Dragón", controller_id):
		return true

	if shuffle_amount > 0:
		var main := _executor._main.get_node_or_null("/root/Main")
		# 2026-09-30, mismo bug que Aaru/Manuel Bulnes más arriba: hardcodeado
		# a player_hand sin mirar controller_id.
		var hand_container = main.player_hand if (main and controller_id == 0) else (main.get("_opponent_fan") if main else null)
		if main and hand_container and main._card_interaction:
			var hand_cards: Array = (main.player_hand.cards if controller_id == 0 else hand_container.get_cards()).duplicate()
			if not hand_cards.is_empty():
				# 2026-09-13, a pedido del usuario: click directo en la mano en
				# vez del modal de lista viejo. Mandatorio, sin ESC (§10.29).
				var pick_amount: int = mini(shuffle_amount, hand_cards.size())
				var chosen: Array = await main._card_interaction.await_multi_target(
					"Baraja %d carta(s) de tu mano en tu Castillo" % shuffle_amount, hand_cards, pick_amount,
					Callable(), Callable(), false, null, controller_id)
				var shuffled := 0
				for c in chosen:
					if is_instance_valid(c):
						var data: Dictionary = c.card_data
						hand_container.remove_card(c, true)
						CardManager.get_deck(controller_id).append(data)
						shuffled += 1
				if shuffled > 0:
					CardManager.shuffle_deck(controller_id)
					AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
						"callable": Callable(AnimationQueue, "animate_shuffle").bind(controller_id),
						"description": "Barajar mazo (Trono del Dragón)"
					})

	if draw_amount > 0:
		await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)

	return true
