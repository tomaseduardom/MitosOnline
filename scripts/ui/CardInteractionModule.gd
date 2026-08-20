extends Node
class_name CardInteractionModule
## CardInteractionModule — Gestiona clicks, hover y arrastre de cartas.
## Se instancia como hijo de Main en _ready().

var _main: Node = null

var selected_card: Node = null
var is_placing_gold: bool = false
var _card_clicked_this_frame: bool = false
var _opponent_card_original_pos: Dictionary = {}

# =============================================================================
# SELECCIÓN DE OBJETIVO — usado por efectos que apuntan a UNA carta en juego
# (dar fuerza, silenciar, anular/destruir dirigido). Mismo patrón que
# is_placing_gold: se activa un "modo", y el próximo click en una carta que
# pase el filtro resuelve la acción pendiente en vez de abrir la selección
# normal de carta.
# =============================================================================
var is_selecting_target: bool = false
var _target_filter: Callable = Callable()
var _target_callback: Callable = Callable()


func setup(main: Node) -> void:
	_main = main


func start_target_selection(prompt: String, filter: Callable, on_selected: Callable) -> void:
	"""Activa el modo de selección de objetivo.
	filter: Callable(card) -> bool — decide si esa carta es un objetivo legal.
	on_selected: Callable(card) — se llama con la carta elegida al resolver."""
	is_selecting_target = true
	_target_filter = filter
	_target_callback = on_selected
	_main._update_debug(prompt)


func cancel_target_selection() -> void:
	if not is_selecting_target:
		return
	is_selecting_target = false
	_target_filter = Callable()
	_target_callback = Callable()
	_main._update_debug("Selección de objetivo cancelada")


func _resolve_target_selection(card: Node) -> void:
	if _target_filter.is_valid() and not _target_filter.call(card):
		_main._update_debug("Objetivo no válido — elige otra carta")
		return
	var callback = _target_callback
	is_selecting_target = false
	_target_filter = Callable()
	_target_callback = Callable()
	if callback.is_valid():
		callback.call(card)


func check_deselect() -> void:
	"""Deselecciona la carta si el click fue fuera de cualquier carta."""
	if _card_clicked_this_frame:
		_card_clicked_this_frame = false
		return
	if selected_card:
		selected_card.deselect()
		selected_card = null


# =============================================================================
# CLICKS EN CARTAS DEL JUGADOR
# =============================================================================
func _on_card_clicked(card: Node) -> void:
	_card_clicked_this_frame = true
	if is_selecting_target:
		_resolve_target_selection(card)
		return
	if is_placing_gold:
		await _main._gold_manager._place_card_as_gold(card)
		return
	# Declarar atacante con un clic (2026-08-17): el arrastre se desactivó
	# (Card.drag_enabled = false) por los bugs de posicionamiento que
	# causaba — ver Card._can_declare_attack_drag() para las mismas
	# condiciones (ataque anticipado con Furia en Vigilia, o declaración
	# normal en el paso de Ataque). Se reutiliza esa función tal cual para
	# no duplicar la lógica de cuándo tiene sentido intentar atacar.
	if card.card_type == Constants.CardType.ALIADO and card.current_zone == Constants.Zone.LINEA_DEFENSA:
		# Si ya está atacando, un segundo clic lo retira del combate en vez
		# de rechazar el clic con un mensaje — a pedido del usuario, para
		# poder corregir una declaración antes de confirmar con ¿Paso?.
		if card in GameManager.attackers:
			if GameManager.current_phase == Constants.Phase.ATAQUE:
				var undeclared = GameManager.undeclare_attacker(card)
				if undeclared:
					unmark_attackers([card])
					var name_undeclared = card.get("card_name") if card.get("card_name") else "Aliado"
					_main._update_debug("%s ya no está atacando" % name_undeclared)
			return
		if card.has_method("_can_declare_attack_drag") and card._can_declare_attack_drag():
			await _declare_attacker(card)
			return
	if selected_card and selected_card != card:
		selected_card.deselect()
	card.toggle_selection()
	selected_card = card if card.is_selected else null
	if card.card_type == Constants.CardType.ORO:
		_main._update_debug("Oro: %s" % card.card_name)
	elif card.card_type == Constants.CardType.ALIADO:
		_main._update_debug("Carta: %s (Coste: %d, Fuerza: %d)" % [card.card_name, card.card_cost, card.card_strength])
	else:
		_main._update_debug("Carta: %s (Coste: %d)" % [card.card_name, card.card_cost])


