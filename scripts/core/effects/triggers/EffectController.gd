extends Node
## EffectController - Procesa efectos de cartas sobre el mazo
## Implementa validación "En medida de lo posible" (DAR - regla general)
##
## ESTADO REAL (2026-08-17, ver docs/audit-2026-08-13.html hallazgo 2 y 4):
## Casi todo aquí abajo está gateado por _validate_board(), que depende de
## `game_board` (poblado solo por GameBoard.gd — código huérfano de un layout
## de tablero anterior, nunca adjunto a ningún nodo de la escena actual).
## Con fallback hacia CardManager (que SÍ está vivo y sincronizado con Main):
##   draw_cards(), mill_cards(), destroy_card(), exile_card()
## search_cards()/discard_cards()/return_to_deck()/return_to_hand()/
## shuffle_deck()/convert_card_type() y todo lo que colgaba exclusivamente de
## ellas se ELIMINARON (2026-08-17): auditadas función por función, cero
## llamadores en todo el proyecto — implementaciones duplicadas y abandonadas
## de lo que ActionModule.gd (el camino real: TriggerSystem →
## UniversalCardParser → ActionModule) ya hace de verdad. Antes de añadir un
## efecto nuevo, dale a game_board el mismo tratamiento que draw_cards/
## mill_cards/destroy_card/exile_card (fallback a CardManager) en vez de
## asumir que va a aparecer solo — pero solo si algo realmente lo va a llamar.

# =============================================================================
# SIGNALS - Efectos
# =============================================================================
signal effect_started(effect_name: String, player_id: int)
signal effect_completed(effect_name: String, player_id: int, result: Dictionary)
signal effect_failed(effect_name: String, player_id: int, reason: String)
signal player_defeated(player_id: int, reason: String)

# =============================================================================
# SIGNALS - Triggers (DAR 7.2, 7.3, 7.4)
# =============================================================================
# Eventos de cartas individuales (para TriggerSystem)
signal on_card_drawn(player_id: int, card: Node)
signal on_card_milled(player_id: int, card: Node, destination: int)
signal on_card_discarded(player_id: int, card: Node)
signal on_card_entered_play(player_id: int, card: Node, zone: int)
signal on_card_left_play(player_id: int, card: Node, from_zone: int)
signal on_card_destroyed(player_id: int, card: Node)
signal on_card_exiled(player_id: int, card: Node)
signal on_card_returned_to_hand(player_id: int, card: Node)
signal on_card_attacks(player_id: int, card: Node)  # DAR 5.3.1 — "cuando ataque"
signal on_card_returned_to_deck(player_id: int, card: Node, to_top: bool)

# =============================================================================
# REFERENCIAS
# =============================================================================
var game_board: Node = null


func _ready() -> void:
	if GameManager:
		GameManager.connect("game_board_ready", _on_game_board_ready)
		if GameManager.game_board:
			game_board = GameManager.game_board


func _on_game_board_ready(board: Node) -> void:
	game_board = board


# =============================================================================
# VALIDACIÓN "EN MEDIDA DE LO POSIBLE"
# =============================================================================
func _get_available_amount(requested: int, available: int) -> int:
	"""Retorna la cantidad que se puede procesar según 'En medida de lo posible'
	Si se piden 3 pero hay 2, procesa 2 sin error
	"""
	return mini(requested, available)


func _validate_board() -> bool:
	"""Verifica que el GameBoard esté disponible. Siempre devuelve false —
	game_board nunca se asigna (era el GameBoard.gd huérfano, eliminado) —
	y cada llamador ya tiene su propio fallback basado en CardManager para
	cuando esto pasa (ver draw_cards()/mill_cards()/etc). No es un error
	real: antes imprimía push_error() cada vez, como si algo hubiera
	fallado, cuando en realidad el fallback se ejecuta correctamente
	siempre — solo generaba ruido confuso en la consola."""
	return game_board != null


