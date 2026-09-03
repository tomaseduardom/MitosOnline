extends RefCounted
class_name TargetedEffectExecutor
## TargetedEffectExecutor — Ejecución de acciones ETB extraídas por texto
## (extract_action()) que requieren elegir UN objetivo con clic (destruir,
## desterrar, anular, silenciar, buff/debuff, devolver al mazo) y los
## patrones compuestos "puedes [costo] y Roba N" / weapon-discount-draw /
## shuffle-for-draw. Opera sobre TriggerSystem via _main.
## Extraído de TriggerSystem.gd (Fase 4 de reestructuración). Los patrones
## "mira/muestra N... elige qué hacer con ellas" (Signo Amarillo, Tangata
## Manu, Presente, Perder la Razón) se sacaron aparte a
## LookAndPlayResolver.gd (2026-08-28, "módulos gordos" — este archivo solo
## sigue en TriggerSystem._targeted_executor; el nuevo vive en
## TriggerSystem._look_and_play).

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
# DISPATCHER — ejecuta el GameAction de extract_action() según su tipo
# =============================================================================
func execute_parsed_action(action: Dictionary, card: Node, _event_data: Dictionary) -> void:
	"""Ejecuta un GameAction retornado por extract_action().
	Ruta principal: ActionModule.draw(N).
	Fallback: ZoneManager.draw_card() × N (como especificado en el DAR).
	"""
	var controller_id: int = card.get("controller_id") if card.get("controller_id") != null else 0
	var amount: int = action.get("value", 1)

	# Confirmación visual de que esta carta está disparando/activando una
	# habilidad (a pedido del usuario) — punto único para ambos casos:
	# disparadas (llamado desde _collect_triggers_for_event) y activadas
	# (llamado desde ActionPipeline._resolve_ability()).
	if is_instance_valid(card) and card.has_method("play_ability_activation_effect"):
		card.play_ability_activation_effect()

	match action.get("type", ""):
		"DRAW":
			# ActionModule es autoload — siempre existe, sin necesidad de
			# get_node_or_null/has_method (2026-08-28, "módulos gordos" punto
			# 1: esos guards solo escondían un fallback roto, ver abajo).
			await ActionModule.draw(controller_id, amount, "etb_trigger", true)

		"DESTROY":
			await _execute_targeted_destroy(card)

		"BANISH":
			await _execute_targeted_banish(card)

		"DISCARD":
			await _execute_targeted_discard(card, controller_id, amount)

		"SHUFFLE":
			ActionModule.shuffle_deck(controller_id)

		"MILL":
			var ability_text_mill: String = card.get("card_ability") if card.get("card_ability") != null else ""
			var to_exile_mill: bool = "destierro" in ability_text_mill.to_lower()
			# skip_validation=true: _validate_mill() depende del GameBoard
			# legacy (siempre null) y rechazaría la acción antes de
			# llegar al fallback real de mill() (vía EffectController).
			await ActionModule.mill(controller_id, amount, to_exile_mill, "etb_trigger", true)

		"SEARCH":
			await _execute_targeted_search(card, controller_id)

		"RETURN_DECK":
			await _execute_targeted_return_to_deck(card, controller_id)

		"SHUFFLE_FOR_DRAW":
			await _execute_shuffle_for_draw(action, controller_id)

		"PLAY_WEAPON_DISCOUNT_DRAW", "PLAY_WEAPON_DISCOUNT":
			await _execute_play_weapon_discount_draw(action, controller_id)

		"RETURN_WEAPON_SWAP_FREE":
			await _execute_return_weapon_swap_free(controller_id)

		"CONVERT_ORO_OR_LOW_COST":
			await _execute_targeted_convert(card, action)

		"LOOK":
			# Cartas simples "Mira N cartas del tope" sin el patrón compuesto
			# de elegir 1 a mano / 1 a Cementerio (ese lo resuelve
			# try_execute_look_pick_pattern() antes de llegar acá) — solo
			# las muestra, en privado, sin mover nada.
			var deck: Array = CardManager.get_deck(controller_id)
			var top_cards: Array = deck.slice(0, mini(amount, deck.size()))
			if not top_cards.is_empty():
				SelectionManager.open_reveal(top_cards, "Mirando %d carta(s) del tope de tu Castillo" % top_cards.size())

		"REVEAL":
			# Igual que LOOK pero es información pública (DAR): ambos
			# jugadores "ven" las cartas reveladas, no solo el controlador.
			# El overlay es local (SelectionManager no distingue jugadores en
			# red), así que la diferencia real es el título mostrado.
			#
			# A diferencia de LOOK, acá SÍ hay que barajar después (2026-08-26,
			# regla del usuario): "Muestra/Revela del tope" sin instrucción
			# de orden deja saber a los dos jugadores qué cartas y en qué
			# orden están arriba del mazo — barajar borra esa ventaja, cosa
			# que "Mira" no necesita porque es privado y deja reordenar.
			var deck_reveal: Array = CardManager.get_deck(controller_id)
			var top_cards_reveal: Array = deck_reveal.slice(0, mini(amount, deck_reveal.size()))
			if not top_cards_reveal.is_empty():
				SelectionManager.open_reveal(top_cards_reveal, "Revelando %d carta(s) del tope del Castillo (público)" % top_cards_reveal.size())
				CardManager.shuffle_deck(controller_id)

		"BUFF", "DEBUFF":
			await _execute_targeted_buff(action, card, controller_id, amount)

		"SILENCE":
			await _execute_targeted_silence(card)

		"ANNUL":
			await _execute_targeted_annul(card)

		"GOLD":
			# 'Genera un Oro por el turno' (p.ej. Lobo Sagrado al atacar): Oro
			# virtual, solo sirve para pagar costes, no es una carta física ni
			# cuenta para efectos que miran la Reserva/Oro Pagado. Expira al
			# empezar el próximo turno — ver GoldManager.limpiar_oros_virtuales(),
			# conectado a GameManager.turn_started.
			var main_gold := _main.get_node_or_null("/root/Main")
			if main_gold and main_gold._gold_manager and main_gold._gold_manager.has_method("generar_oros_virtuales"):
				main_gold._gold_manager.generar_oros_virtuales(amount)
			else:
				push_warning("[TriggerSystem] No se pudo generar Oro Virtual: GoldManager no disponible")

		"PREVENT_DAMAGE":
			# type -1 = cualquier tipo de daño (convención ya usada en
			# DamageManager para "aplica a todo"); one_shot: se consume
			# con el primer daño que prevenga, no dura el turno completo.
			DamageManager.add_damage_prevention(controller_id, amount, -1, true, card)

		_:
			push_warning("[TriggerSystem] Tipo de acción ETB no implementado: %s" % action.get("type", "?"))