func _on_card_double_clicked(card: Node) -> void:
	if GameManager.current_phase != Constants.Phase.VIGILIA:
		_main._update_debug("Solo puedes jugar cartas en Vigilia")
		return
	if GameManager.active_player_id != 0:
		_main._update_debug("No es tu turno")
		return
	if card.get_parent() != _main.player_hand:
		_main._update_debug("Solo puedes jugar cartas de la mano")
		return
	if card.card_type == Constants.CardType.ORO:
		await _main._gold_manager._place_card_as_gold(card)
		return
	await _main._gold_manager.play_card(card)


func _on_card_hovered(_card: Node) -> void:
	pass


func _on_card_unhovered(_card: Node) -> void:
	pass


# =============================================================================
# HOVER EN CARTAS DEL OPONENTE
# =============================================================================
func _on_opponent_card_hovered(card: Node) -> void:
	if not _opponent_card_original_pos.has(card):
		_opponent_card_original_pos[card] = card.position
	card.z_index = 100
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "position:y", card.position.y + 15, 0.15)
	tween.tween_property(card, "scale", card.base_scale * 1.08, 0.15)


func _on_opponent_card_unhovered(card: Node) -> void:
	card.z_index = 0
	var original_pos = _opponent_card_original_pos.get(card, card.position)
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "position", original_pos, 0.15)
	tween.tween_property(card, "scale", card.base_scale, 0.15)


func _on_card_dropped(card: Node, pos: Vector2) -> void:
	if card.has_method("move_to"):
		card.move_to(card.original_position)


# =============================================================================
# COLOCAR ORO
# =============================================================================
func _on_place_gold_pressed() -> void:
	if not TurnManager.can_place_oro(GameManager.current_phase):
		if TurnManager.oro_placed_this_turn:
			_main._update_debug("Ya colocaste Oro este turno")
		elif TurnManager.oro_chance_lost:
			_main._update_debug("Perdiste la oportunidad de colocar Oro (jugaste otra carta primero)")
		else:
			_main._update_debug("Solo puedes colocar Oro en Fase de Vigilia")
		return
	is_placing_gold = not is_placing_gold
	if is_placing_gold:
		_main._update_debug("Selecciona una carta para colocar como Oro (debe ser tu primera acción)")
	else:
		_main._update_debug("Modo Oro cancelado")