# =============================================================================
# 1. ROBAR CARTAS (DAR - Robo)
# =============================================================================
func draw_cards(player_id: int, amount: int) -> Dictionary:
	"""Roba cartas una a una del Castillo
	'En medida de lo posible': roba hasta que el mazo se vacíe
	DAR 2.1: Si intenta robar con mazo vacío, pierde

	Returns: {success: bool, cards_drawn: Array, deck_emptied: bool}
	"""
	var result = {
		"success": true,
		"cards_drawn": [],
		"deck_emptied": false,
		"requested": amount,
		"actual": 0
	}

	if not _validate_board():
		# El GameBoard legacy no está activo en la escena actual (ver
		# docs/audit-2026-08-13.html, hallazgo 2) — usar el camino real del
		# juego en su lugar en vez de fallar en silencio.
		return await _draw_cards_fallback(player_id, amount)

	emit_signal("effect_started", "draw_cards", player_id)

	for i in range(amount):
		var deck = game_board.get_cards_in_zone(Constants.Zone.CASTILLO, player_id)

		# Verificar mazo vacío ANTES de robar (condición de derrota)
		if deck.is_empty():
			print("[EffectController] Castillo vacío - Jugador %d pierde (DAR 2.1)" % (player_id + 1))
			result.deck_emptied = true
			emit_signal("player_defeated", player_id, "deck_empty")
			if GameManager:
				GameManager.player_loses(player_id, "deck_empty")
			break

		# Robar carta del tope
		var card = deck[0]
		game_board.move_card(card, Constants.Zone.MANO, player_id, true)
		result.cards_drawn.append(card)
		result.actual += 1

		# Emitir trigger para cada carta robada (DAR 7.2)
		emit_signal("on_card_drawn", player_id, card)

		# Pausa visual entre robos
		if i < amount - 1:
			await get_tree().create_timer(0.12).timeout

	print("[EffectController] Jugador %d robó %d/%d cartas" % [
		player_id + 1, result.actual, amount
	])

	emit_signal("effect_completed", "draw_cards", player_id, result)
	return result


func _draw_cards_fallback(player_id: int, amount: int) -> Dictionary:
	"""Fallback para robar cartas cuando no hay GameBoard legacy registrado.
	Usa Main/ZoneManager (el camino que realmente mueve cartas en la escena
	actual) en vez de fallar. Limitación conocida: como Main.draw_card() no
	devuelve el nodo de la carta robada, cards_drawn queda vacío y no se
	emite on_card_drawn por carta — cualquier trigger que dependa de esa
	señal específica no se disparará todavía. El conteo (actual/deck_emptied)
	sí es correcto."""
	var result = {
		"success": true,
		"cards_drawn": [],
		"deck_emptied": false,
		"requested": amount,
		"actual": 0
	}

	var main = get_node_or_null("/root/Main")
	if not main or not main.get("_zone_manager"):
		result.success = false
		emit_signal("effect_failed", "draw_cards", player_id, "no_main")
		return result

	emit_signal("effect_started", "draw_cards", player_id)

	for i in range(amount):
		var drew: bool = await main._zone_manager.draw_card(player_id)
		if not drew:
			result.deck_emptied = true
			break
		result.actual += 1
		if i < amount - 1:
			await get_tree().create_timer(0.12).timeout

	print("[EffectController] (fallback) Jugador %d robó %d/%d cartas" % [
		player_id + 1, result.actual, amount
	])

	emit_signal("effect_completed", "draw_cards", player_id, result)
	return result