func _select_ally_target(prompt: String, source_card: Node = null) -> Node:
	"""Pide al jugador elegir un Aliado en juego (propio o enemigo) con clic,
	reutilizando el modo de selección que ya usa 'colocar Oro'
	(CardInteractionModule.is_selecting_target). Devuelve null si no hay
	forma de abrir el modo de selección (Main/CardInteractionModule ausentes).
	source_card (2026-08-30, p.ej. Aho: 'el portador gana... y no puede ser
	afectado por Aliados oponentes') — si se pasa, se excluyen los Aliados
	inmunes a esta fuente en particular (ver _is_immune_to_enemy_ally)."""
	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		push_warning("[TriggerSystem] No se pudo abrir selección de objetivo")
		return null

	var filter := func(c: Node) -> bool:
		if c.get("card_type") != Constants.CardType.ALIADO:
			return false
		var parent = c.get_parent()
		if parent not in [main.player_field, main.player_linea_ataque, main.opponent_field, main.opponent_linea_ataque]:
			return false
		if _is_immune_to_enemy_ally(c, source_card):
			return false
		# Inmunidad a Talismanes otorgada por otra carta (2026-09-02, p.ej.
		# Espíritu Kotaix: "Tus Aliados ganan... y no pueden ser afectados
		# por Talismanes") — a diferencia de _target_text_denies(), que solo
		# ve el texto propio del objetivo, esto consulta los modificadores
		# de protección registrados por AURAS (ContinuousEffectManager).
		# Solo aplica cuando la fuente de este efecto es un Talismán — un
		# Aliado inmune a Talismanes sigue siendo objetivo legal de
		# Silenciar/Convertir/etc. de otras cartas.
		if source_card and source_card.get("card_type") == Constants.CardType.TALISMAN \
				and ContinuousEffectManager.has_protection(c, "TALISMAN"):
			return false
		return true
	return await main._card_interaction.await_target(prompt, filter)


func _select_annul_target_cost_filter(prompt: String, max_cost: int) -> Node:
	"""Como _select_ally_target() pero para 'una carta' genérica en juego
	(no solo Aliados) con tope de coste — 2026-08-30, p.ej. Paladín
	Bestiarium: 'Anular una carta de coste 1 o menos'. Incluye Aliados,
	Armas y Tótems en cualquiera de las tres zonas de campo de ambos
	jugadores; no Oro (no tiene sentido 'anular' un Oro) ni Talismanes
	(ya se resolvieron al jugarse, no quedan en juego)."""
	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		return null
	var filter := func(c: Node) -> bool:
		if c.get("card_type") not in [Constants.CardType.ALIADO, Constants.CardType.ARMA, Constants.CardType.TOTEM]:
			return false
		var parent = c.get_parent()
		var valid_zones = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
			main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
		if parent not in valid_zones:
			return false
		var cost = c.get("card_cost")
		if cost == null or int(cost) > max_cost:
			return false
		return true
	return await main._card_interaction.await_target(prompt, filter)


func _select_ally_or_totem_target(prompt: String) -> Node:
	"""Como _select_ally_target() pero incluye Tótems además de Aliados —
	2026-08-30, p.ej. Aho: 'Destierra un Aliado o Tótem'. Cualquiera de los
	dos jugadores, en cualquiera de sus tres zonas de campo."""
	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		return null
	var filter := func(c: Node) -> bool:
		if c.get("card_type") not in [Constants.CardType.ALIADO, Constants.CardType.TOTEM]:
			return false
		var parent = c.get_parent()
		var valid_zones = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
			main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
		if parent not in valid_zones:
			return false
		return true
	return await main._card_interaction.await_target(prompt, filter)


func _is_immune_to_enemy_ally(target: Node, source_card: Node) -> bool:
	"""'No puede ser afectado por Aliados oponentes' (2026-08-30, p.ej. Aho —
	el Arma le da esta protección a su portador). Solo bloquea cuando la
	FUENTE del efecto es un Aliado enemigo del target (un Arma/Talismán/Oro
	rival, o un Aliado propio, siguen afectándolo igual — el texto protege
	específicamente de Aliados oponentes, no de todo). La protección puede
	estar en el propio target o en un Arma que tenga equipada."""
	if not source_card or not is_instance_valid(source_card):
		return false
	if source_card.get("card_type") != Constants.CardType.ALIADO:
		return false
	var source_owner = source_card.get("owner_id")
	var target_owner = target.get("owner_id")
	if source_owner == null or target_owner == null or source_owner == target_owner:
		return false

	var texts: Array = []
	if target.get("card_ability") != null:
		texts.append(str(target.card_ability))
	if target.get("equipped_weapons") != null:
		for w in target.equipped_weapons:
			if is_instance_valid(w) and w.get("card_ability") != null:
				texts.append(str(w.card_ability))
	for t in texts:
		if "no puede ser afectado por aliados oponentes" in t.to_lower():
			return true
	return false


