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
## Dividido en dos slices más por tamaño (2026-09-06, "módulos gordos"):
## WeaponSearchShuffleExecutor.gd (cluster compuesto Buscar/Barajar-para-robar/
## Arma-con-descuento) y MiscTargetedPatterns.gd (patrones sueltos:
## búsqueda de Cementerio a mano, destierro combinado de ambos Cementerios,
## refresco visual de "pierde habilidad" por nombre). El dispatcher
## (execute_parsed_action) y el toolkit genérico de selección de UN objetivo
## (_select_*_target, _target_text_denies, _choose_search_zone_owner,
## _select_hand_cards_for_discard, y los _execute_targeted_* de un solo
## objetivo) se quedaron AQUÍ sin extraer a propósito: es el cluster de mayor
## tráfico externo de todo este archivo (decenas de call sites en
## PreventionAbilityHandler_*.gd, SearchAbilityHandler_*.gd,
## BanishOpponentPatterns.gd, GoldConversionPatterns.gd,
## LookRevealPatterns.gd, ShuffleDrawPatterns.gd, SearchOwnZonePatterns.gd,
## TriggerResolution.gd), así que moverlo no reducía riesgo — solo lo
## concentraba en otro archivo.

const WeaponSearchShuffleExecutorScript = preload("res://scripts/core/effects/triggers/WeaponSearchShuffleExecutor.gd")
const MiscTargetedPatternsScript = preload("res://scripts/core/effects/triggers/MiscTargetedPatterns.gd")

var _main: Node
var _weapon_search: RefCounted
var _misc: RefCounted


func setup(main: Node) -> void:
	_main = main
	_weapon_search = WeaponSearchShuffleExecutorScript.new()
	_weapon_search.setup(main)
	_misc = MiscTargetedPatternsScript.new()
	_misc.setup(main)


func _resolve_search_cemetery_to_hand(controller_id: int, max_amount: int, type_filter: Array = []) -> bool:
	return await _misc._resolve_search_cemetery_to_hand(controller_id, max_amount, type_filter)


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
			await _weapon_search._execute_targeted_search(card, controller_id)

		"RETURN_DECK":
			await _execute_targeted_return_to_deck(card, controller_id)

		"SHUFFLE_FOR_DRAW":
			await _weapon_search._execute_shuffle_for_draw(action, controller_id, card)

		"PLAY_WEAPON_DISCOUNT_DRAW", "PLAY_WEAPON_DISCOUNT":
			await _weapon_search._execute_play_weapon_discount_draw(action, controller_id, card)

		"RETURN_WEAPON_SWAP_FREE":
			await _weapon_search._execute_return_weapon_swap_free(controller_id, card)

		"CONVERT_ORO_OR_LOW_COST":
			await _execute_targeted_convert(card, action)

		"LOOK":
			# Cartas simples "Mira N cartas del tope" sin el patrón compuesto
			# de elegir 1 a mano / 1 a Cementerio (ese lo resuelve
			# try_execute_look_pick_pattern() antes de llegar aquí) — solo
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
			# A diferencia de LOOK, aquí SÍ hay que barajar después (2026-08-26,
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


func _select_ally_target(prompt: String, source_card: Node = null, chooser_id: int = 0) -> Node:
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
		# 2026-09-12: current_zone en vez de get_parent() (ver §10.5)
		if c.get("current_zone") not in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE]:
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
		# "No pueden ser afectados por habilidades de cartas fuera del
		# juego mientras atacan" (2026-09-03, Trono del Dragón, condicional
		# a 3+ Aliados de la misma Raza — la parte racial ya la resuelve el
		# condition Callable del modificador PROTECTION registrado en
		# ContinuousEffectManager). 'Mientras atacan' es un estado POR
		# CARTA que no tiene sentido meter en ese Callable (no recibe el
		# objetivo), así que se chequea aquí, en el único punto real donde
		# se elige un objetivo para una habilidad de OTRA carta. 'Fuera del
		# juego' = la fuente de ESTE efecto está en Mano/Destierro/
		# Cementerio/Castillo (mismo criterio ya usado para Signo Amarillo,
		# ver ResponseWindowHandler.gd/TriggerResolution.gd).
		if source_card:
			var source_zone = source_card.get("current_zone")
			var off_board_zones = [Constants.Zone.MANO, Constants.Zone.DESTIERRO, Constants.Zone.CEMENTERIO, Constants.Zone.CASTILLO]
			if source_zone in off_board_zones and c in GameManager.attackers \
					and ContinuousEffectManager.has_protection(c, "OFF_BOARD_WHILE_ATTACKING"):
				return false
		return true
	return await main._card_interaction.await_target(prompt, filter, true, chooser_id)


