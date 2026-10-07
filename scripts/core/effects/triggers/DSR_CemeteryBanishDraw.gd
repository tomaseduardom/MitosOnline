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

	var amount: int = ContinuousEffectManager.get_modified_strength(card)
	if amount <= 0:
		return true

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main or not main._zone_viewer:
		return true
	# 2026-09-13, a pedido del usuario: click directo con ambos Cementerios
	# visibles en vez del modal de lista viejo — pool combinado, sin lock
	# (mismo caso que Espada de O'Higgins, arquitectura.md §10.14/§10.27).
	var no_filter := func(_c: Node) -> bool: return true
	var picked: Array = await main._zone_viewer.open_cemetery_target_picker(
		"Destierra hasta %d carta(s) de los Cementerios" % amount, no_filter, amount, "cemetery", false, false, controller_id)
	if not picked.is_empty() and await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return true
	for entry in picked:
		var owner_of_picked: int = entry.owner_id
		var picked_data: Dictionary = entry.data
		var idx: int = CardManager.get_cemetery(owner_of_picked).find(picked_data)
		if idx < 0:
			continue
		CardManager.remove_from_cemetery(owner_of_picked, idx)
		CardManager.add_to_exile(owner_of_picked, picked_data)
	return true


## try_execute_banish_up_to_n_cemeteries_then_draw_pattern() ELIMINADA
## (2026-09-13, a pedido del usuario — "la habilidad del Bernardo O'Higgins
## no es esa, revísalo bien" llevó a revisar TODO lo tocado en la misma
## tanda). Detectaba "Destierra hasta N cartas de los Cementerios y Roba M
## cartas" (Espada de O'Higgins) con un regex ESTRICTO, pero
## TriggerResolution.gd prueba los patrones EN ORDEN y
## try_execute_banish_from_cemeteries_and_draw_pattern() (más abajo en este
## mismo archivo, chequeo SUELTO: solo "de los cementerios" + "destierra"
## en el texto) corre ANTES y matchea cualquier texto que la versión
## estricta también matchearía — así que esta función NUNCA se alcanzaba
## para NINGUNA carta posible, no solo para O'Higgins. La conversión a
## click-directo de esta función (§10.14) se aplicó código muerto; la
## conversión real que sí importa está en
## MiscTargetedPatterns._resolve_banish_from_both_cemeteries() (la que de
## verdad ejecuta try_execute_banish_from_cemeteries_and_draw_pattern()),
## convertida en la misma revisión — ver arquitectura.md §10.21.


