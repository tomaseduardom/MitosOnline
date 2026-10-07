extends Node
## CardManager - Singleton que gestiona el movimiento de cartas entre zonas
## Centraliza la lógica de deck, mano, cementerio y destierro

# =============================================================================
# SEÑALES
# =============================================================================
signal card_drawn(player_id: int, card_data: Dictionary)
signal card_discarded(player_id: int, card_data: Dictionary)
signal card_destroyed(player_id: int, card: Node)
signal card_exiled(player_id: int, card: Node)
signal damage_taken(player_id: int, amount: int, cards_milled: Array)
signal deck_empty(player_id: int)
signal zone_changed(card: Node, from_zone: int, to_zone: int, player_id: int)

# Señales para actualización de UI (contadores)
signal deck_count_changed(player_id: int, new_count: int)
signal hand_count_changed(player_id: int, new_count: int)
signal cemetery_count_changed(player_id: int, new_count: int)
signal exile_count_changed(player_id: int, new_count: int)
signal field_count_changed(player_id: int, new_count: int)

# =============================================================================
# REFERENCIAS
# =============================================================================
var _main: Node = null  # Referencia a Main.gd (se obtiene dinámicamente)

# =============================================================================
# DATOS DE ZONAS (por jugador)
# =============================================================================
# Estructura: { player_id: { zone: data } }
var _zones: Dictionary = {
	0: {
		"deck": [],        # Array[Dictionary] - datos de cartas
		"hand": [],        # Array[Node] - instancias de Card
		"field": [],       # Array[Node] - aliados en juego
		"cemetery": [],    # Array[Dictionary] - datos de cartas destruidas
		"exile": [],       # Array[Dictionary] - datos de cartas desterradas
		"gold": [],        # Array[Node] - oros en reserva
		"gold_paid": []    # Array[Node] - oros pagados este turno
	},
	1: {
		"deck": [],
		"hand": [],
		"field": [],
		"cemetery": [],
		"exile": [],
		"gold": [],
		"gold_paid": []
	}
}

## "las cartas que estén o sean puestas en los Cementerios este turno pierden
## su habilidad hasta tu próximo turno" (2026-08-30, Sable de Napoleón) —
## mientras esté true, cualquier carta que entre a CUALQUIER Cementerio
## (ver _append_to_cemetery()) queda marcada como silenciada también. Se
## apaga sola al empezar el próximo turno (turno del rival), ver
## silence_all_cemetery_cards().
var _cemetery_silence_capture_active: bool = false

# =============================================================================
# INICIALIZACIÓN
# =============================================================================
func _ready() -> void:
	print("[CardManager] Inicializado")


func _get_main() -> Node:
	"""Obtiene referencia a Main.gd de forma lazy"""
	if not _main or not is_instance_valid(_main):
		_main = get_tree().current_scene if get_tree() else null
	return _main


# =============================================================================
# SINCRONIZACIÓN CON MAIN.GD
# =============================================================================
func sync_from_main() -> void:
	"""Sincroniza los datos desde Main.gd (llamar al inicio del juego)"""
	var main = _get_main()
	if not main:
		push_warning("[CardManager] Main.gd no disponible para sincronizar")
		return

	# Sincronizar decks
	if main.get("player_deck"):
		_zones[0].deck = main.player_deck
	if main.get("opponent_deck"):
		_zones[1].deck = main.opponent_deck

	# Sincronizar cementerios
	if main.get("player_cemetery"):
		_zones[0].cemetery = main.player_cemetery
	if main.get("opponent_cemetery"):
		_zones[1].cemetery = main.opponent_cemetery

	print("[CardManager] Sincronizado - Deck P0: %d, Deck P1: %d" % [
		_zones[0].deck.size(), _zones[1].deck.size()
	])