# search_cards()/_card_matches_filter() eliminados (2026-08-17): cero
# llamadores en todo el proyecto — ActionModule.search() es la búsqueda real.
# =============================================================================
# 3. BOTAR CARTAS - MILL (DAR Sección 8 - Botar)
# =============================================================================
func mill_cards(player_id: int, amount: int, destination: int = Constants.Zone.CEMENTERIO) -> Dictionary:
	"""Bota cartas del tope del Castillo una a una
	'En medida de lo posible': bota hasta que el mazo se vacíe
	Nota: Botar NO causa derrota, solo robar (DAR 2.1)

	Returns: {success: bool, milled_cards: Array, actual: int}
	"""
	var result = {
		"success": true,
		"milled_cards": [],
		"requested": amount,
		"actual": 0,
		"destination": destination
	}

	if not _validate_board():
		# GameBoard legacy no disponible (docs/audit, hallazgo 2/4) — usar el
		# fallback basado en CardManager en vez de fallar en silencio.
		return await _mill_cards_fallback(player_id, amount, destination)

	# Validar destino
	if destination != Constants.Zone.CEMENTERIO and destination != Constants.Zone.DESTIERRO:
		destination = Constants.Zone.CEMENTERIO
		result.destination = destination

	emit_signal("effect_started", "mill_cards", player_id)

	var dest_name = Constants.ZONE_NAMES[destination]

	for i in range(amount):
		var deck = game_board.get_cards_in_zone(Constants.Zone.CASTILLO, player_id)

		# 'En medida de lo posible': si no hay más cartas, terminar sin error
		if deck.is_empty():
			print("[EffectController] Castillo vacío, no se pueden botar más cartas")
			break

		var card = deck[0]
		game_board.move_card(card, destination, player_id, true)
		result.milled_cards.append(card)
		result.actual += 1

		# Revelar carta botada (información pública)
		if card.has_method("flip_face_up"):
			card.flip_face_up()

		# Emitir trigger para cada carta botada (DAR 7.3)
		emit_signal("on_card_milled", player_id, card, destination)

		print("[EffectController] Botada: %s -> %s" % [
			card.card_name if card.get("card_name") else "Carta",
			dest_name
		])

		# Pausa visual
		if i < amount - 1:
			await get_tree().create_timer(0.1).timeout

	print("[EffectController] Jugador %d botó %d/%d cartas al %s" % [
		player_id + 1, result.actual, amount, dest_name
	])

	emit_signal("effect_completed", "mill_cards", player_id, result)
	return result


func _mill_cards_fallback(player_id: int, amount: int, destination: int) -> Dictionary:
	"""Fallback para botar cartas cuando no hay GameBoard legacy registrado.
	Usa CardManager (su deck/cementerio/destierro quedan sincronizados con
	Main por referencia compartida desde sync_from_main()) en vez de fallar
	en silencio. Limitación conocida: el Castillo no tiene nodos de Card
	individuales (solo un contador visual), así que milled_cards queda vacío
	y no se emite on_card_milled por carta — el conteo sí es correcto."""
	var result = {
		"success": true,
		"milled_cards": [],
		"requested": amount,
		"actual": 0,
		"destination": destination
	}

	emit_signal("effect_started", "mill_cards", player_id)

	if destination == Constants.Zone.DESTIERRO:
		var deck: Array = CardManager.get_deck(player_id)
		var exile: Array = CardManager.get_exile(player_id)
		for i in range(amount):
			if deck.is_empty():
				break
			var card_data: Dictionary = deck.pop_back()
			card_data["esta_oculta"] = false
			exile.append(card_data)
			result.actual += 1
		CardManager._emit_exile_changed(player_id)
		CardManager._emit_deck_changed(player_id)
	else:
		var dmg_result: Dictionary = CardManager.mill_cards(player_id, amount)
		result.actual = dmg_result.get("actual", 0)

	print("[EffectController] (fallback) Jugador %d botó %d/%d cartas al %s" % [
		player_id + 1, result.actual, amount, Constants.ZONE_NAMES.get(destination, "?")
	])

	emit_signal("effect_completed", "mill_cards", player_id, result)
	return result


