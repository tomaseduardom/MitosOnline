extends EasyBotController
class_name RemotePlayerController
## RemotePlayerController — reemplaza a EasyBotController cuando el jugador 1
## es una PERSONA real conectada por red (NetworkClient), no una IA sin
## estrategia. Extiende EasyBotController y sobreescribe cada punto de
## DECISIÓN (Vigilia, Ataque, respuesta con habilidad activada) para que en
## vez de elegir al azar, le pregunte al Remoto por red y espere su
## respuesta — misma superficie pública que la clase base, así que ningún
## llamador existente (PhaseFlowController, ActionPipeline,
## ResponseWindowHandler, LookRevealPatternsA.gd — todos invocan
## `_main._easy_bot.<método>` sin saber qué hay del otro lado) necesitó
## cambiar una sola línea. Ver docs/plans/2026-09-09-multiplayer-remoto-
## design.md e iterative-booping-abelson.md (Fase B).
##
## Alcance de ESTE incremento (Fase B, "bucle de turno básico" — mismo techo
## que el bot hoy, pero una persona real detrás): poner Oro, jugar Aliados de
## la mano, declarar atacantes, responder ventanas con habilidades activadas
## sin costo de Descarte, y el mulligan inicial real (que hoy ni siquiera
## existe como decisión para el jugador 1). La paridad completa (cualquier
## carta, cualquier elección de SelectionManager) es Fase C, todavía no
## empezada — reset_gold()/_pay_oro_for_bot()/play_free_ally_from_data()/
## put_free_gold_in_pagado_from_data() se heredan tal cual de la clase base
## (no hay decisión real que preguntar en Agrupación, y los triggers "juega
## gratis" siguen sin alcanzar al jugador 1 por network hasta Fase C).
##
## Protocolo: cada método manda al Remoto un mensaje {"op":"prompt",
## "kind":...} con los datos que la persona necesita ver — su propia mano/
## campo NO está oculta para ella (aunque en la pantalla del Anfitrión se
## vea como 'oponente' con esta_oculta=true, eso es solo la vista LOCAL del
## Anfitrión) — y espera un {"op":"intent","kind":...} de vuelta. Las
## cartas se identifican por get_instance_id() (mismo criterio ya usado por
## turn_registry en otras partes del proyecto para distinguir copias
## físicas durante la sesión) — estable mientras el Node exista, no
## persiste entre partidas ni hace falta que persista.
##
## Decisión de alcance (2026-09-11, sin protocolo de instrucciones
## incremental completo todavía): en vez de streaming continuo de
## move_card/reveal_card por cada transición de zona (la forma "completa"
## descrita en el diseño), cada prompt de este archivo embebe un snapshot
## de los datos que el Remoto necesita en ESE momento (su propia mano/
## campo, más lo público). Esto respeta la niebla de guerra (nunca se
## manda la mano/mazo ocultos del Anfitrión) y alcanza para que el Remoto
## tome decisiones legales, pero significa que el Remoto no ve en tiempo
## real lo que el Anfitrión hace en SU PROPIO turno (recién se entera en el
## próximo prompt que le toque). El streaming incremental completo (fidelidad
## visual total) queda pendiente — ver nota en el plan.

func _await_intent(expected_kinds: Array) -> Dictionary:
	"""Espera el próximo {"op":"intent","kind":X,...} con X en expected_kinds.
	Sin timeout — mismo criterio que el resto del motor espera a un jugador
	humano local (SelectionManager). Si la conexión se cae mientras se
	espera, esto queda colgado para siempre — aceptable en v1 (el diseño ya
	decidió 'sin reconexión, la partida termina', pero mostrar un aviso claro
	acá en vez de quedar mudo es una mejora pendiente, no bloqueante)."""
	while true:
		var data = await NetworkClient.message_received
		if data.get("op", "") == "intent" and data.get("kind", "") in expected_kinds:
			return data
	# Inalcanzable en la práctica (el while true: solo sale por return), pero
	# el analizador de GDScript no lo sabe y exige un retorno explícito al
	# final de la función — mismo patrón ya usado en
	# WeaponSearchShuffleExecutor._select_cards_by_cost_budget().
	return {}


func _card_ref(card: Node) -> String:
	return str(card.get_instance_id())


func _find_card_by_id(id_str: String) -> Node:
	if id_str.is_empty() or not id_str.is_valid_int():
		return null
	var obj: Object = instance_from_id(int(id_str))
	if obj is Node and is_instance_valid(obj):
		return obj as Node
	return null