func _select_annul_target_cost_filter(prompt: String, max_cost: int, chooser_id: int = 0) -> Node:
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
		# 2026-09-12: current_zone en vez de get_parent() (ver §10.5)
		if c.get("current_zone") not in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO]:
			return false
		# get_modified_cost(), no card_cost crudo (2026-09-04) — ver nota en
		# _select_convert_target() más arriba.
		return ContinuousEffectManager.get_modified_cost(c) <= max_cost
	return await main._card_interaction.await_target(prompt, filter, true, chooser_id)


func _select_destroy_target_cost_filter(prompt: String, max_cost: int, chooser_id: int = 0) -> Node:
	"""Como _select_banish_target_cost_filter() pero para Destruir (va al
	Cementerio) — 2026-09-04, p.ej. gran kraken: 'Destruir una carta de
	coste 3 o menos'."""
	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		return null
	var filter := func(c: Node) -> bool:
		if c.get("card_type") not in [Constants.CardType.ALIADO, Constants.CardType.ARMA, Constants.CardType.TOTEM]:
			return false
		# 2026-09-12: current_zone en vez de get_parent() (ver §10.5)
		if c.get("current_zone") not in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO]:
			return false
		return ContinuousEffectManager.get_modified_cost(c) <= max_cost
	return await main._card_interaction.await_target(prompt, filter, true, chooser_id)


func _select_banish_target_cost_filter(prompt: String, max_cost: int, chooser_id: int = 0) -> Node:
	"""Como _select_annul_target_cost_filter() pero para Desterrar (en vez de
	Anular/destruir) — 2026-09-04, p.ej. akuma el terrible: 'Destierra una
	carta de coste 2 o menos'. Mismo alcance (Aliados/Armas/Tótems en
	cualquier zona de campo de ambos jugadores, filtro por coste efectivo)."""
	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		return null
	var filter := func(c: Node) -> bool:
		if c.get("card_type") not in [Constants.CardType.ALIADO, Constants.CardType.ARMA, Constants.CardType.TOTEM]:
			return false
		# 2026-09-12: current_zone en vez de get_parent() (ver §10.5)
		if c.get("current_zone") not in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO]:
			return false
		return ContinuousEffectManager.get_modified_cost(c) <= max_cost
	return await main._card_interaction.await_target(prompt, filter, true, chooser_id)


func _select_ally_or_totem_target(prompt: String, chooser_id: int = 0) -> Node:
	"""Como _select_ally_target() pero incluye Tótems además de Aliados —
	2026-08-30, p.ej. Aho: 'Destierra un Aliado o Tótem'. Cualquiera de los
	dos jugadores, en cualquiera de sus tres zonas de campo."""
	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		return null
	var filter := func(c: Node) -> bool:
		if c.get("card_type") not in [Constants.CardType.ALIADO, Constants.CardType.TOTEM]:
			return false
		# 2026-09-12: current_zone en vez de get_parent() (ver §10.5)
		if c.get("current_zone") not in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO]:
			return false
		return true
	return await main._card_interaction.await_target(prompt, filter, true, chooser_id)


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


func _execute_targeted_buff(action: Dictionary, card: Node, controller_id: int, amount: int) -> void:
	"""Modifica la Fuerza de UN Aliado elegido por el jugador (DAR 7.2).
	Los Aliados tienen un único indicador de Fuerza (que también es su vida/
	resistencia) — no hay par ataque/defensa. El modificador se registra en
	ContinuousEffectManager — BattleManager._get_strength() ya lo consulta,
	así que se refleja de inmediato en el cálculo de combate."""
	var is_debuff: bool = action.get("type", "") == "DEBUFF"
	var value: int = -amount if is_debuff else amount
	var sign := "-" if is_debuff else "+"
	var chosen_target := await _select_ally_target("Elige un Aliado: %s%d de Fuerza" % [sign, amount], card, controller_id)

	if not chosen_target or not is_instance_valid(chosen_target):
		return

	# Prevención reactiva real (2026-09-09 — Estaca) — solo aplica a debuffs
	# (un buff no es un efecto hostil que valga la pena bloquear).
	if is_debuff and await EffectController.offer_prevention(chosen_target, card, "debuff"):
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
	var destroy_chooser: int = int(card.get("controller_id")) if card.get("controller_id") != null else 0
	var chosen_target := await _select_ally_target("Elige un Aliado para destruir", card, destroy_chooser)
	if not chosen_target or not is_instance_valid(chosen_target):
		return
	await ActionModule.destroy([chosen_target], card, true, true)