# shuffle_deck()/discard_cards() eliminados (2026-08-17): cero llamadores
# en todo el proyecto. ActionModule.discard() es el descarte real; el
# barajado real lo hacen CardManager.shuffle_deck()/_zone_manager/GameManager
# directamente (varios sitios ya usan esos, no EffectController).
# =============================================================================
# 6/7. return_to_deck()/play_card_to_zone() eliminados (2026-08-17): cero
# llamadores en todo el proyecto. GoldManager._trigger_enter_play() ya
# documentaba por qué evita play_card_to_zone() (depende del game_board
# muerto) y mueve la carta directo — ver ese comentario para el camino real.
# =============================================================================
# 8. DESTRUIR CARTA (DAR 7.3 - Triggers de destrucción)
# =============================================================================
func destroy_card(player_id: int, card: Node) -> bool:
	"""Destruye una carta, enviándola al Cementerio (o al Destierro si fue
	exhumada, regla que respeta CardManager.destroy_card()).
	Emite on_card_left_play y on_card_destroyed.

	Returns: true si se destruyó
	"""
	if _try_consume_leave_play_prevention(player_id, card):
		return false

	# Guardar zona origen
	var from_zone = card.current_zone if card.get("current_zone") != null else -1

	# Verificar que está en juego
	if from_zone not in Constants.ZONES_IN_PLAY:
		push_warning("[EffectController] Carta no está en juego, no se puede destruir")
		return false

	# Notificar a la carta que deja el juego
	if card.has_method("on_left_play"):
		card.on_left_play()

	# Limpiar keywords temporales y cache (DAR Sección 8)
	KeywordManager.clear_all_for_card(card)

	# Limpiar datos de conversión si estaba convertida
	clear_conversion_on_leave(card)

	# Emitir trigger de salida del juego
	emit_signal("on_card_left_play", player_id, card, from_zone)

	# Mover al Cementerio
	if game_board:
		game_board.move_card(card, Constants.Zone.CEMENTERIO, player_id, true)
	else:
		# GameBoard legacy no disponible (docs/audit, hallazgo 2/4) — CardManager
		# ya respeta la regla de exhumación y mantiene los contadores de UI
		# sincronizados (a diferencia de game_board.move_card(), sí libera el
		# nodo — correcto, porque el Cementerio real solo muestra un contador).
		await CardManager.destroy_card(player_id, card)

	# Emitir trigger de destrucción
	emit_signal("on_card_destroyed", player_id, card)

	var card_name = card.card_name if card.get("card_name") else "Carta"
	print("[EffectController] %s fue destruida" % card_name)

	return true


# =============================================================================
# 9. DESTERRAR CARTA (DAR - Destierro)
# =============================================================================
func exile_card(player_id: int, card: Node, bypass_prevention: bool = false) -> bool:
	"""Destierra una carta, enviándola al Destierro
	Emite on_card_left_play (si estaba en juego) y on_card_exiled

	bypass_prevention (2026-08-28): true cuando desterrar ES el costo que el
	propio jugador eligió pagar (p.ej. 'Puedes Desterrarlo para...', Legión
	Paladín) — la Prevención protege contra remoción del RIVAL, no debe
	poder bloquear que pagues tu propio costo (y si el jugador tiene otra
	copia de la misma carta con una carga de Prevención ya activa, sin esto
	quedaría sin poder pagar el costo de la segunda nunca).

	Returns: true si se desterró
	"""
	if not bypass_prevention and _try_consume_leave_play_prevention(player_id, card):
		return false

	var from_zone = card.current_zone if card.get("current_zone") != null else -1

	# Si estaba en juego, notificar y emitir salida
	if from_zone in Constants.ZONES_IN_PLAY:
		if card.has_method("on_left_play"):
			card.on_left_play()

		# Limpiar keywords temporales y cache (DAR Sección 8)
		KeywordManager.clear_all_for_card(card)

		# Limpiar datos de conversión si estaba convertida
		clear_conversion_on_leave(card)

		emit_signal("on_card_left_play", player_id, card, from_zone)

	# Mover al Destierro
	if game_board:
		game_board.move_card(card, Constants.Zone.DESTIERRO, player_id, true)
	else:
		# GameBoard legacy no disponible (docs/audit, hallazgo 2/4)
		await CardManager.exile_card(player_id, card)

	# Emitir trigger de destierro
	emit_signal("on_card_exiled", player_id, card)

	var card_name = card.card_name if card.get("card_name") else "Carta"
	print("[EffectController] %s fue desterrada" % card_name)

	return true