func _card_public_data(card: Node) -> Dictionary:
	"""Datos de UNA carta propia del Remoto para mandarle por red — no está
	oculta para su propio dueño, aunque en la pantalla del Anfitrión se vea
	con esta_oculta=true (eso es solo la vista LOCAL del Anfitrión, no un
	límite real de información para la persona a la que pertenece)."""
	if not is_instance_valid(card):
		return {}
	return {
		"card_id": _card_ref(card),
		"nombre": str(card.get("card_name")) if card.get("card_name") != null else "",
		"coste": int(card.get("card_cost")) if card.get("card_cost") != null else 0,
		"tipo": int(card.get("card_type")) if card.get("card_type") != null else -1,
		"habilidad": str(card.get("card_ability")) if card.get("card_ability") != null else "",
	}


# =============================================================================
# MULLIGAN (2026-09-11 — no existe llamador base: MulliganController._end_
# mulligan_phase() llama acá directo, con chequeo de tipo, solo si hay un
# Remoto conectado; si no, sigue con draw_initial_hand() como siempre)
# =============================================================================
func run_mulligan(initial_count: int) -> void:
	"""Mulligan real para el jugador 1: dibuja la mano, le pregunta al Remoto
	si la mantiene o la vuelve a barajar (con una carta menos, como cualquier
	mulligan DAR), hasta que mantenga o llegue a 0."""
	var count := initial_count
	while true:
		for i in range(count):
			await _main._zone_manager.draw_card(1, false)
		var hand_cards: Array = _main._opponent_fan.get_cards().duplicate()
		var hand_data: Array = []
		for c in hand_cards:
			if is_instance_valid(c):
				hand_data.append(_card_public_data(c))

		NetworkClient.send_message({"op": "prompt", "kind": "mulligan", "hand": hand_data})
		var intent: Dictionary = await _await_intent(["mulligan_choice"])

		if intent.get("keep", true) or count - 1 <= 0:
			return

		for c in hand_cards:
			if is_instance_valid(c):
				var data: Dictionary = c.card_data.duplicate()
				data["esta_oculta"] = true
				_main._opponent_fan.remove_card(c, true)
				_main.opponent_deck.append(data)
		_main._zone_manager.shuffle_deck(1)
		count -= 1


# =============================================================================
# VIGILIA — igual que la base, pero cada acción la elige el Remoto por red
# =============================================================================
func take_vigilia_actions() -> void:
	if not _main._opponent_fan:
		return
	while true:
		if not (GameManager.is_game_active and GameManager.active_player_id == 1 \
				and GameManager.current_phase == Constants.Phase.VIGILIA):
			return

		var gold_candidates: Array = []
		for c in _main._opponent_fan.get_cards():
			if not is_instance_valid(c) or c.get("card_type") != Constants.CardType.ORO:
				continue
			if not TurnManager.can_place_oro(GameManager.current_phase, c):
				continue
			if _main._gold_manager and (_main._gold_manager._no_more_cards_violation(c) \
					or _main._gold_manager._card_play_locked(c)):
				continue
			gold_candidates.append(_card_public_data(c))

		var ally_candidates: Array = []
		for c in _affordable_allies_in_hand():
			ally_candidates.append(_card_public_data(c))

		var hand_data: Array = []
		for c in _main._opponent_fan.get_cards():
			if is_instance_valid(c):
				hand_data.append(_card_public_data(c))

		NetworkClient.send_message({
			"op": "prompt", "kind": "vigilia",
			"hand": hand_data,
			"gold_candidates": gold_candidates,
			"ally_candidates": ally_candidates,
			"gold_reserva": GameState.get_oro_reserva(1),
		})
		var intent: Dictionary = await _await_intent(["place_gold", "play_card", "end_vigilia"])

		match intent.get("kind", ""):
			"place_gold":
				var card := _find_card_by_id(str(intent.get("card_id", "")))
				if card and is_instance_valid(card) and card.get("card_type") == Constants.CardType.ORO:
					await _place_gold_card(card)
			"play_card":
				var card := _find_card_by_id(str(intent.get("card_id", "")))
				if card and is_instance_valid(card) and card.get("card_type") == Constants.CardType.ALIADO:
					await _play_ally(card)
			"end_vigilia":
				if GameManager.is_game_active and GameManager.active_player_id == 1 \
						and GameManager.current_phase == Constants.Phase.VIGILIA:
					_main._update_debug("Oponente ataca")
					GameManager.proceed_to_battle()
				return
			_:
				return