func sync_to_main() -> void:
	"""Sincroniza los datos de vuelta a Main.gd"""
	var main = _get_main()
	if not main:
		return

	if main.get("player_deck") != null:
		main.player_deck = _zones[0].deck
	if main.get("opponent_deck") != null:
		main.opponent_deck = _zones[1].deck
	if main.get("player_cemetery") != null:
		main.player_cemetery = _zones[0].cemetery
	if main.get("opponent_cemetery") != null:
		main.opponent_cemetery = _zones[1].cemetery


# =============================================================================
# ACCESO A ZONAS
# =============================================================================
func get_deck(player_id: int) -> Array:
	"""Obtiene el mazo de un jugador"""
	return _zones[player_id].deck


func get_hand(player_id: int) -> Array:
	"""Obtiene la mano de un jugador (instancias)"""
	return _zones[player_id].hand


func get_cemetery(player_id: int) -> Array:
	"""Obtiene el cementerio de un jugador"""
	return _zones[player_id].cemetery


func get_exile(player_id: int) -> Array:
	"""Obtiene el destierro de un jugador"""
	return _zones[player_id].exile


func get_field(player_id: int) -> Array:
	"""Obtiene los aliados en campo de un jugador"""
	return _zones[player_id].field


func get_deck_count(player_id: int) -> int:
	"""Obtiene el número de cartas en el mazo"""
	return _zones[player_id].deck.size()


func get_hand_count(player_id: int) -> int:
	"""Obtiene el número de cartas en mano"""
	return _zones[player_id].hand.size()


func get_cemetery_count(player_id: int) -> int:
	"""Obtiene el número de cartas en cementerio"""
	return _zones[player_id].cemetery.size()


func get_exile_count(player_id: int) -> int:
	"""Obtiene el número de cartas en destierro"""
	return _zones[player_id].exile.size()



# =============================================================================
# MOVIMIENTO DE CARTAS - DECK
# =============================================================================
func draw_card(player_id: int) -> Dictionary:
	"""Roba una carta del tope del mazo

	Returns: Datos de la carta robada, o {} si el mazo está vacío
	"""
	var deck = _zones[player_id].deck

	if deck.is_empty():
		emit_signal("deck_empty", player_id)
		return {}

	# Robar del tope (último elemento = tope del mazo)
	var card_data = deck.pop_back()

	emit_signal("card_drawn", player_id, card_data)
	_update_deck_visual(player_id)

	return card_data


func draw_cards(player_id: int, count: int) -> Array:
	"""Roba múltiples cartas del mazo

	Returns: Array de datos de cartas robadas
	"""
	var drawn: Array = []

	for i in range(count):
		var card_data = draw_card(player_id)
		if card_data.is_empty():
			break
		drawn.append(card_data)

	return drawn


func add_to_deck_top(player_id: int, card_data: Dictionary) -> void:
	"""Añade una carta al tope del mazo.

	Convención real del tope (2026-08-30, corregido — estaba al revés): el
	camino de robo que de verdad se usa en la partida es ZoneManager.
	draw_card(), que hace _main.player_deck.pop_front() — el FRENTE del
	array (índice 0) es el tope. _zones[player_id].deck es el MISMO array
	que _main.player_deck (ver sync_from_main(): asignación directa, no una
	copia), así que esta función tiene que insertar al frente para que
	'tope' signifique lo mismo aquí que en el robo real. draw_card() de este
	mismo archivo (más arriba) usa pop_back() y NUNCA se llama desde
	ningún lado — quedó con la convención vieja/incorrecta, no se tocó
	porque no tiene ningún llamador real que arreglar."""
	_zones[player_id].deck.insert(0, card_data)
	_update_deck_visual(player_id)


func add_to_deck_bottom(player_id: int, card_data: Dictionary) -> void:
	"""Añade una carta al fondo del mazo (ver nota de convención en
	add_to_deck_top() — fondo = el otro extremo del array real de robo)."""
	_zones[player_id].deck.append(card_data)
	_update_deck_visual(player_id)


func shuffle_deck(player_id: int) -> void:
	"""Baraja el mazo de un jugador"""
	_zones[player_id].deck.shuffle()
	print("[CardManager] Mazo de jugador %d barajado" % player_id)