func _execute_targeted_banish(card: Node) -> void:
	"""Destierra UN Aliado en juego elegido por el jugador — va a Destierro,
	no se puede recuperar por medios normales (DAR Sección 8)."""
	var banish_chooser: int = int(card.get("controller_id")) if card.get("controller_id") != null else 0
	var chosen_target := await _select_ally_target("Elige un Aliado para desterrar", card, banish_chooser)
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
	# Descartar no está cubierto por el sistema de Prevención de hoy (sus
	# tags son destroy/exile/leave_play/silence/annul/cancel/debuff/
	# strength_change) — sí le corresponde la ventana genérica.
	if await TriggerSystem.open_response_window(card, str(card.card_name), controller_id):
		return

	await ActionModule.discard(target_player, to_discard, "etb_trigger", true)


func _resolve_banish_from_both_cemeteries(max_amount: int, card: Node = null, controller_id: int = 0) -> void:
	await _misc._resolve_banish_from_both_cemeteries(max_amount, card, controller_id)


func _select_hand_cards_for_discard(hand_cards: Array, amount: int, chooser_id: int = 0) -> Array:
	"""Pide al jugador humano elegir qué cartas descartar de su propia mano —
	click directo sobre las cartas reales (2026-09-13, a pedido del usuario,
	ver arquitectura.md §10.16), en vez del modal de lista viejo. Costo TODO
	o NADA de 'amount' cartas exactas (mismo criterio que Belta, §10.19):
	si el jugador elige menos (ESC), se devuelve Array vacío — ningún
	llamador de los 6 que reusan esta función debe tratar un resultado
	parcial como válido."""
	# 2026-09-14, bug real reportado por el usuario: _main aquí ES TriggerSystem
	# (ver TriggerSystem._ready(): '_targeted_executor.setup(self)'), no el
	# Main real — _main._card_interaction tiraba 'Invalid access to property
	# or key' porque esa propiedad no existe en TriggerSystem.gd (mismo
	# patrón de bug documentado en arquitectura.md §2). El resto de esta
	# clase ya resuelve esto bien con 'var main := _main.get_node_or_null(
	# "/root/Main")' antes de usar main._card_interaction (ver _select_
	# banish_target_cost_filter() más arriba) — esta función se saltó ese
	# paso.
	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		return []
	# cancellable=false (2026-09-13): este descarte es MANDATORIO (sin
	# "puedes" en las llamadoras) — ESC no debe dejar al jugador esquivarlo,
	# a diferencia del resto de conversiones de esta sesión que sí son
	# costos opcionales.
	var chosen: Array = await main._card_interaction.await_multi_target(
		"Descarta %d carta(s)" % amount, hand_cards, amount, Callable(), Callable(), false, null, chooser_id)
	if chosen.size() < amount:
		return []
	return chosen


func _target_text_denies(target: Node, phrases: Array) -> bool:
	"""Verifica si el propio texto de la carta OBJETIVO la protege
	explícitamente contra un efecto ('esta carta no puede ser anulada',
	'no puede perder su habilidad', etc.). 'Inmune a X' no es una keyword
	fija en Mitos y Leyendas — es texto libre de cada carta ('no puede ser
	afectada por talismanes/habilidades'), así que también se detecta aquí
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
	var silence_chooser: int = int(card.get("controller_id")) if card.get("controller_id") != null else 0
	var chosen_target := await _select_ally_target("Elige un Aliado que pierda su habilidad", card, silence_chooser)
	if not chosen_target or not is_instance_valid(chosen_target):
		return

	if _target_text_denies(chosen_target, ["no puede perder su habilidad", "no pierde su habilidad"]):
		var blocked_name: String = chosen_target.get("card_name") if chosen_target.get("card_name") != null else "Esa carta"
		var main_ui := _main.get_node_or_null("/root/Main")
		if main_ui:
			main_ui._update_debug("%s no puede perder su habilidad" % blocked_name)
		print("[TriggerSystem] Pérdida de habilidad bloqueada: %s tiene protección" % blocked_name)
		return

	await KeywordManager.silence_card(chosen_target, card, "permanent")


func _execute_targeted_convert(card: Node, action: Dictionary) -> void:
	"""'Convertir un Oro o una carta de coste N o menos en una carta del
	mismo tipo sin habilidad' (DAR Sección 8 - Convertir, p.ej. Capitán
	O'Brien, 2026-08-28). Misma carta física — solo pierde la habilidad,
	conserva tipo/coste/Fuerza. Reusa el flag Card.is_converted (ya
	establecido por Signo Amarillo — ver ResponseWindowHandler.gd, es el
	que da el giro visual de 180° y "vacía" la caja de texto) más
	await KeywordManager.silence_card() para que de verdad deje de disparar sus
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
	await KeywordManager.silence_card(chosen_target, card, "permanent")