# =============================================================================
# 10. return_to_hand() eliminado (2026-08-17): cero llamadores en todo el
# proyecto (Card.return_to_hand() es un método distinto y no relacionado —
# la animación de "volver a la posición" al cancelar un drag).
# =============================================================================
# 11. CONVERTIR TIPO DE CARTA (DAR Sección 8 - Convertir) — eliminado
# (2026-08-17): convert_card_type(), revert_card_type() y todo lo que
# colgaba exclusivamente de ellas (_validate_persistent_abilities,
# _unequip_weapon, _handle_zone_movement_on_conversion, can_use_ability,
# _update_card_faculties, _set_card_property, _register_conversion_duration,
# _on_turn_end_revert_conversion, _on_combat_end_revert_conversion,
# _revert_card_type, _notify_type_change, is_card_converted,
# get_original_type) tenían CERO llamadores en todo el proyecto — la
# palabra clave Convertir (DAR Sección 8) nunca se conectó a nada real. Se
# conserva clear_conversion_on_leave() (y _converted_cards) porque
# destroy_card()/exile_card() SÍ la llaman, aunque hoy sea un no-op — si
# se reimplementa Convertir en el futuro, ahí queda el punto de enganche.
# =============================================================================
var _converted_cards: Dictionary = {}


func clear_conversion_on_leave(card: Node) -> void:
	"""Limpia datos de conversión cuando una carta sale del juego"""
	if is_instance_valid(card):
		_converted_cards.erase(card.get_instance_id())


# =============================================================================
# PREVENCIÓN "SALE DEL JUEGO" (DAR - Utilizar Habilidades: Prevenir. P.ej.
# Legión Paladín: "Puedes Desterrarlo para prevenir que un Aliado que
# controles salga del juego", 2026-08-28)
# =============================================================================
## Cargas de Prevención por jugador — "prevenir" en el DAR no es una
## keyword fija (no existe "Escudo" como término del juego): es el mismo
## verbo que se usa para prevenir daño (DamageManager.add_damage_prevention)
## o prevenir que un efecto afecte a un Aliado, aplicado acá a "salir del
## juego". destroy_card()/exile_card() son el único choke point real de
## "salir del juego" en todo el proyecto (todo camino de remoción, incluido
## combate vía BattleManager y ActionModule.destroy(), termina llamando
## acá — verificado 2026-08-28), así que interceptar acá cubre TODOS los
## casos sin tener que tocar cada uno.
var _leave_play_preventions: Dictionary = {0: 0, 1: 0}


func add_leave_play_prevention(player_id: int, amount: int = 1) -> void:
	_leave_play_preventions[player_id] = _leave_play_preventions.get(player_id, 0) + amount
	print("[EffectController] Prevención 'sale del juego' +%d para J%d (total: %d)" % [
		amount, player_id + 1, _leave_play_preventions[player_id]
	])


## Inmunidad TEMPORAL de "no pueden salir del juego" para TODOS los Aliados
## de un jugador, con vencimiento por TURNO (no por carga) — distinto de
## _leave_play_preventions (cargas consumibles una por una). 2026-08-29,
## p.ej. Sherlock Holmes: "los Aliados que controlas no pueden salir del
## juego hasta tu próximo turno" — protege a TODOS a la vez, sin límite de
## cantidad, hasta que vuelva a empezar el turno de ese jugador.
var _blanket_leave_play_immunity: Dictionary = {0: false, 1: false}


func add_blanket_leave_play_immunity(player_id: int) -> void:
	"""Activa la inmunidad para TODOS los Aliados de player_id hasta que
	vuelva a empezar SU turno (GameManager.turn_started con ese player_id)."""
	if _blanket_leave_play_immunity.get(player_id, false):
		return  # Ya activa — no hace falta una segunda conexión
	_blanket_leave_play_immunity[player_id] = true
	print("[EffectController] Inmunidad de salida del juego activada para J%d (hasta su próximo turno)" % (player_id + 1))
	var clear_it: Callable
	clear_it = func(started_player_id: int, _turn: int) -> void:
		if started_player_id != player_id:
			return
		_blanket_leave_play_immunity[player_id] = false
		if GameManager.turn_started.is_connected(clear_it):
			GameManager.turn_started.disconnect(clear_it)
		print("[EffectController] Inmunidad de salida del juego terminó para J%d" % (player_id + 1))
	GameManager.turn_started.connect(clear_it)