func add_to_exile(player_id: int, card_data: Dictionary) -> void:
	"""Añade datos de una carta directo al Destierro (2026-08-25) — para
	efectos que la mandan ahí sin pasar por una carta en juego (p.ej. Rey de
	Amarillo: busca en un Castillo y Destiérralas directo, sin llevárselas a
	la mano primero)."""
	card_data["esta_oculta"] = false
	_zones[player_id].exile.append(card_data)
	_emit_exile_changed(player_id)


# =============================================================================
# MOVIMIENTO DE CARTAS - MANO
# =============================================================================
func add_to_hand(player_id: int, card: Node) -> void:
	"""Añade una instancia de carta a la mano"""
	_zones[player_id].hand.append(card)
	emit_signal("zone_changed", card, -1, Constants.Zone.MANO, player_id)


func remove_from_hand(player_id: int, card: Node) -> bool:
	"""Remueve una carta de la mano

	Returns: true si se removió exitosamente
	"""
	var hand = _zones[player_id].hand
	var idx = hand.find(card)

	if idx >= 0:
		hand.remove_at(idx)
		return true
	return false


func discard_from_hand(player_id: int, card: Node) -> void:
	"""Descarta una carta de la mano al cementerio"""
	if remove_from_hand(player_id, card):
		# Guardar datos antes de destruir el nodo
		var card_data = card.card_data.duplicate() if card.get("card_data") else {}
		card_data["esta_oculta"] = false
		_append_to_cemetery(player_id, card_data)

		emit_signal("card_discarded", player_id, card_data)
		emit_signal("zone_changed", card, Constants.Zone.MANO, Constants.Zone.CEMENTERIO, player_id)

		_update_cemetery_visual(player_id)

		var main_node = Engine.get_main_loop().root.get_node_or_null("Main") if Engine.get_main_loop() else null
		if main_node and main_node.get("_zone_manager") != null and is_instance_valid(card) and card.is_inside_tree() and card.visible:
			await main_node._zone_manager.animate_card_to_cemetery(card, player_id)

		_disconnect_card_interaction_signals(card)
		card.queue_free()


# =============================================================================
# MOVIMIENTO DE CARTAS - CEMENTERIO
# =============================================================================
func _append_to_cemetery(player_id: int, card_data: Dictionary) -> void:
	"""Choke point único para agregar una entrada a un Cementerio (2026-08-30)
	— antes cada llamador hacía _zones[player_id].cemetery.append(card_data)
	por su cuenta; se centraliza aquí para que la 'captura' de Sable de
	Napoleón (silenciar cartas que entren al Cementerio durante la ventana
	activa) no dependa de tocar cada llamador por separado."""
	if _cemetery_silence_capture_active:
		card_data["_silenced_by_cemetery_effect"] = true
	_zones[player_id].cemetery.append(card_data)


func is_cemetery_card_silenced(card_data: Dictionary) -> bool:
	"""'Pierde su habilidad' para una carta EN CEMENTERIO (2026-08-30, Sable
	de Napoleón) — KeywordManager._silenced_cards es por instance_id de un
	Node vivo, no aplica a datos de Cementerio (Dictionary puro), así que
	esto vive aquí, junto con el dato mismo."""
	return card_data.get("_silenced_by_cemetery_effect", false)