func _execute_targeted_buff(action: Dictionary, card: Node, _controller_id: int, amount: int) -> void:
	"""Modifica la Fuerza de UN Aliado elegido por el jugador (DAR 7.2).
	Los Aliados tienen un único indicador de Fuerza (que también es su vida/
	resistencia) — no hay par ataque/defensa. El modificador se registra en
	ContinuousEffectManager — BattleManager._get_strength() ya lo consulta,
	así que se refleja de inmediato en el cálculo de combate."""
	var is_debuff: bool = action.get("type", "") == "DEBUFF"
	var value: int = -amount if is_debuff else amount
	var sign := "-" if is_debuff else "+"
	var chosen_target := await _select_ally_target("Elige un Aliado: %s%d de Fuerza" % [sign, amount], card)

	if not chosen_target or not is_instance_valid(chosen_target):
		return

	# "Prevenir que una carta sea afectada por un efecto oponente"
	# (2026-08-30, Estaca) — solo aplica a debuffs (un buff no es un efecto
	# hostil que valga la pena bloquear).
	if is_debuff and EffectController.try_consume_opponent_effect_prevention(chosen_target, card):
		return

	var duration = ContinuousEffectManager.ModifierDuration.PERMANENT
	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	var ability_lower := ability_text.to_lower()
	if "este turno" in ability_lower or "final del turno" in ability_lower:
		duration = ContinuousEffectManager.ModifierDuration.UNTIL_END_TURN

	var card_name: String = card.get("card_name") if card.get("card_name") != null else "carta"
	ContinuousEffectManager.register_modifier({
		"source": card,
		"target": chosen_target,
		"type": ContinuousEffectManager.ModifierType.STRENGTH,
		"stat": "strength",
		"value": value,
		"operation": "add",
		"duration": duration,
		"layer": ContinuousEffectManager.ModifierLayer.LAYER_7B_CHAR_MODIFY,
		"description": "%s de %s" % [("Debuff" if is_debuff else "Buff"), card_name],
	})


func _execute_targeted_destroy(card: Node) -> void:
	"""Destruye UN Aliado en juego elegido por el jugador — va al Cementerio
	(a diferencia de ANNUL/BANISH, que van a Destierro)."""
	var chosen_target := await _select_ally_target("Elige un Aliado para destruir", card)
	if not chosen_target or not is_instance_valid(chosen_target):
		return
	await ActionModule.destroy([chosen_target], card, true, true)


func _execute_targeted_banish(card: Node) -> void:
	"""Destierra UN Aliado en juego elegido por el jugador — va a Destierro,
	no se puede recuperar por medios normales (DAR Sección 8)."""
	var chosen_target := await _select_ally_target("Elige un Aliado para desterrar", card)
	if not chosen_target or not is_instance_valid(chosen_target):
		return
	await ActionModule.banish([chosen_target], card, true)


func _execute_targeted_discard(card: Node, controller_id: int, amount: int) -> void:
	"""Descarta N cartas de una mano (DAR Sección 8). Por defecto la mano del
	controlador; si el texto menciona 'oponente'/'rival', la del rival. Si
	dice 'al azar' se eligen al azar; si no, y es la mano del jugador humano,
	él elige con la UI (mismo overlay que el descarte por límite de mano)."""
	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	var ability_lower := ability_text.to_lower()
	var random_pick := "al azar" in ability_lower
	var target_player := controller_id
	if "oponente" in ability_lower or "rival" in ability_lower:
		target_player = 1 - controller_id

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return

	var hand_cards: Array = []
	if target_player == 0:
		if main.player_hand and main.player_hand.get("cards") != null:
			hand_cards = main.player_hand.cards.duplicate()
	else:
		if main._opponent_fan and main._opponent_fan.has_method("get_cards"):
			hand_cards = main._opponent_fan.get_cards().duplicate()
	if hand_cards.is_empty():
		return

	amount = mini(amount, hand_cards.size())
	var to_discard: Array
	if target_player == 0 and not random_pick:
		to_discard = await _select_hand_cards_for_discard(hand_cards, amount)
	else:
		hand_cards.shuffle()
		to_discard = hand_cards.slice(0, amount)

	if to_discard.is_empty():
		return

	await ActionModule.discard(target_player, to_discard, "etb_trigger", true)


# =============================================================================
# PATRÓN "TU OPONENTE DESCARTA N... Y TÚ ROBAS [HASTA] M CARTAS" (p.ej. Miguel)
# =============================================================================
func _resolve_banish_from_both_cemeteries(max_amount: int) -> void:
	"""Destierra hasta max_amount cartas combinadas entre ambos Cementerios
	(2026-08-30, Espada de O'Higgins). DOS selecciones SEPARADAS (primero
	el Cementerio RIVAL, después el propio — orden a pedido del usuario,
	2026-08-30) en vez de un solo pool mezclado, que confundía de cuál
	Cementerio salía cada carta al elegir. El tope de la segunda selección
	se descuenta de lo ya elegido en la primera, así el total combinado
	sigue respetando max_amount. Cada carta se destierra al Destierro de
	SU DUEÑO real."""
	var own_cemetery: Array = CardManager.get_cemetery(0)
	var opp_cemetery: Array = CardManager.get_cemetery(1)
	if own_cemetery.is_empty() and opp_cemetery.is_empty():
		return

	var chosen_count := 0

	if not opp_cemetery.is_empty():
		var result_opp: Dictionary = await SelectionManager.await_multi_pick(
			opp_cemetery, "Destierra hasta %d carta(s) del Cementerio RIVAL" % max_amount, max_amount)
		if not result_opp.cancelled:
			for picked_data in result_opp.picked:
				var idx: int = CardManager.get_cemetery(1).find(picked_data)
				if idx >= 0:
					CardManager.remove_from_cemetery(1, idx)
					CardManager.add_to_exile(1, picked_data)
					chosen_count += 1

	var remaining: int = max_amount - chosen_count
	if remaining > 0 and not own_cemetery.is_empty():
		var result_own: Dictionary = await SelectionManager.await_multi_pick(
			own_cemetery, "Destierra hasta %d carta(s) de TU Cementerio" % remaining, remaining)
		if not result_own.cancelled:
			for picked_data in result_own.picked:
				var idx: int = CardManager.get_cemetery(0).find(picked_data)
				if idx >= 0:
					CardManager.remove_from_cemetery(0, idx)
					CardManager.add_to_exile(0, picked_data)