## Inmunidad TEMPORAL de "no puede salir del juego" para UNA carta puntual
## (2026-08-30, p.ej. Garfio Pirata: "Cuando entra en juego, el portador no
## puede salir del juego hasta tu próximo turno") — distinta de
## _blanket_leave_play_immunity (esa protege a TODOS los Aliados de un
## jugador a la vez, no una carta elegida). {card_instance_id: true}
var _single_card_leave_play_immunity: Dictionary = {}


func add_single_card_leave_play_immunity(card: Node, player_id: int) -> void:
	"""Activa la inmunidad para ESTA carta hasta que vuelva a empezar el
	turno de player_id (el controlador de la fuente, no necesariamente el
	dueño de 'card' — DAR: la protección la otorga QUIEN controla el
	efecto)."""
	if not is_instance_valid(card):
		return
	var id := card.get_instance_id()
	if _single_card_leave_play_immunity.get(id, false):
		return  # ya activa — no hace falta una segunda conexión
	_single_card_leave_play_immunity[id] = true
	var card_name: String = str(card.get("card_name")) if card.get("card_name") != null else "Carta"
	print("[EffectController] Inmunidad de salida del juego activada para %s (hasta el próximo turno de J%d)" % [card_name, player_id + 1])
	var clear_it: Callable
	clear_it = func(started_player_id: int, _turn: int) -> void:
		if started_player_id != player_id:
			return
		_single_card_leave_play_immunity.erase(id)
		if GameManager.turn_started.is_connected(clear_it):
			GameManager.turn_started.disconnect(clear_it)
	GameManager.turn_started.connect(clear_it)


func _try_consume_leave_play_prevention(player_id: int, card: Node) -> bool:
	"""Solo previene la salida de Aliados (texto literal de Legión Paladín/
	Sherlock Holmes/Garfio Pirata). La inmunidad temporal en bloque (blanket)
	y la puntual por carta se revisan PRIMERO y no consumen nada — solo
	bloquean mientras estén activas. Si ninguna aplica, cae a las cargas de
	Prevención (_leave_play_preventions), que sí se consumen una por una.
	Cancela la salida del juego por completo — la carta queda exactamente
	como estaba, sin pasar por ningún otro paso de destroy_card/exile_card
	(on_left_play, limpieza de keywords, cambio de zona, etc.)."""
	if not is_instance_valid(card) or card.get("card_type") != Constants.CardType.ALIADO:
		return false
	if _blanket_leave_play_immunity.get(player_id, false):
		var card_name0: String = str(card.get("card_name")) if card.get("card_name") != null else "Aliado"
		print("[EffectController] %s no sale del juego (inmunidad temporal activa para J%d)" % [card_name0, player_id + 1])
		var main0 := get_node_or_null("/root/Main")
		if main0:
			main0._update_debug("%s: no puede salir del juego este turno" % card_name0)
		return true
	if _single_card_leave_play_immunity.get(card.get_instance_id(), false):
		var card_name1: String = str(card.get("card_name")) if card.get("card_name") != null else "Aliado"
		print("[EffectController] %s no sale del juego (inmunidad puntual activa)" % card_name1)
		var main1 := get_node_or_null("/root/Main")
		if main1:
			main1._update_debug("%s: no puede salir del juego este turno" % card_name1)
		return true
	if _leave_play_preventions.get(player_id, 0) <= 0:
		return false
	_leave_play_preventions[player_id] -= 1
	var card_name: String = str(card.get("card_name")) if card.get("card_name") != null else "Aliado"
	print("[EffectController] Prevención consumida: %s no sale del juego (quedan %d para J%d)" % [
		card_name, _leave_play_preventions[player_id], player_id + 1
	])
	var main := get_node_or_null("/root/Main")
	if main:
		main._update_debug("%s: se previno que saliera del juego" % card_name)
	return true