func try_execute_shuffle_cemeteries_or_raise_ally_totem_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Puedes Barajar hasta cuatro cartas de los Cementerios o subir un
	Aliado o Tótem de tu Cementerio a tu mano' (Campanita, 2026-09-04) —
	elección A/B."""
	var lower := ability_text.to_lower()
	if not ("barajar hasta cuatro cartas de los cementerios o subir un aliado o tótem de tu cementerio" in lower
			or "barajar hasta cuatro cartas de los cementerios o subir un aliado o totem de tu cementerio" in lower):
		return false

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main or not main._zone_viewer:
		return true
	# 2026-09-13, a pedido del usuario: la elección A/B en sí ('Barajar' vs
	# 'Subir') sigue siendo un modal de dos botones (son dos EFECTOS
	# distintos, no dos cartas — no es candidato al reemplazo por click, ver
	# arquitectura.md §10.16). Lo que cambió es CÓMO se elige la carta
	# DESPUÉS de esa decisión: ambas ramas ahora usan
	# ZoneViewerModule.open_cemetery_target_picker() en vez del modal de
	# lista viejo.
	var choose_shuffle: bool = await SelectionManager.await_two_choice(
		main, "Campanita", "Barajar hasta cuatro cartas de los Cementerios", "Subir un Aliado o Tótem de tu Cementerio a tu mano", controller_id)

	if choose_shuffle:
		var no_filter := func(_c: Node) -> bool: return true
		var picked: Array = await main._zone_viewer.open_cemetery_target_picker(
			"Baraja hasta cuatro carta(s) de los Cementerios", no_filter, 4, "cemetery", false, false, controller_id)
		if picked.is_empty():
			return true
		if await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Campanita", controller_id):
			return true
		for entry in picked:
			var owner_of_picked: int = entry.owner_id
			var picked_data: Dictionary = entry.data
			var idx: int = CardManager.get_cemetery(owner_of_picked).find(picked_data)
			if idx < 0:
				continue
			CardManager.remove_from_cemetery(owner_of_picked, idx)
			CardManager.get_deck(owner_of_picked).append(picked_data)
			CardManager.shuffle_deck(owner_of_picked)
			AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
				"callable": Callable(AnimationQueue, "animate_shuffle").bind(owner_of_picked),
				"description": "Barajar mazo (Campanita)"
			})
	else:
		# 'de TU Cementerio' (posesivo, solo propio) + filtrado por tipo —
		# el filtro rechaza tanto el lado rival como Armas/Talismanes/Oro;
		# esas cartas se ven en el popup pero no brillan ni son clickeables.
		var eligible_filter := func(c: Node) -> bool:
			return c.owner_id == controller_id and c.get("card_type") in [Constants.CardType.ALIADO, Constants.CardType.TOTEM]
		var picked: Array = await main._zone_viewer.open_cemetery_target_picker(
			"Sube un Aliado o Tótem de tu Cementerio a tu mano", eligible_filter, 1, "cemetery", false, false, controller_id)
		if picked.is_empty():
			return true
		if await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Campanita", controller_id):
			return true
		var picked_data: Dictionary = picked[0].data
		var idx: int = CardManager.get_cemetery(controller_id).find(picked_data)
		if idx < 0:
			return true
		CardManager.remove_from_cemetery(controller_id, idx)
		var card_node = main._create_card(picked_data, false)
		var hand_container_campanita = main.player_hand if controller_id == 0 else main._opponent_fan
		hand_container_campanita.add_card(card_node)
		main._connect_card_signals(card_node)
	return true


func try_execute_shuffle_up_to_n_cemeteries_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Puedes Barajar hasta N cartas de los Cementerios' (2026-09-04, p.ej.
	Tamales: 'En tu Fase Final, puedes Barajar hasta tres cartas de los
	Cementerios') — sin Desterrar (a diferencia de Armería del Guerrero/
	Colmillo de Vampiro, que ofrecen Barajar Y/O Desterrar). 'Los
	Cementerios' = ambos jugadores ([[project_no_zone_means_in_play]]),
	'puedes' = opcional, cancelar el picker = 0 elegidas.
	'and not "desterrar" in lower' (2026-09-15, bug real reportado por el
	usuario: Capitán O'Brien — 'puedes Barajar y/o Desterrar tantas cartas
	de los Cementerios como Fuerza tenga este Aliado' — caía AQUÍ por error
	('puedes barajar' es substring de esa frase), resolviendo solo Barajar
	1 carta en vez de la elección real Barajar/Desterrar por hasta Fuerza
	cartas). Ver try_execute_shuffle_or_banish_cemeteries_equal_to_strength_
	pattern más abajo, que ahora cubre el texto real."""
	var lower := ability_text.to_lower()
	if not ("puedes barajar" in lower and "cartas de los cementerios" in lower) or "desterrar" in lower:
		return false

	var amount_rx := RegEx.new()
	amount_rx.compile("barajar hasta (\\w+) cartas? de los cementerios")
	var m := amount_rx.search(lower)
	var max_amount: int = UniversalCardParser._parse_amount(m.get_string(1)) if m else 1

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main or not main._zone_viewer:
		return true
	# 2026-09-13, a pedido del usuario: click directo con ambos Cementerios
	# visibles en vez del modal de lista viejo.
	var no_filter := func(_c: Node) -> bool: return true
	var picked: Array = await main._zone_viewer.open_cemetery_target_picker(
		"Baraja hasta %d carta(s) de los Cementerios" % max_amount, no_filter, max_amount, "cemetery", false, false, controller_id)
	if picked.is_empty() or await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Tamales", controller_id):
		return true
	for entry in picked:
		var owner_of_picked: int = entry.owner_id
		var picked_data: Dictionary = entry.data
		var idx: int = CardManager.get_cemetery(owner_of_picked).find(picked_data)
		if idx < 0:
			continue
		CardManager.remove_from_cemetery(owner_of_picked, idx)
		CardManager.get_deck(owner_of_picked).append(picked_data)
		CardManager.shuffle_deck(owner_of_picked)
		AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
			"callable": Callable(AnimationQueue, "animate_shuffle").bind(owner_of_picked),
			"description": "Barajar mazo (Tamales)"
		})
	return true