func silence_all_cemetery_cards(activator_player_id: int) -> void:
	"""'Las cartas que estén o sean puestas en los Cementerios este turno
	pierden su habilidad hasta tu próximo turno' (Sable de Napoleón,
	2026-08-30). 'los Cementerios' sin posesivo = AMBOS (mismo criterio ya
	confirmado para 'un Cementerio' de Miguel). Dos ventanas de tiempo
	DISTINTAS:
	  1) La CAPTURA de nuevas entradas dura 'este turno' — se apaga sola en
	     cuanto empiece cualquier otro turno (CONNECT_ONE_SHOT, sin
	     importar de quién sea: no puedes volver a tu propio turno sin que
	     pase el del rival primero).
	  2) El SILENCIO en sí dura 'hasta tu próximo turno' (el de
	     activator_player_id específicamente, no el del rival que viene
	     primero) — se levanta solo cuando vuelva a empezar SU turno."""
	for player_id in [0, 1]:
		for card_data in _zones[player_id].cemetery:
			card_data["_silenced_by_cemetery_effect"] = true
	_cemetery_silence_capture_active = true

	GameManager.turn_started.connect(
		func(_p, _t): _cemetery_silence_capture_active = false,
		CONNECT_ONE_SHOT
	)

	var clear_silence: Callable
	clear_silence = func(started_player_id: int, _turn: int) -> void:
		if started_player_id != activator_player_id:
			return
		for player_id in [0, 1]:
			for card_data in _zones[player_id].cemetery:
				card_data.erase("_silenced_by_cemetery_effect")
		if GameManager.turn_started.is_connected(clear_silence):
			GameManager.turn_started.disconnect(clear_silence)
	GameManager.turn_started.connect(clear_silence)


func add_to_cemetery(player_id: int, card_data: Dictionary) -> void:
	"""Añade datos de carta al cementerio (desde mazo o efecto)"""
	card_data["esta_oculta"] = false
	_append_to_cemetery(player_id, card_data)
	_update_cemetery_visual(player_id)


func add_card_to_cemetery(player_id: int, card: Node) -> void:
	"""Mueve una instancia de carta al cementerio (la destruye)
	NOTA: Usar destroy_card() para respetar la regla de exhumación
	"""
	var card_data = card.card_data.duplicate() if card.get("card_data") else {}
	card_data["esta_oculta"] = false
	_append_to_cemetery(player_id, card_data)

	emit_signal("card_destroyed", player_id, card)
	_update_cemetery_visual(player_id)

	_disconnect_card_interaction_signals(card)
	card.queue_free()


func _unequip_from_wielder(card: Node) -> void:
	"""2026-09-19, bug real reportado por el usuario ('Trying to assign
	invalid previously freed instance', ZoneManager.gd:535 — desterrando un
	Arma equipada con Bernardo O'Higgins). _move_equipped_weapons_with()
	(arriba) cubre la dirección 'el portador sale del juego, el Arma lo
	sigue' — pero la dirección contraria (el ARMA MISMA sale del juego
	directo, con su portador quedándose en juego) nunca limpiaba
	wielder.equipped_weapons antes de queue_free(). equipped_weapons es un
	Array genérico sin tipar, pero la lectura `var w: Node =
	card.equipped_weapons[w_idx]` en ZoneManager.compact_field_slots() SÍ
	está typada — asignar ahí la referencia ya liberada del
	Arma es justo lo que Godot rechaza con ese error, la próxima vez que
	cualquier acción recompactara el campo (compact_all_fields(), llamado
	DEFERRED dos líneas más abajo en destroy_card()/exile_card(), así que
	nunca fallaba en el mismo frame — el crash aparecía en la próxima
	recompactación real). Llamar ANTES de queue_free() en ambas funciones."""
	if not is_instance_valid(card):
		return
	var wielder: Node = card.get("wielder")
	if wielder and is_instance_valid(wielder):
		var weapons = wielder.get("equipped_weapons")
		if weapons is Array:
			weapons.erase(card)


func _move_equipped_weapons_with(player_id: int, card: Node, mover: Callable) -> void:
	"""El Arma sigue a su portador al mismo destino (DAR — no queda suelta en
	juego). Se llama ANTES de queue_free() en destroy_card()/exile_card(),
	pasándose a sí misma (mover) como la función a aplicar a cada Arma.
	Excepción (2026-08-30, p.ej. Aho: 'Cuando el portador fuera a salir del
	juego, súbela a tu mano o cámbiala de portador') — un Arma con ese texto
	NO sigue al portador, el jugador elige entre las dos alternativas."""
	if not card.get("equipped_weapons"):
		return
	for weapon in card.equipped_weapons.duplicate():
		if not is_instance_valid(weapon):
			continue
		if player_id == 0 and _weapon_survives_wielder_death(weapon):
			await _resolve_weapon_survives_wielder(weapon)
			continue
		await mover.call(player_id, weapon)