func _select_hand_cards_for_discard(hand_cards: Array, amount: int) -> Array:
	"""Pide al jugador humano elegir qué cartas descartar de su propia mano,
	reutilizando el overlay SelectionManager en modo DISCARD (mismo patrón
	de espera de señal que ActionModule._select_search_results())."""
	var card_data_list: Array = []
	for c in hand_cards:
		card_data_list.append(c.card_data)

	var result: Dictionary = await SelectionManager.await_multi_pick(
		card_data_list, "Descarta %d carta(s)" % amount, amount, amount, false)

	# Traducir datos elegidos de vuelta a los nodos Card reales
	var chosen_nodes: Array = []
	for data in result.picked:
		for c in hand_cards:
			if c.card_data == data:
				chosen_nodes.append(c)
				break
	return chosen_nodes


func _target_text_denies(target: Node, phrases: Array) -> bool:
	"""Verifica si el propio texto de la carta OBJETIVO la protege
	explícitamente contra un efecto ('esta carta no puede ser anulada',
	'no puede perder su habilidad', etc.). 'Inmune a X' no es una keyword
	fija en Mitos y Leyendas — es texto libre de cada carta ('no puede ser
	afectada por talismanes/habilidades'), así que también se detecta acá
	por texto en vez de por keyword."""
	if not is_instance_valid(target):
		return false
	var text: String = target.get("card_ability") if target.get("card_ability") != null else ""
	var lower := text.to_lower()
	if "no puede ser afectad" in lower:
		return true
	for phrase in phrases:
		if phrase in lower:
			return true
	return false


func _execute_targeted_silence(card: Node) -> void:
	"""Silencia UN Aliado elegido por el jugador: pierde todas sus keywords
	(KeywordManager.silence_card) — 'silenciar' es solo el nombre interno,
	en Mitos y Leyendas el texto real dice 'pierde su habilidad' (DAR).
	Deja de disparar sus habilidades activadas/disparadas
	(KeywordManager.is_silenced(), consultado en _check_trigger_conditions()).
	Respeta protecciones explícitas del objetivo ('no puede perder su
	habilidad') e Inmune a Habilidades."""
	var chosen_target := await _select_ally_target("Elige un Aliado que pierda su habilidad", card)
	if not chosen_target or not is_instance_valid(chosen_target):
		return

	if _target_text_denies(chosen_target, ["no puede perder su habilidad", "no pierde su habilidad"]):
		var blocked_name: String = chosen_target.get("card_name") if chosen_target.get("card_name") != null else "Esa carta"
		var main_ui := _main.get_node_or_null("/root/Main")
		if main_ui:
			main_ui._update_debug("%s no puede perder su habilidad" % blocked_name)
		print("[TriggerSystem] Pérdida de habilidad bloqueada: %s tiene protección" % blocked_name)
		return

	KeywordManager.silence_card(chosen_target, card, "permanent")


func _execute_targeted_convert(card: Node, action: Dictionary) -> void:
	"""'Convertir un Oro o una carta de coste N o menos en una carta del
	mismo tipo sin habilidad' (DAR Sección 8 - Convertir, p.ej. Capitán
	O'Brien, 2026-08-28). Misma carta física — solo pierde la habilidad,
	conserva tipo/coste/Fuerza. Reusa el flag Card.is_converted (ya
	establecido por Signo Amarillo — ver ResponseWindowHandler.gd, es el
	que da el giro visual de 180° y "vacía" la caja de texto) más
	KeywordManager.silence_card() para que de verdad deje de disparar sus
	habilidades — is_converted por sí solo es solo visual, lo que consulta
	TriggerSystem._check_trigger_conditions() es is_silenced()."""
	var max_cost: int = action.get("params", {}).get("max_cost", 2)
	var chosen_target := await _select_convert_target(max_cost, card)
	if not chosen_target or not is_instance_valid(chosen_target):
		return

	if _target_text_denies(chosen_target, ["no puede ser convertida", "no puede ser convertido"]):
		var blocked_name: String = chosen_target.get("card_name") if chosen_target.get("card_name") != null else "Esa carta"
		var main_ui := _main.get_node_or_null("/root/Main")
		if main_ui:
			main_ui._update_debug("%s no puede ser convertida" % blocked_name)
		print("[TriggerSystem] Conversión bloqueada: %s tiene protección" % blocked_name)
		return

	chosen_target.is_converted = true
	KeywordManager.silence_card(chosen_target, card, "permanent")