func try_execute_banish_up_to_n_cemeteries_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'Puedes Desterrar hasta N cartas de los Cementerios' (2026-09-04,
	p.ej. Quantum Megumi: 'En tu Fase Final, puedes Desterrar hasta dos
	cartas de los Cementerios') — versión Desterrar (no Barajar) de
	try_execute_shuffle_up_to_n_cemeteries_pattern. 'Los Cementerios' =
	ambos jugadores ([[project_no_zone_means_in_play]]), 'puedes' =
	opcional, cancelar el picker = 0 elegidas. 'and not "barajar" in lower'
	(2026-09-15, mismo motivo que try_execute_shuffle_up_to_n_cemeteries_
	pattern — ver ese comentario): evita un falso-positivo simétrico si
	alguna carta real dice 'puedes Desterrar y/o Barajar...'."""
	var lower := ability_text.to_lower()
	if not ("puedes desterrar" in lower and "cartas de los cementerios" in lower) or "barajar" in lower:
		return false

	var amount_rx := RegEx.new()
	amount_rx.compile("desterrar hasta (\\w+) cartas? de los cementerios")
	var m := amount_rx.search(lower)
	var max_amount: int = UniversalCardParser._parse_amount(m.get_string(1)) if m else 1

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main or not main._zone_viewer:
		return true
	# 2026-09-13, a pedido del usuario: click directo con ambos Cementerios
	# visibles en vez del modal de lista viejo.
	var no_filter := func(_c: Node) -> bool: return true
	var picked: Array = await main._zone_viewer.open_cemetery_target_picker(
		"Destierra hasta %d carta(s) de los Cementerios" % max_amount, no_filter, max_amount, "cemetery", false, false, controller_id)
	if picked.is_empty() or await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Quantum Megumi", controller_id):
		return true
	for entry in picked:
		var owner_of_picked: int = entry.owner_id
		var picked_data: Dictionary = entry.data
		var idx: int = CardManager.get_cemetery(owner_of_picked).find(picked_data)
		if idx < 0:
			continue
		CardManager.remove_from_cemetery(owner_of_picked, idx)
		CardManager.add_to_exile(owner_of_picked, picked_data)
	return true


func try_execute_shuffle_or_banish_cemeteries_equal_to_strength_pattern(ability_text: String, controller_id: int, card: Node = null) -> bool:
	"""'En tu Fase Final, puedes Barajar y/o Desterrar tantas cartas de los
	Cementerios como Fuerza tenga este Aliado' (Capitán O'Brien, 2026-09-15
	— bug real reportado por el usuario: sin patrón propio hasta ahora,
	caía por error en try_execute_shuffle_up_to_n_cemeteries_pattern
	de arriba — 'puedes barajar' es substring de esta frase — resolviendo
	solo Barajar 1 carta en vez de la elección real Barajar/Desterrar por
	carta, hasta tantas cartas como Fuerza efectiva tenga este Aliado).
	Cantidad DINÁMICA (a diferencia de Armería del Guerrero/Belta/Uriel/
	Torre de Babel, que son un número fijo) — reusa GoldManager.
	_resolve_armeria_barajar_desterrar() con el amount calculado, mismo
	criterio que esos llamadores: la ventana de respuesta se abre ANTES de
	arrancar toda la resolución (el helper compartido resuelve elección
	intercalada carta-por-carta sin un punto limpio de 'declarar todo
	antes de ejecutar', ver el comentario del propio helper en
	GoldManager.gd)."""
	var lower := ability_text.to_lower()
	if not ("barajar y/o desterrar" in lower and "cartas de los cementerios" in lower and "fuerza tenga" in lower):
		return false
	if not is_instance_valid(card):
		return true

	var amount: int = ContinuousEffectManager.get_modified_strength(card)
	if amount <= 0:
		return true

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true
	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return true
	await main._gold_manager._resolve_armeria_barajar_desterrar(amount, str(card.card_name), controller_id)
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

	if banish_amount > 0:
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

	var main := _executor._main.get_node_or_null("/root/Main")
	if not main:
		return true

	var weapon_count: int = 0
	var own_fields_hanta: Array = [main.player_field, main.player_linea_ataque] if controller_id == 0 else [main.opponent_field, main.opponent_linea_ataque]
	for field in own_fields_hanta:
		if not field:
			continue
		for c in field.get_children():
			if not is_instance_valid(c):
				continue
			var weapons = c.get("equipped_weapons")
			if weapons is Array:
				weapon_count += weapons.size()
	var amount: int = weapon_count + 1

	if CardManager.get_cemetery(0).is_empty() and CardManager.get_cemetery(1).is_empty():
		return true
	if not main._zone_viewer:
		return true

	# 2026-09-13, a pedido del usuario: ver ambos Cementerios lado a lado y
	# elegir con click directo, en vez de preguntar primero 'de cuál
	# Cementerio' con un modal — 'un Cementerio' (sin posesivo, singular) en
	# el texto real sigue significando UN SOLO Cementerio para toda esta
	# habilidad, no un pool combinado (a diferencia de Espada de O'Higgins,
	# 'los Cementerios' en plural) — lock_to_one_side=true lo hace cumplir:
	# tras el primer click, el otro Cementerio deja de ser elegible.
	var no_filter := func(_c: Node) -> bool: return true
	var picked: Array = await main._zone_viewer.open_cemetery_target_picker(
		"Destierra hasta %d carta(s) de UN Cementerio (tuyo o rival)" % amount,
		no_filter, amount, "cemetery", true, false, controller_id)
	if picked.is_empty():
		return true
	if await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Hanta el Samurai", controller_id):
		return true
	for entry in picked:
		var target_owner: int = entry.owner_id
		var picked_data: Dictionary = entry.data
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
	triggers() llega hasta aquí, el mismo texto completo se revisa de
	nuevo, así que el patrón matchea las dos veces por diseño. 'Cementerio
	oponente' con posesivo explícito = siempre el del rival, sin elección
	de zona.
	Returns: true si el patrón aplicaba."""
	var lower := ability_text.to_lower()
	if not ("destierra hasta tres cartas del cementerio oponente" in lower):
		return false

	var opponent_id: int = 1 - controller_id
	if CardManager.get_cemetery(opponent_id).is_empty():
		return true
	var main := _executor._main.get_node_or_null("/root/Main")
	if not main or not main._zone_viewer:
		return true

	# 2026-09-13, a pedido del usuario: click directo en el Cementerio rival
	# en vez del modal de lista viejo.
	var opp_only := func(c: Node) -> bool: return c.owner_id == opponent_id
	var picked: Array = await main._zone_viewer.open_cemetery_target_picker(
		"Destierra hasta 3 carta(s) del Cementerio rival", opp_only, 3, "cemetery", false, false, controller_id)
	if picked.is_empty() or await TriggerSystem.open_response_window(card, str(card.card_name) if card else "Mariano Osorio", controller_id):
		return true
	for entry in picked:
		var idx: int = CardManager.get_cemetery(opponent_id).find(entry.data)
		if idx >= 0:
			CardManager.remove_from_cemetery(opponent_id, idx)
			CardManager.add_to_exile(opponent_id, entry.data)
	return true