func _weapon_survives_wielder_death(weapon: Node) -> bool:
	"""2026-08-31: se ancla también en 'bela a tu mano' (sin la 'sú' acentuada
	inicial) — la API de cartas puede traer el texto con la doble-
	codificación UTF-8→Latin-1→UTF-8 típica en vocales acentuadas (mismo
	problema ya conocido y corregido aparte en GoldManager._fix_mojibake(),
	p.ej. 'TalismÃ¡n' en vez de 'Talismán'); si 'súbela' llega corrupto aquí
	el check anterior (que exigía el acento exacto) fallaba en silencio y
	Aho terminaba siguiendo a su portador al Cementerio/Destierro en vez de
	ofrecer la elección real."""
	var text: String = str(weapon.get("card_ability")) if weapon.get("card_ability") != null else ""
	var lower := text.to_lower()
	return "portador fuera a salir del juego" in lower and "bela a tu mano" in lower


func _resolve_weapon_survives_wielder(weapon: Node) -> void:
	"""'Cuando el portador fuera a salir del juego, súbela a tu mano o
	cámbiala de portador' (2026-08-30, p.ej. Aho) — reemplaza la regla por
	defecto de que un Arma sigue a su portador al Cementerio/Destierro.
	Solo el jugador humano elige por ahora (mover_placeholder del bot, ver
	llamador: para el rival se sigue aplicando la regla vieja hasta que
	haya IA para esta decisión)."""
	var main := get_node_or_null("/root/Main")
	if not main:
		return

	# Popup mínimo de 2 botones (mismo patrón que TargetedEffectExecutor.
	# _choose_search_zone_owner()) — si no hay otro Aliado libre para
	# portarla (GoldManager._get_eligible_weapon_wielders(), ya excluye
	# solo el portador que se está muriendo porque ÉL SÍ 'tiene un Arma' en
	# este instante — todavía no se soltó — y a cualquier otro que ya porte
	# una distinta), la única alternativa real es subirla a la mano.
	var other_wielders: Array = []
	if main._gold_manager and main._gold_manager.has_method("_get_eligible_weapon_wielders"):
		other_wielders = main._gold_manager._get_eligible_weapon_wielders()

	var to_hand := true
	if not other_wielders.is_empty():
		to_hand = await SelectionManager.await_two_choice(
			main, "%s: ¿Subir a tu mano o cambiar de portador?" % str(weapon.get("card_name")),
			"Subir a la mano", "Cambiar de portador")

	if to_hand:
		var weapon_parent = weapon.get_parent()
		if weapon_parent:
			weapon_parent.remove_child(weapon)
		weapon.can_interact = true
		weapon.scale = Vector2.ONE
		weapon.base_scale = Vector2.ONE
		weapon.z_index = 0
		weapon.original_z_index = 0
		weapon.set_zone(Constants.Zone.MANO)
		main.player_hand.add_card(weapon)
		return

	var new_wielder: Node = null
	if main._card_interaction:
		var filter := func(c: Node) -> bool:
			return c in other_wielders
		new_wielder = await main._card_interaction.await_target(
			"Elige qué Aliado porta %s ahora" % str(weapon.get("card_name")), filter)
	if not new_wielder or not is_instance_valid(new_wielder):
		# Canceló sin elegir — no queda otra que subirla a la mano igual,
		# no puede quedar suelta en juego sin portador (DAR).
		await _resolve_weapon_survives_wielder(weapon)
		return
	if main._gold_manager and main._gold_manager.has_method("_equip_weapon"):
		# fire_enter_play=false (2026-09-25, ver comentario en _equip_weapon()):
		# el Arma ya estaba en juego, solo cambia de portador porque el
		# anterior murió — no es un juego nuevo, no debe re-disparar 'Cuando
		# entra en juego' ni sumar al conteo de cartas jugadas este turno.
		await main._gold_manager._equip_weapon(weapon, new_wielder, false)