func _select_convert_target(max_cost: int, source_card: Node = null, chooser_id: int = 0) -> Node:
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
		if max_cost < 0:
			return false  # sentinel: solo Oro es objetivo válido (p.ej. Mariano Osorio)
		# get_modified_cost(), no card_cost crudo (2026-09-04, a pedido del
		# usuario): una carta YA EN JUEGO puede tener su coste reducido de
		# forma continua (p.ej. Samael, 'las cartas oponentes en juego
		# reducen su coste en un Oro') — el filtro tiene que verlo.
		return ContinuousEffectManager.get_modified_cost(c) <= max_cost

	# Chequeo defensivo ANTES de abrir la selección (2026-09-03, bug
	# reportado: sin ningún Oro en juego en ese momento — max_cost=-1
	# sentinel, solo Oro qualifica — el picker se abría de todos modos con
	# CERO candidatos posibles, dejando is_selecting_target pegado para
	# siempre; el jugador ni siquiera podía declarar atacantes después,
	# porque cada click le caía a este filtro colgado. Mismo criterio ya
	# aplicado a _select_weapon_wielder()/_get_eligible_weapon_wielders()."""
	var has_candidate := false
	for field in [main.player_field, main.player_linea_ataque, main.player_linea_apoyo,
			main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo,
			main.player_gold, main.opponent_gold, main.player_oro_pagado, main.opponent_oro_pagado]:
		if not field:
			continue
		for c in field.get_children():
			if is_instance_valid(c) and filter.call(c):
				has_candidate = true
				break
		if has_candidate:
			break
	if not has_candidate:
		main._update_debug("No hay ningún objetivo válido para Convertir")
		return null

	var prompt: String = "Elige un Oro para Convertir" if max_cost < 0 \
		else "Elige un Oro o una carta de coste %d o menos para Convertir" % max_cost
	return await main._card_interaction.await_target(prompt, filter, true, chooser_id)


func _count_allies_in_play(player_id: int) -> int:
	return _weapon_search._count_allies_in_play(player_id)


func _choose_search_zone_owner(controller_id: int, zone: int, action_verb: String = "buscar") -> int:
	"""Elige a quién buscarle cuando el texto es ambiguo ('un Castillo', sin
	posesivo — p.ej. Rey de Amarillo) (2026-08-25). Para Castillo, click
	directo sobre el Panel del Castillo propio/rival en el tablero
	(2026-08-30, a pedido del usuario); Cementerio sigue con el popup de 2
	botones — no tiene un Panel fijo equivalente en el tablero. Devuelve el
	player_id elegido; declinar/cerrar = el propio.
	'action_verb' personaliza el texto del prompt (2026-09-06, bug real
	reportado por el usuario: Sherlock Holmes CONVIERTE cartas del tope de
	un Castillo, no las busca — el prompt genérico decía 'buscar' igual,
	confundiendo la acción real)."""
	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return controller_id
	var picked_own: bool
	if zone == Constants.Zone.CASTILLO:
		picked_own = await SelectionManager.await_castillo_pick(main, "¿En qué Castillo %s?" % action_verb)
	else:
		var zone_name: String = "Cementerio"
		picked_own = await SelectionManager.await_two_choice(
			main, "¿En qué %s %s?" % [zone_name, action_verb], "Tu %s" % zone_name, "%s del oponente" % zone_name, controller_id)
	return controller_id if picked_own else 1 - controller_id