func _select_convert_target(max_cost: int, source_card: Node = null) -> Node:
	"""Objetivo válido para Convertir: un Oro, o cualquier carta (Aliado,
	Tótem, Arma) de coste ≤ max_cost, EN JUEGO (propio o enemigo) — usa
	current_zone en vez de coincidir contenedor padre para que un Arma ya
	equipada (hija de su portador, no de una línea) también cuente.
	source_card (2026-08-30, p.ej. Aho) — excluye Aliados inmunes a esta
	fuente, ver _is_immune_to_enemy_ally."""
	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		push_warning("[TriggerSystem] No se pudo abrir selección de objetivo")
		return null

	var in_play_zones = [
		Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO,
		Constants.Zone.RESERVA_ORO, Constants.Zone.ORO_PAGADO,
	]
	var filter := func(c: Node) -> bool:
		if c.get("current_zone") not in in_play_zones:
			return false
		if _is_immune_to_enemy_ally(c, source_card):
			return false
		if c.get("card_type") == Constants.CardType.ORO:
			return true
		var cost = c.get("card_cost")
		return cost != null and int(cost) <= max_cost
	return await main._card_interaction.await_target(
		"Elige un Oro o una carta de coste %d o menos para Convertir" % max_cost, filter)


func _execute_targeted_search(card: Node, controller_id: int) -> void:
	"""Busca en el Castillo o Cementerio (DAR Sección 8): relee el texto
	completo de la carta (no solo el fragmento que capturó ABILITY_PATTERNS)
	para extraer zona, dueño de esa zona, tipo de carta buscado, cantidad
	(fija o 'por cada Aliado que controles'), destino (mano/Destierro) y si
	la carta encontrada se juega directamente pagando su coste."""
	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	var ability_lower := ability_text.to_lower()

	var zone := Constants.Zone.CASTILLO
	if "cementerio" in ability_lower:
		zone = Constants.Zone.CEMENTERIO

	# Dueño de la zona a buscar (2026-08-25): 'tu Castillo'/'tu Cementerio'
	# es siempre propio; 'Castillo/Cementerio de tu oponente' (o 'rival') es
	# siempre del rival; 'un Castillo' sin posesivo (p.ej. Rey de Amarillo)
	# es AMBIGUO — el jugador elige a cuál apunta.
	var opponent_id := 1 - controller_id
	var zone_owner := controller_id
	var owner_is_ambiguous := false
	if "oponente" in ability_lower or "rival" in ability_lower:
		zone_owner = opponent_id
	elif "tu castillo" in ability_lower or "tu cementerio" in ability_lower:
		zone_owner = controller_id
	elif "un castillo" in ability_lower or "un cementerio" in ability_lower:
		owner_is_ambiguous = true

	if owner_is_ambiguous and controller_id == 0:
		zone_owner = await _choose_search_zone_owner(controller_id, zone)
	elif owner_is_ambiguous:
		zone_owner = controller_id  # el bot no elige de verdad todavía — busca lo propio

	# Tipos mencionados (no 'elif' — 2026-08-22): "busca un Arma o un Oro"
	# (p.ej. Tyet) menciona DOS tipos válidos a la vez, un elif que corta en
	# el primero que encuentra (antes 'arma' ganaba siempre sobre 'oro')
	# dejaba la búsqueda incompleta.
	var wanted_types: Array = []
	if "aliado" in ability_lower:
		wanted_types.append(Constants.CardType.ALIADO)
	if "talismán" in ability_lower or "talisman" in ability_lower:
		wanted_types.append(Constants.CardType.TALISMAN)
	if "tótem" in ability_lower or "totem" in ability_lower:
		wanted_types.append(Constants.CardType.TOTEM)
	if "arma" in ability_lower:
		wanted_types.append(Constants.CardType.ARMA)
	if "oro" in ability_lower:
		wanted_types.append(Constants.CardType.ORO)

	var filter: Dictionary = {}
	if wanted_types.size() == 1:
		filter["type"] = wanted_types[0]
	elif wanted_types.size() > 1:
		filter["type"] = wanted_types

	# Cantidad: fija ("busca 2 cartas") o dinámica "una carta por cada
	# Aliado que controles (más N)" (2026-08-25, p.ej. Rey de Amarillo:
	# 'una carta por cada Aliado que controles más una').
	var amount := 1
	var per_ally_rx := RegEx.new()
	per_ally_rx.compile("por cada aliado que controles(?:\\s+m[aá]s\\s+(\\w+))?")
	var per_ally_match := per_ally_rx.search(ability_lower)
	if per_ally_match:
		amount = _count_allies_in_play(controller_id)
		var bonus_str := per_ally_match.get_string(1)
		if not bonus_str.is_empty():
			amount += UniversalCardParser._parse_amount(bonus_str)
	else:
		var amount_rx := RegEx.new()
		amount_rx.compile("busca (\\d+)")
		var amount_match := amount_rx.search(ability_lower)
		if amount_match:
			amount = int(amount_match.get_string(1))

	var may_play := (
		"puedes jugarla" in ability_lower
		or "puedes ponerla en juego" in ability_lower
		or "juégala" in ability_lower
		or "pagando su coste" in ability_lower
	)

	# Destino: Destierro directo si el texto lo dice (p.ej. 'y Destiérralas'),
	# Reserva de Oro directa si dice 'ponlo/ponla en tu Reserva' (2026-08-29,
	# p.ej. Don de Amma: 'busca un Oro en tu Castillo y ponlo en tu
	# Reserva' — va derecho a Reserva, no a la mano), si no, el default de
	# siempre (mano / juego con may_play).
	var destination := Constants.Zone.MANO
	if "destiérra" in ability_lower or "destierra" in ability_lower:
		destination = Constants.Zone.DESTIERRO
	elif "en tu reserva" in ability_lower or "en su reserva" in ability_lower:
		destination = Constants.Zone.RESERVA_ORO

	# 'de distinto nombre'/'distintos nombres' (2026-08-25, p.ej. necro-titan:
	# 'busca... dos cartas de distinto nombre') — no puede repetirse nombre
	# entre las elegidas.
	var distinct_names := "distinto nombre" in ability_lower or "distintos nombres" in ability_lower

	await ActionModule.search(zone_owner, zone, filter, amount, true, false, may_play, card, destination, distinct_names)