func _disconnect_card_interaction_signals(card: Node) -> void:
	"""Desconecta TODAS las conexiones de las señales de interacción de una
	carta antes de queue_free() (2026-08-29) — sin esto, un hover/click que
	sigue apuntando al nodo después de liberarlo tira 'Invalid access...
	on a base object of type previously freed' al tocar .modulate en el
	próximo evento de mouse (reportado con Don de Amma desterrándose a sí
	mismo desde su Reserva). HandManager.remove_card() ya hacía esta
	desconexión para cartas en la MANO, pero destroy_card()/exile_card()
	aquí abajo son el camino real de TODA destrucción/destierro sin
	GameBoard (siempre null en este proyecto) — cartas en Reserva/Oro
	Pagado/líneas de juego, conectadas por Main._connect_card_signals(),
	nunca pasaban por esa limpieza. Desconecta cualquier conexión existente
	sin asumir quién la hizo (Main, HandManager, DynamicHand, MulliganHand,
	SelectionManager conectan las mismas 4 señales cada uno en su propio
	contexto)."""
	if not is_instance_valid(card):
		return
	for signal_name in ["card_hovered", "card_unhovered", "card_clicked", "card_double_clicked"]:
		if not card.has_signal(signal_name):
			continue
		for conn in card.get_signal_connection_list(signal_name):
			card.disconnect(signal_name, conn.callable)


func destroy_card(player_id: int, card: Node) -> void:
	"""Destruye una carta respetando la regla de exhumación (DAR)

	Si la carta fue exhumada (is_exhumed = true), va al destierro.
	Si no fue exhumada, va al cementerio normalmente.
	"""
	await _move_equipped_weapons_with(player_id, card, destroy_card)

	var card_data = card.card_data.duplicate() if card.get("card_data") else {}

	# Cartas exhumadas van al destierro, no al cementerio
	card_data["esta_oculta"] = false
	var is_exhumed = card.get("is_exhumed") == true
	if is_exhumed:
		_zones[player_id].exile.append(card_data)
		emit_signal("card_exiled", player_id, card)
		_emit_exile_changed(player_id)
		print("[CardManager] Carta exhumada '%s' desterrada (no vuelve al cementerio)" % card_data.get("nombre", "?"))
	else:
		_append_to_cemetery(player_id, card_data)
		emit_signal("card_destroyed", player_id, card)
		_update_cemetery_visual(player_id)

	# Desequipar ANTES de animar: compact_field_slots() corre de forma
	# síncrona dentro de animate_card_exile()/animate_card_to_cemetery()
	# (al reparentar la carta) y todavía mira equipped_weapons del portador
	# — si el Arma sigue ahí, le pisa la posición recién calculada y se ve
	# un salto visual antes de volar al cementerio/destierro.
	_unequip_from_wielder(card)

	var main_node = Engine.get_main_loop().root.get_node_or_null("Main") if Engine.get_main_loop() else null
	if main_node and main_node.get("_zone_manager") != null and is_instance_valid(card) and card.is_inside_tree() and card.visible:
		if is_exhumed:
			await main_node._zone_manager.animate_card_exile(card, player_id)
		else:
			await main_node._zone_manager.animate_card_to_cemetery(card, player_id)

	_disconnect_card_interaction_signals(card)
	card.queue_free()
	if main_node and main_node.get("_zone_manager") != null:
		main_node._zone_manager.call_deferred("compact_all_fields", true)


func remove_from_cemetery(player_id: int, index: int = -1) -> Dictionary:
	"""Remueve una carta del cementerio (para Exhumar)

	Args:
		player_id: ID del jugador
		index: Índice de la carta (-1 = última/tope)

	Returns: Datos de la carta removida
	"""
	var cemetery = _zones[player_id].cemetery

	if cemetery.is_empty():
		return {}

	if index < 0:
		index = cemetery.size() - 1

	if index >= 0 and index < cemetery.size():
		var card_data = cemetery[index]
		cemetery.remove_at(index)
		_update_cemetery_visual(player_id)
		return card_data

	return {}