# =============================================================================
# BATALLA — DECLARAR ATACANTE
# =============================================================================
func _declare_attacker(card: Node) -> void:
	"""Declara un Aliado como atacante. Se llama al soltarlo en la Línea de
	Ataque — con Furia funciona durante Vigilia (ataque anticipado, DAR 8);
	sin Furia, DropZone solo deja soltar aquí durante el paso de Ataque
	(DAR 5.3.1), y GameManager.declare_attacker() valida enfermedad de
	invocación. Antes esta función solo se usaba (y nombraba) para Furia,
	pero el drop de DropZone ya aceptaba ambos casos — ver hallazgo 5.

	NO abre su propia ventana de prioridad (2026-08-16): antes lo hacía
	siempre, apenas se declaraba UN atacante — eso hacía que, en cuanto se
	pasaba esa ventana, se interpretara como 'atacantes confirmados' y el
	combate arrancaba con un solo Aliado, sin dejar declarar más. Además esa
	ventana se solapaba con la que GameManager.declare_attacker() ya abre
	internamente al resolver el trigger 'cuando ataque' de la propia carta
	(ver TriggerSystem._collect_triggers_for_event), lo que dejaba la
	prioridad en un estado inconsistente. Ahora el jugador puede seguir
	arrastrando más Aliados a la Línea de Ataque, y confirma todos juntos
	presionando ¿Paso? — que ya llama a GameManager.confirm_attackers()
	cuando no hay ninguna ventana de prioridad activa (ver _on_paso_pressed
	en PhaseFlowController), y ESA transición sí abre la ventana real
	(Guerra de Talismanes o Bloqueo)."""
	if not card or not is_instance_valid(card):
		return
	# Con el clic reemplazando al arrastre, es fácil volver a clickear un
	# Aliado que ya está atacando (por error, o para revisarlo). Antes esto
	# caía en GameManager.declare_attacker(), que lo rechaza en silencio
	# (ally in attackers), y el mensaje genérico de más abajo ('no puede
	# atacar todavía') daba a entender que el ataque había fallado, cuando
	# en realidad ya estaba registrado y el combate seguía su curso normal.
	if card in GameManager.attackers:
		_main._update_debug("%s ya está atacando" % (card.get("card_name") if card.get("card_name") else "Aliado"))
		return
	# Si hay una ventana de prioridad abierta (p.ej. respuesta a un 'cuando
	# entre en juego' que se acaba de disparar), no dejar declarar un nuevo
	# atacante todavía — eso hacía que el efecto pendiente (p.ej. el 'roba 2'
	# de un oro) quedara pospuesto y se resolviera recién al momento de
	# atacar, en vez de cuando se jugó la carta. Hay que resolver esa
	# ventana primero (presionando ¿Paso?).
	var pm_check = get_node_or_null("/root/PriorityManager")
	if pm_check and pm_check.priority_window_active:
		_main._update_debug("Resuelve la respuesta pendiente (¿Paso?) antes de declarar otro atacante")
		card.return_to_hand()
		return
	var card_name = card.get("card_name") if card.get("card_name") else "Aliado"
	var has_furia = card.has_method("has_keyword") and card.has_keyword(Constants.Keyword.FURIA)
	await card.return_to_hand()
	GameManager.proceed_to_battle()
	await get_tree().process_frame
	# Validar ANTES de aplicar el aspecto visual de 'atacando' (2026-08-17):
	# antes _mark_card_as_attacker() se llamaba siempre, sin importar si
	# GameManager.declare_attacker() aceptaba el ataque — si la validación
	# fallaba (enfermedad de invocación, fase incorrecta, etc.), la carta
	# quedaba con el aspecto de atacante para siempre sin haberse agregado
	# al combate: nunca hacía daño y parecía 'desaparecer'/quedar con un
	# color raro, sin ningún aviso de por qué.
	var declared = await GameManager.declare_attacker(card)
	if not declared:
		var reason = ""
		var tm = get_node_or_null("/root/TurnManager")
		if tm and tm.has_method("can_attack"):
			reason = tm.can_attack(card).get("reason", "")
		_main._update_debug("%s no puede atacar%s" % [card_name, (": " + reason) if not reason.is_empty() else " todavía"])
		return
	_mark_card_as_attacker(card)
	_main._start_paso_glow()
	_main._update_debug("⚔ %s declara ataque%s! Puedes seguir declarando o presionar ¿Paso?" % [card_name, " con Furia" if has_furia else ""])
	print("[CardInteraction] '%s' declaró ataque%s" % [card_name, " (Furia)" if has_furia else ""])


func _mark_card_as_attacker(card: Node) -> void:
	"""Aspecto visual de 'atacando': tinte naranja y leve aumento de escala.

	Antes rotaba -90° usando pivot_offset centrado — dentro del contenedor
	horizontal del campo (HBoxContainer, top_level=false), rotar 90° hace
	que la carta ocupe un área muy distinta a la que el contenedor le
	reservó, y en la práctica se veía como si la carta desapareciera o
	quedara recortada. Se quita la rotación por completo: el tinte y la
	escala ya comunican 'esta carta está atacando' sin ese riesgo."""
	if not card or not is_instance_valid(card):
		return
	var tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(card, "modulate", Color(1.0, 0.55, 0.35, 1.0), 0.2)
	tween.tween_property(card, "scale", card.base_scale * 1.08, 0.15)


func unmark_attackers(cards: Array) -> void:
	"""Revierte el aspecto visual de 'atacando' (tinte naranja, escala
	aumentada) que aplica _mark_card_as_attacker(). Se debe llamar al
	terminar el combate — antes NADA lo hacía, así que un Aliado que
	atacaba quedaba con el tinte naranja para siempre."""
	for card in cards:
		if not card or not is_instance_valid(card):
			continue
		var tween = create_tween()
		tween.set_parallel(true)
		tween.tween_property(card, "modulate", Color.WHITE, 0.2)
		tween.tween_property(card, "scale", card.base_scale, 0.15)
		tween.tween_property(card, "rotation_degrees", card.target_rotation, 0.25).set_ease(Tween.EASE_OUT)