func _count_allies_in_play(player_id: int) -> int:
	"""Cuenta los Aliados que controla un jugador (Línea de Defensa +
	Ataque) — usado por cantidades dinámicas tipo 'por cada Aliado que
	controles' (2026-08-25)."""
	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return 0
	var fields = [main.player_field, main.player_linea_ataque] if player_id == 0 \
		else [main.opponent_field, main.opponent_linea_ataque]
	var count := 0
	for field in fields:
		if not field:
			continue
		for c in field.get_children():
			if c.get("card_type") == Constants.CardType.ALIADO:
				count += 1
	return count


func _choose_search_zone_owner(controller_id: int, zone: int) -> int:
	"""Elige a quién buscarle cuando el texto es ambiguo ('un Castillo', sin
	posesivo — p.ej. Rey de Amarillo) (2026-08-25). Para Castillo, click
	directo sobre el Panel del Castillo propio/rival en el tablero
	(2026-08-30, a pedido del usuario); Cementerio sigue con el popup de 2
	botones — no tiene un Panel fijo equivalente en el tablero. Devuelve el
	player_id elegido; declinar/cerrar = el propio."""
	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return controller_id
	var picked_own: bool
	if zone == Constants.Zone.CASTILLO:
		picked_own = await SelectionManager.await_castillo_pick(main, "¿En qué Castillo buscar?")
	else:
		var zone_name: String = "Cementerio"
		picked_own = await SelectionManager.await_two_choice(
			main, "¿En qué %s buscar?" % zone_name, "Tu %s" % zone_name, "%s del oponente" % zone_name)
	return controller_id if picked_own else 1 - controller_id


func _execute_targeted_return_to_deck(card: Node, controller_id: int) -> void:
	"""'Barajar' una carta EN JUEGO (DAR): vuelve al Castillo del elegido y
	el Castillo queda barajado de inmediato — no es 'pon en el fondo' seco,
	es 'vuelve a tu mazo y se baraja', tal como se describió."""
	var chosen_target := await _select_ally_target("Elige un Aliado para devolver al Castillo", card)
	if not chosen_target or not is_instance_valid(chosen_target):
		return

	var target_owner: int = chosen_target.get("controller_id") if chosen_target.get("controller_id") != null else controller_id
	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	var to_top: bool = "fondo del mazo" not in ability_text.to_lower()

	if not ActionModule.return_to_deck(chosen_target, target_owner, to_top):
		return

	CardManager.shuffle_deck(target_owner)


func _execute_shuffle_for_draw(action: Dictionary, controller_id: int) -> void:
	"""'Puedes Barajar cartas de tu mano cuyos costes sumen hasta N y Roba M
	cartas' (p.ej. Bernardo O'Higgins) — DAR: como dice 'puedes', el robo
	queda condicionado a barajar de verdad, no es gratis. Solo el jugador
	humano por ahora (controller_id == 0); el bot simplemente declina."""
	if controller_id != 0:
		return
	var params: Dictionary = action.get("params", {})
	var max_sum: int = params.get("max_cost_sum", 0)
	var draw_amount: int = params.get("draw_amount", 0)
	var main := _main.get_node_or_null("/root/Main")
	if not main or not main.player_hand:
		return
	var hand_cards: Array = main.player_hand.cards.duplicate()
	if hand_cards.is_empty():
		return

	var chosen := await _select_cards_by_cost_budget(hand_cards, max_sum,
		"Puedes barajar cartas cuyos costes sumen hasta %d para robar %d (confirma sin elegir para declinar)" % [max_sum, draw_amount])
	if chosen.is_empty():
		return

	for c in chosen:
		if not is_instance_valid(c):
			continue
		var idx = main.player_hand.cards.find(c)
		if idx >= 0:
			main.player_hand.cards.remove_at(idx)
		if c.get_parent() == main.player_hand:
			main.player_hand.remove_child(c)
		ActionModule.return_to_deck(c, controller_id, false)
	if main.player_hand.has_method("_arrange_cards"):
		main.player_hand._arrange_cards()

	CardManager.shuffle_deck(controller_id)
	await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)


func _select_cards_by_cost_budget(hand_cards: Array, max_sum: int, title: String) -> Array:
	"""Selección múltiple OPCIONAL (0 a N cartas) de la propia mano,
	validando que la suma de costes de lo elegido no supere max_sum.
	Reintenta si se pasa del presupuesto. Array vacío = el jugador declinó."""
	while true:
		var card_data_list: Array = []
		for c in hand_cards:
			if is_instance_valid(c):
				card_data_list.append(c.card_data)
		if card_data_list.is_empty():
			return []

		# state es Dictionary a propósito (2026-08-22): los lambdas de GDScript
		# capturan variables locales POR VALOR — reasignar 'picked_data'/
		# 'resolved'/'declined' DENTRO del lambda solo movía la copia local
		# del lambda, la de afuera nunca se enteraba y 'while not resolved'
		# colgaba para siempre en silencio (confirmado con un test aislado
		# en Godot).
		var state := {"resolved": false, "declined": false, "picked_data": []}
		var on_completed := func(cards: Array):
			state.picked_data = cards
			state.resolved = true
		var on_cancelled := func():
			state.declined = true
			state.resolved = true
		SelectionManager.selection_completed.connect(on_completed, CONNECT_ONE_SHOT)
		SelectionManager.selection_cancelled.connect(on_cancelled, CONNECT_ONE_SHOT)
		SelectionManager.open_selection(card_data_list, SelectionManager.SelectionMode.DISCARD, {
			"title": title,
			"max_selections": card_data_list.size(),
			"min_selections": 0,
			"can_cancel": true,
		})
		while not state.resolved:
			await _main.get_tree().process_frame
		if SelectionManager.selection_completed.is_connected(on_completed):
			SelectionManager.selection_completed.disconnect(on_completed)
		if SelectionManager.selection_cancelled.is_connected(on_cancelled):
			SelectionManager.selection_cancelled.disconnect(on_cancelled)

		if state.declined or state.picked_data.is_empty():
			return []

		var sum_cost := 0
		for d in state.picked_data:
			sum_cost += int(d.get("coste", d.get("cost", 0)))
		if sum_cost <= max_sum:
			var chosen_nodes: Array = []
			for data in state.picked_data:
				for c in hand_cards:
					if is_instance_valid(c) and c.card_data == data:
						chosen_nodes.append(c)
						break
			return chosen_nodes

		var main := _main.get_node_or_null("/root/Main")
		if main:
			main._update_debug("La suma de costes (%d) supera el máximo permitido (%d) — elige de nuevo" % [sum_cost, max_sum])
		# Inalcanzable en la práctica (el while true: solo sale por return),
		# pero el analizador de GDScript no lo sabe y exige un retorno
		# explícito al final de la función — sin esto: "Parse Error: Not all
		# code paths return a value" (confirmado con Godot --check-only).
	return []