# =============================================================================
# MOVIMIENTO DE CARTAS - DESTIERRO
# =============================================================================
func exile_card(player_id: int, card: Node) -> void:
	"""Destierra una carta (la remueve del juego)"""
	await _move_equipped_weapons_with(player_id, card, exile_card)

	var card_data = card.card_data.duplicate() if card.get("card_data") else {}
	card_data["esta_oculta"] = false
	_zones[player_id].exile.append(card_data)

	emit_signal("card_exiled", player_id, card)
	_emit_exile_changed(player_id)

	# Ver comentario equivalente en destroy_card(): desequipar ANTES de
	# animar para que compact_field_slots() no le pise la posición al Arma
	# mientras aún aparece en equipped_weapons del portador.
	_unequip_from_wielder(card)

	var main_node = Engine.get_main_loop().root.get_node_or_null("Main") if Engine.get_main_loop() else null
	if main_node and main_node.get("_zone_manager") != null and is_instance_valid(card) and card.is_inside_tree() and card.visible:
		await main_node._zone_manager.animate_card_exile(card, player_id)

	_disconnect_card_interaction_signals(card)
	card.queue_free()
	if main_node and main_node.get("_zone_manager") != null:
		main_node._zone_manager.call_deferred("compact_all_fields", true)



func exile_from_cemetery(player_id: int, index: int = -1) -> Dictionary:
	"""Destierra una carta del cementerio"""
	var card_data = remove_from_cemetery(player_id, index)
	if not card_data.is_empty():
		card_data["esta_oculta"] = false
		_zones[player_id].exile.append(card_data)
		_emit_exile_changed(player_id)
	return card_data


func exhume_card(player_id: int, index: int = -1) -> Dictionary:
	"""Exhuma una carta del cementerio (DAR - Exhumar)

	La carta exhumada debe marcarse con is_exhumed = true al instanciarla.
	Cuando la carta deje el campo, irá al destierro en lugar de al cementerio.

	Returns: Datos de la carta exhumada (marcar is_exhumed al instanciar)
	"""
	var card_data = remove_from_cemetery(player_id, index)
	if not card_data.is_empty():
		# Marcar en los datos que fue exhumada (para referencia)
		card_data["_was_exhumed"] = true
		print("[CardManager] Carta '%s' exhumada del cementerio" % card_data.get("nombre", "?"))
	return card_data


# =============================================================================
# SISTEMA DE DAÑO (DAR 2025)
# =============================================================================
func take_damage(player_id: int, amount: int) -> Dictionary:
	"""Aplica daño a un jugador moviendo cartas del mazo al cementerio

	Args:
		player_id: ID del jugador que recibe daño
		amount: Cantidad de daño (cartas a mover)

	Returns: {
		requested: int,      # Daño solicitado
		actual: int,         # Daño real aplicado
		cards: Array,        # Cartas movidas al cementerio
		deck_empty: bool,    # Si el mazo quedó vacío
		defeated: bool       # Si el jugador perdió (mazo vacío después del daño)
	}
	"""
	var deck = _zones[player_id].deck
	var result = {
		"requested": amount,
		"actual": 0,
		"cards": [],
		"deck_empty": false,
		"defeated": false
	}

	if amount <= 0:
		return result

	# Mover cartas del tope del mazo al cementerio
	for i in range(amount):
		if deck.is_empty():
			result.deck_empty = true
			break

		# pop_front() = tope real (2026-08-30, corregido — antes pop_back()
		# tomaba del FONDO; el camino de robo que de verdad usa la partida,
		# ZoneManager.draw_card(), confirma que el FRENTE del array es el
		# tope). El daño de combate debe consumir cartas del tope del
		# Castillo, no del fondo.
		var card_data = deck.pop_front()
		card_data["esta_oculta"] = false
		_append_to_cemetery(player_id, card_data)
		result.cards.append(card_data)
		result.actual += 1

	# Actualizar visuales
	_update_deck_visual(player_id)
	_update_cemetery_visual(player_id)

	# Verificar derrota
	if deck.is_empty():
		result.defeated = true
		emit_signal("deck_empty", player_id)

	# Emitir señal de daño
	emit_signal("damage_taken", player_id, result.actual, result.cards)

	# Log
	var card_names = result.cards.map(func(c): return c.get("nombre", "?"))
	print("[CardManager] Jugador %d recibe %d daño: %s" % [
		player_id, result.actual, card_names
	])

	# Log parcial si no se pudo hacer todo el daño
	# (2026-08-28, "módulos gordos" punto 1): 'log_partial_damage' espera
	# target_name: String como 3er parámetro — se pasaba player_id (int)
	# directo, lo que revienta en tiempo de ejecución (error de tipo) cada
	# vez que este log se dispara. Se corrige con el mismo formato usado en
	# DamageManager._log_partial_damage().
	if result.actual < result.requested:
		CombatLog.log_partial_damage(result.requested, result.actual, "Jugador %d" % (player_id + 1))

	return result