## "Puedes Desterrarla para prevenir que una carta sea afectada por un
## efecto oponente" (2026-08-30, Estaca) — cargas de protección POR CARTA
## puntual (no por jugador, a diferencia de _leave_play_preventions),
## consumibles una por una contra el PRÓXIMO efecto CON OBJETIVO de un
## jugador distinto al controlador de la carta protegida (anular, destruir,
## desterrar, debuff, silenciar — alcance confirmado por el usuario,
## 2026-08-30: NO cubre daño de combate normal ni auras pasivas).
## {card_instance_id: count}
var _opponent_effect_preventions: Dictionary = {}


func add_opponent_effect_prevention(card: Node) -> void:
	if not is_instance_valid(card):
		return
	var id := card.get_instance_id()
	_opponent_effect_preventions[id] = _opponent_effect_preventions.get(id, 0) + 1
	print("[EffectController] Protección contra efecto rival +1 para %s (total: %d)" % [
		str(card.get("card_name")) if card.get("card_name") != null else "Carta",
		_opponent_effect_preventions[id]
	])


func try_consume_opponent_effect_prevention(target: Node, source: Node) -> bool:
	"""Consume una carga de protección de 'target' si 'source' pertenece a
	un jugador distinto al controlador de 'target' — un efecto propio NUNCA
	gasta la protección. Returns true si bloqueó el efecto (el llamador
	debe abortar la acción sobre ESTE target puntual, sin afectar otros
	targets de la misma resolución)."""
	if not is_instance_valid(target):
		return false
	var id := target.get_instance_id()
	var charges: int = _opponent_effect_preventions.get(id, 0)
	if charges <= 0:
		return false
	var target_controller: int = target.controller_id if target.get("controller_id") != null else -1
	var source_controller: int = -2
	if source and is_instance_valid(source):
		source_controller = source.controller_id if source.get("controller_id") != null else -2
	if source_controller == target_controller:
		return false
	_opponent_effect_preventions[id] = charges - 1
	var card_name: String = str(target.get("card_name")) if target.get("card_name") != null else "Carta"
	print("[EffectController] Protección consumida: %s no fue afectada por el efecto rival (quedan %d)" % [
		card_name, _opponent_effect_preventions[id]
	])
	var main := get_node_or_null("/root/Main")
	if main:
		main._update_debug("%s: protegida de un efecto rival" % card_name)
	return true


## "Puedes convertirlo en un Oro sin habilidad para prevenir que una
## habilidad sea cancelada o un Aliado de coste 1 sea Anulado" (2026-08-30,
## Drácula) — carga POR JUGADOR (no por carta puntual, a diferencia de
## _opponent_effect_preventions: Drácula protege cualquier habilidad/Aliado
## propio, no una carta elegida de antemano), consumible contra CUALQUIERA
## de las dos amenazas, lo que ocurra primero. Opera sobre la pila
## (ActionPipeline/LinkedEffectRegistry), no sobre Nodos en juego, así que
## no puede reusar _opponent_effect_preventions (keyed por instance_id de
## Node).
var _stack_annul_cancel_preventions: Dictionary = {0: 0, 1: 0}


func add_stack_annul_cancel_prevention(player_id: int) -> void:
	_stack_annul_cancel_preventions[player_id] = _stack_annul_cancel_preventions.get(player_id, 0) + 1
	print("[EffectController] Prevención 'Cancelar/Anular en pila' +1 para J%d (total: %d)" % [
		player_id + 1, _stack_annul_cancel_preventions[player_id]
	])


func try_consume_stack_annul_cancel_prevention(player_id: int) -> bool:
	if _stack_annul_cancel_preventions.get(player_id, 0) <= 0:
		return false
	_stack_annul_cancel_preventions[player_id] -= 1
	print("[EffectController] Prevención 'Cancelar/Anular en pila' consumida para J%d (quedan %d)" % [
		player_id + 1, _stack_annul_cancel_preventions[player_id]
	])
	var main := get_node_or_null("/root/Main")
	if main:
		main._update_debug("Se previno una Cancelación/Anulación (Drácula)")
	return true