# =============================================================================
# ATAQUE — el Remoto elige QUIÉNES atacan (en vez del 50% al azar del bot)
# =============================================================================
func take_ataque_actions() -> void:
	if not (GameManager.is_game_active and GameManager.active_player_id == 1 \
			and GameManager.current_phase == Constants.Phase.ATAQUE):
		return

	var attackable: Array = []
	if _main.opponent_field:
		for ally in _main.opponent_field.get_children():
			if not is_instance_valid(ally):
				continue
			var check: Dictionary = TurnManager.can_attack(ally)
			if check.get("can_attack", false):
				attackable.append(ally)

	var payload: Array = []
	for a in attackable:
		payload.append(_card_public_data(a))
	NetworkClient.send_message({"op": "prompt", "kind": "ataque", "attackable": payload})
	var intent: Dictionary = await _await_intent(["declare_attackers"])

	if _main._card_interaction:
		var chosen_ids: Array = intent.get("card_ids", [])
		for id_str in chosen_ids:
			var ally := _find_card_by_id(str(id_str))
			if ally and ally in attackable:
				await _main._card_interaction._declare_attacker(ally)

	if GameManager.is_game_active and GameManager.active_player_id == 1 \
			and GameManager.current_phase == Constants.Phase.ATAQUE:
		_main._update_debug("Oponente confirma atacantes")
		await GameManager.confirm_attackers()


# =============================================================================
# CAPA 2 DE LA PILA DE RESPUESTA UNIVERSAL — responder con una habilidad
# activada, elegida por el Remoto en vez de al azar
# =============================================================================
func try_respond_with_activated_ability() -> bool:
	var fields: Array = [_main.opponent_field, _main.opponent_linea_ataque, _main.opponent_linea_apoyo,
		_main.opponent_gold, _main.opponent_oro_pagado]
	var candidates: Array = []  # [{card, ability}]
	for field in fields:
		if not field:
			continue
		for card in field.get_children():
			if not is_instance_valid(card) or KeywordManager.is_silenced(card):
				continue
			var ability_text: String = str(card.card_ability) if card.get("card_ability") != null else ""
			if ability_text.is_empty():
				continue
			var abilities: Array[Dictionary] = UniversalCardParser.parse_abilities(ability_text, str(card.get_instance_id()))
			for ability in abilities:
				if ability.get("ability_type", "") != "ACTIVATED":
					continue
				var cost_type = ability.get("cost_type", UniversalCardParser.CostType.NONE)
				# A diferencia de la IA (que se limita a NONE/ONCE_PER_TURN/
				# GOLD/TAP), acá se ofrecen todas salvo Descarte — el Remoto
				# todavía no tiene su mano representada como Nodos del lado
				# del pago (mismo hueco ya documentado para el bot).
				if cost_type == UniversalCardParser.CostType.DISCARD:
					continue
				if cost_type == UniversalCardParser.CostType.GOLD and not GameState.puede_pagar(1, ability.get("cost_amount", 0)):
					continue
				if cost_type == UniversalCardParser.CostType.TAP and card.get("is_tapped") == true:
					continue
				if ability.get("once_per_turn", false) or cost_type == UniversalCardParser.CostType.ONCE_PER_TURN:
					var card_id: String = str(card.get_instance_id())
					if UniversalCardParser.turn_registry.was_used(card_id, ability.get("ability_index", 0), GameManager.current_turn):
						continue
				candidates.append({"card": card, "ability": ability})

	var candidate_payload: Array = []
	for c in candidates:
		candidate_payload.append({
			"card_id": _card_ref(c.card),
			"ability_index": c.ability.get("ability_index", 0),
			"cost_text": c.ability.get("cost_text", ""),
			"effect_text": c.ability.get("effect_text", ""),
		})
	NetworkClient.send_message({"op": "prompt", "kind": "response_window", "candidates": candidate_payload})
	var intent: Dictionary = await _await_intent(["activate_ability", "pass"])

	if intent.get("kind", "") != "activate_ability":
		return false

	var chosen_card := _find_card_by_id(str(intent.get("card_id", "")))
	if not chosen_card:
		return false
	var ability_index: int = int(intent.get("ability_index", -1))
	var chosen_ability: Dictionary = {}
	for c in candidates:
		if c.card == chosen_card and int(c.ability.get("ability_index", -1)) == ability_index:
			chosen_ability = c.ability
			break
	if chosen_ability.is_empty():
		return false

	var context := {"controller_id": 1, "source_card_node": chosen_card}
	var result: Dictionary = await ActionPipeline.activate_ability(chosen_card.card_data, chosen_ability, context)
	return result.get("success", false)