func mill_cards(player_id: int, amount: int) -> Dictionary:
	"""Muele cartas del mazo al cementerio (alias para take_damage sin ser daño)

	Usado para efectos que mueven cartas sin ser considerado daño
	"""
	return take_damage(player_id, amount)


# =============================================================================
# ACTUALIZACIÓN VISUAL (vía señales)
# =============================================================================
func _emit_deck_changed(player_id: int) -> void:
	"""Emite señal de cambio en el mazo"""
	var count = _zones[player_id].deck.size()
	emit_signal("deck_count_changed", player_id, count)


func _emit_hand_changed(player_id: int) -> void:
	"""Emite señal de cambio en la mano"""
	var count = _zones[player_id].hand.size()
	emit_signal("hand_count_changed", player_id, count)


func _emit_cemetery_changed(player_id: int) -> void:
	"""Emite señal de cambio en el cementerio"""
	var count = _zones[player_id].cemetery.size()
	emit_signal("cemetery_count_changed", player_id, count)


func _emit_exile_changed(player_id: int) -> void:
	"""Emite señal de cambio en el destierro"""
	var count = _zones[player_id].exile.size()
	emit_signal("exile_count_changed", player_id, count)


func _emit_field_changed(player_id: int) -> void:
	"""Emite señal de cambio en el campo"""
	var count = _zones[player_id].field.size()
	emit_signal("field_count_changed", player_id, count)


# Aliases para compatibilidad
func _update_deck_visual(player_id: int) -> void:
	_emit_deck_changed(player_id)


func _update_cemetery_visual(player_id: int) -> void:
	_emit_cemetery_changed(player_id)


func update_all_visuals() -> void:
	"""Emite señales para todos los contadores"""
	for player_id in [0, 1]:
		_emit_deck_changed(player_id)
		_emit_hand_changed(player_id)
		_emit_cemetery_changed(player_id)
		_emit_exile_changed(player_id)
		_emit_field_changed(player_id)


# =============================================================================
# UTILIDADES
# =============================================================================
func find_card_in_cemetery(player_id: int, card_name: String) -> int:
	"""Busca una carta por nombre en el cementerio

	Returns: Índice de la carta o -1 si no se encuentra
	"""
	var cemetery = _zones[player_id].cemetery
	for i in range(cemetery.size()):
		if cemetery[i].get("nombre", "") == card_name:
			return i
	return -1


func get_cemetery_cards_by_type(player_id: int, card_type: int) -> Array:
	"""Obtiene cartas del cementerio filtradas por tipo"""
	var cemetery = _zones[player_id].cemetery
	return cemetery.filter(func(c): return c.get("tipo", -1) == card_type)


func can_draw(player_id: int) -> bool:
	"""Verifica si el jugador puede robar"""
	return not _zones[player_id].deck.is_empty()


func is_defeated(player_id: int) -> bool:
	"""Verifica si el jugador está derrotado (mazo vacío)"""
	return _zones[player_id].deck.is_empty()