func _execute_targeted_return_to_deck(card: Node, controller_id: int) -> void:
	"""'Barajar' una carta EN JUEGO (DAR): vuelve al Castillo del elegido y
	el Castillo queda barajado de inmediato — no es 'pon en el fondo' seco,
	es 'vuelve a tu mazo y se baraja', tal como se describió."""
	var chosen_target := await _select_ally_target("Elige un Aliado para devolver al Castillo", card, controller_id)
	if not chosen_target or not is_instance_valid(chosen_target):
		return

	var target_owner: int = chosen_target.get("controller_id") if chosen_target.get("controller_id") != null else controller_id
	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	var to_top: bool = "fondo del mazo" not in ability_text.to_lower()

	if not await ActionModule.return_to_deck(chosen_target, target_owner, to_top, card):
		return

	CardManager.shuffle_deck(target_owner)


func _return_equipped_weapon_to_hand(weapon: Node, main: Node) -> void:
	_weapon_search._return_equipped_weapon_to_hand(weapon, main)


func _execute_targeted_annul(card: Node) -> void:
	"""Anula UN Aliado en juego elegido por el jugador (DAR): por defecto va
	al Cementerio, igual que cualquier destrucción — solo va al Destierro si
	el propio texto de ESTA carta lo dice explícitamente (p.ej. 'destiérralo
	en su lugar'). Resolución directa, sin ventana de respuesta (ver alcance
	acordado): no intercepta nada en la pila, actúa sobre algo que YA está
	en juego. Respeta protección explícita del objetivo ('esta carta no
	puede ser anulada') e Inmune a Habilidades."""
	var annul_chooser: int = int(card.get("controller_id")) if card.get("controller_id") != null else 0
	var chosen_target := await _select_ally_target("Elige un Aliado para anular", card, annul_chooser)
	if not chosen_target or not is_instance_valid(chosen_target):
		return

	# Protección otorgada por OTRA carta (2026-09-02, Crono Diamante: "tu
	# primer Aliado o Tótem de coste 2 o más no puede ser Anulado") — a
	# diferencia de _target_text_denies(), que solo mira el texto propio
	# del objetivo, esto es un flag que GoldManager._apply_crono_diamante_
	# annul_protection() marcó al jugarlo, si su controlador tenía Crono
	# Diamante en Reserva en ese momento.
	if _target_text_denies(chosen_target, ["no puede ser anulad"]) or chosen_target.get_meta("protected_from_annul_this_turn", false):
		var blocked_name: String = chosen_target.get("card_name") if chosen_target.get("card_name") != null else "Esa carta"
		var main_ui := _main.get_node_or_null("/root/Main")
		if main_ui:
			main_ui._update_debug("%s no puede ser anulada" % blocked_name)
		print("[TriggerSystem] Anular bloqueado: %s tiene protección" % blocked_name)
		return

	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	var ability_lower := ability_text.to_lower()
	# "destiérralo"/"destiérrala" (2026-09-08, mismo hueco encontrado en
	# GoldManager._play_talisman(): el pronombre enclítico "-lo"/"-la" pegado
	# al verbo lleva tilde en español correcto, y "destierr" sin tilde no
	# matchea esa forma) — se agrega "destiérr" por las dudas, igual que ahí.
	var goes_to_banish := "destierr" in ability_lower or "destierro" in ability_lower or "destiérr" in ability_lower

	# Anular solo lo previene Drácula (tag "annul", con su propio chequeo de
	# coste 1 en el registro), NUNCA Estaca — su propio texto no cubre
	# Anular/Cancelar (2026-09-09, bug real de alcance encontrado en
	# auditoría: antes esto pasaba por destroy()/banish() con
	# can_be_prevented=true, dejando que Estaca bloqueara una Anulación por
	# accidente). can_be_prevented=false en los dos llamados de abajo para
	# que el chequeo genérico de "destroy"/"exile" no vuelva a preguntar.
	if await EffectController.offer_prevention(chosen_target, card, "annul"):
		return

	if goes_to_banish:
		await ActionModule.banish([chosen_target], card, true, false)
	else:
		await ActionModule.destroy([chosen_target], card, false, true)


func _refresh_rotation_for_name(main: Node, card_name: String) -> void:
	_misc._refresh_rotation_for_name(main, card_name)