func _execute_play_weapon_discount_draw(action: Dictionary, controller_id: int) -> void:
	"""'Puedes jugar un Arma desde tu mano o Cementerio reduciendo su coste
	en N Oros, hasta un mínimo de M, y Robar K cartas' (p.ej. Lobo Sagrado)
	— NO es "hasta" un Arma: jugarla es obligatorio para robar, el texto no
	permite jugar 0 Armas y robar igual (confirmado por el usuario,
	2026-08-26 — revertido un intento anterior de hacer el robo
	incondicional). Orden: primero se confirma que hay portador y qué Arma
	jugar; recién con eso resuelto se paga y se retira de su zona de
	origen, para que cancelar a mitad de camino no deje nada a medio mover
	ni cobre Oro de más.

	Variante 'hand_only' (p.ej. Hanta: 'puedes jugar un Arma de tu mano
	reduciendo su coste...' sin Cementerio ni robo) reusa toda esta lógica
	— solo cambia el origen elegible y si al final se roba o no."""
	if controller_id != 0:
		return
	var params: Dictionary = action.get("params", {})
	var discount: int = params.get("discount", 0)
	var floor_val: int = params.get("floor", 1)
	var draw_amount: int = params.get("draw_amount", 0)
	var hand_only: bool = params.get("hand_only", false)

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return

	var hand_weapons: Array = []
	for c in main.player_hand.cards:
		if is_instance_valid(c) and c.get("card_type") == Constants.CardType.ARMA:
			hand_weapons.append(c)
	var cemetery_weapons: Array = []
	if not hand_only:
		for d in CardManager.get_cemetery(controller_id):
			if d.get("tipo") == Constants.CardType.ARMA:
				cemetery_weapons.append(d)
	if hand_weapons.is_empty() and cemetery_weapons.is_empty():
		return

	var card_data_list: Array = []
	for c in hand_weapons:
		card_data_list.append(c.card_data)
	for d in cemetery_weapons:
		card_data_list.append(d)

	# Título corto (2026-08-26, a pedido del usuario — "más visual, menos
	# texto"): el botón Cancelar ya cubre "declinar", no hace falta
	# explicarlo en el título.
	var title: String = "Arma con -%d oro (mín %d), roba %d" % [discount, floor_val, draw_amount]
	if draw_amount <= 0:
		title = "Arma con -%d oro (mín %d)" % [discount, floor_val]
	var picked_data: Dictionary = await SelectionManager.await_single_pick(card_data_list, title, true, 0)
	if picked_data.is_empty():
		return

	# Portador ANTES de tocar el origen del Arma (mismo orden que GoldManager.play_card)
	var ally = await main._gold_manager._select_weapon_wielder()
	if not ally or not is_instance_valid(ally):
		return

	var weapon_node: Node = null
	var from_hand := false
	for c in hand_weapons:
		if is_instance_valid(c) and c.card_data == picked_data:
			weapon_node = c
			from_hand = true
			break
	if not weapon_node:
		weapon_node = main._create_card(picked_data, false)
		main._connect_card_signals(weapon_node)

	var applies_to_this_weapon := func(c: Node) -> bool:
		return c == weapon_node
	PaymentManager.agregar_modificador_coste(weapon_node, -discount, applies_to_this_weapon, floor_val <= 0)
	var coste_real: int = PaymentManager.calcular_coste_real(weapon_node)
	var puede_pagar: bool = PaymentManager.puede_jugar_carta(weapon_node, controller_id)
	PaymentManager.remover_modificador_coste(weapon_node)

	if not puede_pagar:
		main._update_debug("No puedes pagar el Arma con descuento (%d Oro)" % coste_real)
		if not from_hand:
			weapon_node.queue_free()
		return

	if from_hand:
		var idx = main.player_hand.cards.find(weapon_node)
		if idx >= 0:
			main.player_hand.cards.remove_at(idx)
		if weapon_node.get_parent() == main.player_hand:
			main.player_hand.remove_child(weapon_node)
	else:
		var cemetery: Array = CardManager.get_cemetery(controller_id)
		var cidx: int = cemetery.find(picked_data)
		if cidx >= 0:
			CardManager.remove_from_cemetery(controller_id, cidx)

	if coste_real > 0:
		var weapon_race: String = str(weapon_node.get("card_raza")) if weapon_node.get("card_raza") != null else ""
		await main._gold_manager.pagar_coste(coste_real, weapon_node.card_type, weapon_race, weapon_node.card_cost)
		PaymentManager.registrar_pago(coste_real)

	await main._gold_manager._equip_weapon(weapon_node, ally)

	if draw_amount > 0:
		await ActionModule.draw(controller_id, draw_amount, "etb_trigger", true)


func _execute_return_weapon_swap_free(controller_id: int) -> void:
	"""'Puedes subir un Arma que controles a la mano de su dueño para jugar
	un Arma del mismo o menor coste desde tu mano sin pagar su coste'
	(Padre de la Patria, 2026-08-28). Dos elecciones encadenadas: primero
	qué Arma equipada devolver, después qué Arma de la mano (coste ≤ la
	devuelta) jugar gratis con play_card_for_free() — mismo camino final
	que usan los patrones de LookAndPlayResolver."""
	if controller_id != 0:
		return
	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return

	var equipped_weapons: Array = []
	for field in [main.player_field, main.player_linea_ataque]:
		if not field:
			continue
		for ally in field.get_children():
			if not is_instance_valid(ally):
				continue
			var weapons = ally.get("equipped_weapons")
			if weapons is Array:
				for w in weapons:
					if is_instance_valid(w):
						equipped_weapons.append(w)
	if equipped_weapons.is_empty():
		return

	# Hace falta un Arma YA en la mano para que la habilidad tenga algo que
	# jugar gratis — sin esto no vale la pena ni ofrecer el "puedes"
	# (2026-08-28, a pedido del usuario, mismo criterio que Lobo Sagrado).
	var hand_weapons: Array = []
	for c in main.player_hand.cards:
		if is_instance_valid(c) and c.get("card_type") == Constants.CardType.ARMA:
			hand_weapons.append(c)
	if hand_weapons.is_empty():
		return

	# 1) Elegir qué Arma equipada devolver.
	var return_candidates: Array = equipped_weapons.map(func(w): return w.card_data)
	var picked1: Dictionary = await SelectionManager.await_single_pick(
		return_candidates, "Sube un Arma que controles a la mano de su dueño", true, 0)
	if picked1.is_empty():
		return

	var weapon_to_return: Node = null
	for w in equipped_weapons:
		if is_instance_valid(w) and w.card_data == picked1:
			weapon_to_return = w
			break
	if not weapon_to_return:
		return

	var returned_cost: int = int(weapon_to_return.card_cost) if weapon_to_return.get("card_cost") != null else 0
	_return_equipped_weapon_to_hand(weapon_to_return, main)

	# 2) Elegir qué Arma de la mano (coste ≤ la devuelta) jugar gratis. Debe
	# ser OTRA Arma, distinta de la que se acaba de devolver (2026-08-30, a
	# pedido del usuario) — weapon_to_return ya quedó insertada en
	# main.player_hand.cards por _return_equipped_weapon_to_hand() (línea de
	# arriba), así que sin esta exclusión aparecía como su propio candidato
	# válido (cualquier carta cumple costo ≤ su propio costo).
	var eligible_hand: Array = []
	for c in main.player_hand.cards:
		if is_instance_valid(c) and c != weapon_to_return and c.get("card_type") == Constants.CardType.ARMA and int(c.card_cost) <= returned_cost:
			eligible_hand.append(c)
	if eligible_hand.is_empty():
		main._update_debug("No tienes otra Arma de coste %d o menos en la mano" % returned_cost)
		return

	var eligible_data: Array = eligible_hand.map(func(c): return c.card_data)
	var picked2: Dictionary = await SelectionManager.await_single_pick(
		eligible_data, "Juega un Arma de coste %d o menos gratis" % returned_cost, true, 0)
	if picked2.is_empty():
		return

	await main._gold_manager.play_card_for_free(picked2)


func _return_equipped_weapon_to_hand(weapon: Node, main: Node) -> void:
	"""Desequipa 'weapon' de su Aliado portador y la manda a la mano —
	inserción directa (no player_hand.add_card()): _equip_weapon() nunca
	desconectó las señales card_hovered/card_clicked de HandManager al
	sacarla de la mano para equiparla (bypasea remove_card(), que sí las
	desconecta), así que siguen conectadas — add_card() volvería a
	conectarlas y Godot tira un error de 'señal ya conectada'."""
	var ally = weapon.get_parent()
	if ally and ally.get("equipped_weapons") is Array:
		ally.equipped_weapons.erase(weapon)
	if ally:
		ally.remove_child(weapon)
	weapon.can_interact = true
	weapon.set_zone(Constants.Zone.MANO)
	main.player_hand.cards.append(weapon)
	main.player_hand.add_child(weapon)
	main.player_hand._arrange_cards()


func _execute_targeted_annul(card: Node) -> void:
	"""Anula UN Aliado en juego elegido por el jugador (DAR): por defecto va
	al Cementerio, igual que cualquier destrucción — solo va al Destierro si
	el propio texto de ESTA carta lo dice explícitamente (p.ej. 'destiérralo
	en su lugar'). Resolución directa, sin ventana de respuesta (ver alcance
	acordado): no intercepta nada en la pila, actúa sobre algo que YA está
	en juego. Respeta protección explícita del objetivo ('esta carta no
	puede ser anulada') e Inmune a Habilidades."""
	var chosen_target := await _select_ally_target("Elige un Aliado para anular", card)
	if not chosen_target or not is_instance_valid(chosen_target):
		return

	if _target_text_denies(chosen_target, ["no puede ser anulad"]):
		var blocked_name: String = chosen_target.get("card_name") if chosen_target.get("card_name") != null else "Esa carta"
		var main_ui := _main.get_node_or_null("/root/Main")
		if main_ui:
			main_ui._update_debug("%s no puede ser anulada" % blocked_name)
		print("[TriggerSystem] Anular bloqueado: %s tiene protección" % blocked_name)
		return

	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	var ability_lower := ability_text.to_lower()
	var goes_to_banish := "destierr" in ability_lower or "destierro" in ability_lower

	if goes_to_banish:
		await ActionModule.banish([chosen_target], card, true)
	else:
		await ActionModule.destroy([chosen_target], card, true, true)


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
