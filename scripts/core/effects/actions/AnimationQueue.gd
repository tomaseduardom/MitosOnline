extends Node
## AnimationQueue - Sistema de cola de animaciones secuenciales
## DAR Sección 8: Robar/Botar cartas una a una con animación
## NOTA: No usar class_name - ya es autoload global

# =============================================================================
# SIGNALS
# =============================================================================
signal queue_started
signal queue_finished
signal queue_paused
signal queue_resumed

signal animation_started(command: Dictionary)
signal animation_finished(command: Dictionary)
signal animation_skipped(command: Dictionary)

signal batch_started(batch_id: String, total: int)
signal batch_progress(batch_id: String, current: int, total: int)
signal batch_finished(batch_id: String, results: Array)

# =============================================================================
# TIPOS DE COMANDOS
# =============================================================================
enum CommandType {
	DRAW_CARD,       # Robar una carta
	MILL_CARD,       # Botar una carta
	DISCARD_CARD,    # Descartar una carta
	MOVE_CARD,       # Mover carta entre zonas
	FLIP_CARD,       # Voltear carta
	DESTROY_CARD,    # Destruir carta
	EXILE_CARD,      # Desterrar carta
	PLAY_CARD,       # Jugar carta
	BUFF_CARD,       # Aplicar buff
	DAMAGE,          # Daño a carta/jugador
	HEAL,            # Curar
	CUSTOM,          # Callable personalizado
	DELAY,           # Pausa
	PARALLEL,        # Ejecutar múltiples en paralelo
	SHOW_MESSAGE,    # Mostrar mensaje en UI
	SOUND_EFFECT,    # Reproducir sonido
	VISUAL_EFFECT    # Efecto visual (partículas, etc.)
}

# =============================================================================
# ESTADO
# =============================================================================
## Cola principal de comandos
var command_queue: Array[Dictionary] = []

## Flag de ejecución
var is_running: bool = false
var is_paused: bool = false

## Comando actual en ejecución
var current_command: Dictionary = {}

## Velocidad de animación (multiplicador)
var animation_speed: float = 1.0

## Delays entre animaciones (segundos)
var delay_between_cards: float = 0.15
var delay_between_batches: float = 0.3
var delay_after_effect: float = 0.2

## Batch tracking
var current_batch_id: String = ""
var current_batch_results: Array = []

## Skip flag (para saltar animaciones)
var skip_animations: bool = false

## Módulo extraído (Fase 4 de reestructuración)
var _animations: AnimationEffects


func _ready() -> void:
	_animations = AnimationEffects.new()
	_animations.setup(self)

	print("[AnimationQueue] Inicializado")
	# Conectar a ActionModule diferido (por orden de autoloads)
	call_deferred("_connect_to_action_module")


func _connect_to_action_module() -> void:
	"""Conecta a las señales de ActionModule para feedback visual"""
	var action_module = ActionModule

	# Señales de DRAW
	if not action_module.action_draw_started.is_connected(_on_action_draw_started):
		action_module.action_draw_started.connect(_on_action_draw_started)
	if not action_module.action_draw_completed.is_connected(_on_action_draw_completed):
		action_module.action_draw_completed.connect(_on_action_draw_completed)

	# Señales de MILL
	if not action_module.action_mill_started.is_connected(_on_action_mill_started):
		action_module.action_mill_started.connect(_on_action_mill_started)
	if not action_module.action_mill_completed.is_connected(_on_action_mill_completed):
		action_module.action_mill_completed.connect(_on_action_mill_completed)

	# Señales de DESTROY
	if not action_module.action_destroy_started.is_connected(_on_action_destroy_started):
		action_module.action_destroy_started.connect(_on_action_destroy_started)
	if not action_module.action_destroy_completed.is_connected(_on_action_destroy_completed):
		action_module.action_destroy_completed.connect(_on_action_destroy_completed)

	# Señales de BANISH
	if not action_module.action_banish_started.is_connected(_on_action_banish_started):
		action_module.action_banish_started.connect(_on_action_banish_started)
	if not action_module.action_banish_completed.is_connected(_on_action_banish_completed):
		action_module.action_banish_completed.connect(_on_action_banish_completed)

	# Señales de SEARCH
	if not action_module.action_search_started.is_connected(_on_action_search_started):
		action_module.action_search_started.connect(_on_action_search_started)
	if not action_module.action_search_completed.is_connected(_on_action_search_completed):
		action_module.action_search_completed.connect(_on_action_search_completed)

	# Señales de DISCARD
	if not action_module.action_discard_started.is_connected(_on_action_discard_started):
		action_module.action_discard_started.connect(_on_action_discard_started)
	if not action_module.action_discard_completed.is_connected(_on_action_discard_completed):
		action_module.action_discard_completed.connect(_on_action_discard_completed)

	# Señales de triggers
	if not action_module.triggers_collected.is_connected(_on_triggers_collected):
		action_module.triggers_collected.connect(_on_triggers_collected)

	print("[AnimationQueue] Conectado a ActionModule")


# _connect_to_action_executor() y sus 8 handlers (_on_ability_started,
# _on_ability_completed, _on_executor_action, _on_cost_paid,
# _get_cost_display_name, _on_executor_damage, _on_executor_buff,
# _on_executor_heal, _on_executor_token) eliminados (2026-08-17): escuchaban
# señales de ActionExecutor.execute_ability()/execute_ability_blocks(),
# que resultaron tener cero llamadores en todo el proyecto y ya se
# eliminaron de ActionExecutor.gd — estos handlers nunca se disparaban.
# =============================================================================
# HANDLERS DE ACTIONMODULE - Con animaciones automáticas
# =============================================================================
func _on_action_draw_started(player_id: int, amount: int, source: String) -> void:
	print("[AnimationQueue] 🎴 DRAW iniciado: Jugador %d, %d cartas" % [player_id, amount])
	# Mostrar mensaje de acción
	add_command(CommandType.SHOW_MESSAGE, {
		"text": "Robando %d carta(s)..." % amount,
		"duration": 0.5
	})


func _on_action_draw_completed(player_id: int, cards: Array, actual: int) -> void:
	print("[AnimationQueue] 🎴 DRAW completado: %d cartas robadas" % actual)
	# Efecto de highlight en cartas robadas
	for card in cards:
		if is_instance_valid(card):
			add_command(CommandType.VISUAL_EFFECT, {
				"effect": "card_glow",
				"target": card,
				"color": Color(0.4, 0.8, 1.0, 0.6),
				"duration": 0.4
			})


func _on_action_mill_started(player_id: int, amount: int, to_exile: bool) -> void:
	var dest = "Destierro" if to_exile else "Cementerio"
	print("[AnimationQueue] 💀 MILL iniciado: Jugador %d, %d cartas al %s" % [player_id, amount, dest])
	add_command(CommandType.SHOW_MESSAGE, {
		"text": "Enviando %d carta(s) al %s..." % [amount, dest],
		"duration": 0.5
	})


func _on_action_mill_completed(player_id: int, cards: Array) -> void:
	print("[AnimationQueue] 💀 MILL completado: %d cartas enviadas" % cards.size())


func _on_action_destroy_started(targets: Array, source: Node) -> void:
	print("[AnimationQueue] 💥 DESTROY iniciado: %d objetivos" % targets.size())
	var source_name = source.card_name if source and source.get("card_name") else "Efecto"
	add_command(CommandType.SHOW_MESSAGE, {
		"text": "%s destruye %d carta(s)" % [source_name, targets.size()],
		"duration": 0.6
	})


func _on_action_destroy_completed(destroyed: Array, survived: Array) -> void:
	print("[AnimationQueue] 💥 DESTROY completado: %d destruidas, %d sobrevivieron" % [destroyed.size(), survived.size()])
	# Encolar animaciones de destrucción para cada carta
	for card in destroyed:
		if is_instance_valid(card):
			var owner_id = card.owner_id if card.get("owner_id") != null else 0
			add_command(CommandType.DESTROY_CARD, {
				"card": card,
				"player_id": owner_id
			})


func _on_action_banish_started(targets: Array, source: Node) -> void:
	print("[AnimationQueue] ✨ BANISH iniciado: %d objetivos" % targets.size())
	add_command(CommandType.SHOW_MESSAGE, {
		"text": "Desterrando %d carta(s)..." % targets.size(),
		"duration": 0.5
	})


func _on_action_banish_completed(banished: Array) -> void:
	print("[AnimationQueue] ✨ BANISH completado: %d desterradas" % banished.size())
	# Encolar animaciones de destierro
	for card in banished:
		if is_instance_valid(card):
			var owner_id = card.owner_id if card.get("owner_id") != null else 0
			add_command(CommandType.EXILE_CARD, {
				"card": card,
				"player_id": owner_id
			})


func _on_action_search_started(player_id: int, zone: int, filter: Dictionary) -> void:
	var zone_name = Constants.ZONE_NAMES.get(zone, "Mazo") if Constants.get("ZONE_NAMES") else "Mazo"
	print("[AnimationQueue] 🔍 SEARCH iniciado: Jugador %d busca en %s" % [player_id, zone_name])
	add_command(CommandType.SHOW_MESSAGE, {
		"text": "Buscando en %s..." % zone_name,
		"duration": 0.8
	})


func _on_action_search_completed(player_id: int, result: Dictionary) -> void:
	var selected = result.get("selected", [])
	print("[AnimationQueue] 🔍 SEARCH completado: %d cartas seleccionadas" % selected.size())
	# Si buscó en mazo, encolar barajado
	if result.get("must_shuffle", false):
		queue_shuffle_animation(player_id, "search")


func _on_action_discard_started(player_id: int, cards: Array) -> void:
	print("[AnimationQueue] 🗑️ DISCARD iniciado: Jugador %d, %d cartas" % [player_id, cards.size()])
	add_command(CommandType.SHOW_MESSAGE, {
		"text": "Descartando %d carta(s)..." % cards.size(),
		"duration": 0.5
	})


func _on_action_discard_completed(player_id: int, discarded: Array) -> void:
	print("[AnimationQueue] 🗑️ DISCARD completado: %d cartas descartadas" % discarded.size())


func _on_triggers_collected(active_triggers: Array, opponent_triggers: Array) -> void:
	var total = active_triggers.size() + opponent_triggers.size()
	if total > 0:
		print("[AnimationQueue] ⚡ Triggers recolectados: %d activo, %d oponente" % [active_triggers.size(), opponent_triggers.size()])
		# Mostrar indicador de triggers pendientes
		add_command(CommandType.SHOW_MESSAGE, {
			"text": "%d habilidad(es) activada(s)" % total,
			"duration": 0.6
		})


# =============================================================================
# AÑADIR COMANDOS A LA COLA
# =============================================================================
func add_command(type: CommandType, data: Dictionary = {}) -> void:
	"""Añade un comando individual a la cola"""
	var command = {
		"type": type,
		"data": data,
		"timestamp": Time.get_ticks_msec(),
		"id": _generate_command_id()
	}
	command_queue.append(command)


func add_callable(callable: Callable, description: String = "") -> void:
	"""Añade un Callable personalizado a la cola"""
	add_command(CommandType.CUSTOM, {
		"callable": callable,
		"description": description
	})


func add_delay(seconds: float) -> void:
	"""Añade una pausa a la cola"""
	add_command(CommandType.DELAY, {"duration": seconds})


# =============================================================================
# FUNCIONES DE LOTE (BATCH) - DAR Sección 8
# =============================================================================
func queue_draw_cards(player_id: int, amount: int, source: String = "") -> String:
	"""Encola múltiples robos de carta, uno a uno
	DAR Sección 8: Robar se hace carta por carta

	Returns: batch_id para tracking
	"""
	var batch_id = "draw_%d_%d" % [player_id, Time.get_ticks_msec()]

	for i in range(amount):
		add_command(CommandType.DRAW_CARD, {
			"player_id": player_id,
			"index": i,
			"total": amount,
			"batch_id": batch_id,
			"source": source
		})

	print("[AnimationQueue] Encoladas %d animaciones de robo (batch: %s)" % [amount, batch_id])
	return batch_id


func queue_mill_cards(player_id: int, amount: int, destination: int = -1, source: String = "") -> String:
	"""Encola múltiples 'botar' de carta, uno a uno
	DAR Sección 8: Botar se hace carta por carta

	Args:
		player_id: Jugador afectado
		amount: Cantidad de cartas a botar
		destination: Zona destino (CEMENTERIO o DESTIERRO), -1 para Cementerio
		source: Nombre del efecto que causa el botar

	Returns: batch_id para tracking
	"""
	var batch_id = "mill_%d_%d" % [player_id, Time.get_ticks_msec()]

	if destination < 0:
		destination = Constants.Zone.CEMENTERIO

	for i in range(amount):
		add_command(CommandType.MILL_CARD, {
			"player_id": player_id,
			"destination": destination,
			"index": i,
			"total": amount,
			"batch_id": batch_id,
			"source": source
		})

	print("[AnimationQueue] Encoladas %d animaciones de botar (batch: %s)" % [amount, batch_id])
	return batch_id


func queue_discard_cards(player_id: int, cards: Array, source: String = "") -> String:
	"""Encola descarte de múltiples cartas, una a una"""
	var batch_id = "discard_%d_%d" % [player_id, Time.get_ticks_msec()]

	for i in range(cards.size()):
		add_command(CommandType.DISCARD_CARD, {
			"player_id": player_id,
			"card": cards[i],
			"index": i,
			"total": cards.size(),
			"batch_id": batch_id,
			"source": source
		})

	return batch_id


func queue_damage(targets: Array, damage_per_target: int, source: Node = null) -> String:
	"""Encola daño a múltiples objetivos, uno a uno"""
	var batch_id = "damage_%d" % Time.get_ticks_msec()

	for i in range(targets.size()):
		add_command(CommandType.DAMAGE, {
			"target": targets[i],
			"damage": damage_per_target,
			"source": source,
			"index": i,
			"total": targets.size(),
			"batch_id": batch_id
		})

	return batch_id


func queue_move_cards(cards: Array, destination_zone: int, player_id: int) -> String:
	"""Encola movimiento de múltiples cartas"""
	var batch_id = "move_%d" % Time.get_ticks_msec()

	for i in range(cards.size()):
		add_command(CommandType.MOVE_CARD, {
			"card": cards[i],
			"destination": destination_zone,
			"player_id": player_id,
			"index": i,
			"total": cards.size(),
			"batch_id": batch_id
		})

	return batch_id


func queue_parallel(commands: Array[Callable]) -> void:
	"""Encola múltiples comandos para ejecutar en paralelo"""
	add_command(CommandType.PARALLEL, {
		"callables": commands
	})


# =============================================================================
# EJECUCIÓN DE LA COLA
# =============================================================================
func start() -> void:
	"""Inicia la ejecución de la cola"""
	if is_running:
		push_warning("[AnimationQueue] Ya está ejecutando")
		return

	if command_queue.is_empty():
		print("[AnimationQueue] Cola vacía, nada que ejecutar")
		return

	is_running = true
	is_paused = false
	emit_signal("queue_started")

	print("[AnimationQueue] Iniciando ejecución de %d comandos" % command_queue.size())
	await _process_queue()


func start_and_wait() -> Array:
	"""Inicia la cola y espera hasta que termine
	Returns: Array con resultados de cada comando
	"""
	var results: Array = []

	if command_queue.is_empty():
		return results

	start()

	# Esperar hasta que termine
	while is_running:
		await get_tree().process_frame

	return current_batch_results


func pause() -> void:
	"""Pausa la ejecución"""
	if is_running and not is_paused:
		is_paused = true
		emit_signal("queue_paused")
		print("[AnimationQueue] Pausado")


func resume() -> void:
	"""Reanuda la ejecución"""
	if is_running and is_paused:
		is_paused = false
		emit_signal("queue_resumed")
		print("[AnimationQueue] Reanudado")


func stop() -> void:
	"""Detiene y limpia la cola"""
	is_running = false
	is_paused = false
	command_queue.clear()
	current_command = {}
	print("[AnimationQueue] Detenido y limpiado")


func skip_current() -> void:
	"""Salta la animación actual"""
	skip_animations = true


func skip_all() -> void:
	"""Salta todas las animaciones restantes (ejecuta instantáneamente)"""
	animation_speed = 100.0  # Muy rápido
	delay_between_cards = 0.01
	delay_between_batches = 0.01


func _process_queue() -> void:
	"""Procesa la cola de comandos secuencialmente"""
	while not command_queue.is_empty() and is_running:
		# Esperar si está pausado
		while is_paused:
			await get_tree().process_frame

		# Obtener siguiente comando
		current_command = command_queue.pop_front()
		var batch_id = current_command.data.get("batch_id", "")

		# Tracking de batch
		if batch_id and batch_id != current_batch_id:
			# Nuevo batch
			if current_batch_id:
				emit_signal("batch_finished", current_batch_id, current_batch_results)

			current_batch_id = batch_id
			current_batch_results.clear()
			var total = current_command.data.get("total", 1)
			emit_signal("batch_started", batch_id, total)

		# Emitir progreso de batch
		if batch_id:
			var index = current_command.data.get("index", 0)
			var total = current_command.data.get("total", 1)
			emit_signal("batch_progress", batch_id, index + 1, total)

		# Ejecutar comando
		emit_signal("animation_started", current_command)

		if skip_animations:
			emit_signal("animation_skipped", current_command)
			skip_animations = false
		else:
			var result = await _execute_command(current_command)
			current_batch_results.append(result)

		emit_signal("animation_finished", current_command)

		# Delay entre comandos
		if not command_queue.is_empty() and not skip_animations:
			var delay = delay_between_cards / animation_speed
			await get_tree().create_timer(delay).timeout

	# Finalizar último batch
	if current_batch_id:
		emit_signal("batch_finished", current_batch_id, current_batch_results)
		current_batch_id = ""
		current_batch_results.clear()

	is_running = false
	current_command = {}
	emit_signal("queue_finished")
	emit_signal("queue_empty")  # Para TurnManager
	print("[AnimationQueue] Cola completada")


func _execute_command(command: Dictionary) -> Dictionary:
	"""Ejecuta un comando individual"""
	var result = {"success": true, "command": command}
	var type: CommandType = command.type
	var data: Dictionary = command.data

	match type:
		CommandType.DRAW_CARD:
			result = await _execute_draw(data)

		CommandType.MILL_CARD:
			result = await _execute_mill(data)

		CommandType.DISCARD_CARD:
			result = await _execute_discard(data)

		CommandType.MOVE_CARD:
			result = await _execute_move(data)

		CommandType.FLIP_CARD:
			result = await _execute_flip(data)

		CommandType.DESTROY_CARD:
			result = await _execute_destroy(data)

		CommandType.EXILE_CARD:
			result = await _execute_exile(data)

		CommandType.DAMAGE:
			result = await _execute_damage(data)

		CommandType.BUFF_CARD:
			result = await _execute_buff(data)

		CommandType.HEAL:
			result = await _execute_heal(data)

		CommandType.PLAY_CARD:
			result = await _execute_play_card(data)

		CommandType.CUSTOM:
			result = await _execute_custom(data)

		CommandType.DELAY:
			await get_tree().create_timer(data.get("duration", 0.5)).timeout

		CommandType.PARALLEL:
			result = await _execute_parallel(data)

		CommandType.SHOW_MESSAGE:
			_animations.show_message(data)

		CommandType.SOUND_EFFECT:
			_animations.play_sound(data)

		CommandType.VISUAL_EFFECT:
			await _animations.play_visual_effect(data)

	return result


# =============================================================================
# EJECUCIÓN DE COMANDOS ESPECÍFICOS
# =============================================================================
func _execute_draw(data: Dictionary) -> Dictionary:
	"""Ejecuta animación de robar una carta"""
	var result = {"success": true, "card": null}
	var player_id = data.get("player_id", 0)

	var game_board = _get_game_board()

	if not game_board:
		result.success = false
		return result

	# Obtener carta del tope del Castillo
	var deck = game_board.get_cards_in_zone(Constants.Zone.CASTILLO, player_id)

	if deck.is_empty():
		# Castillo vacío - verificar derrota
		result.success = false
		result["deck_empty"] = true
		GameManager.player_loses(player_id, "deck_empty_draw")
		return result

	var card = deck[0]
	result.card = card

	# Mover carta con animación
	await _animations.animate_card_move(card, Constants.Zone.CASTILLO, Constants.Zone.MANO, player_id)

	# Emitir trigger
	EffectController.on_card_drawn.emit(player_id, card)

	var card_name = card.card_name if card.get("card_name") else "Carta"
	print("[AnimationQueue] Robada: %s (jugador %d)" % [card_name, player_id + 1])

	return result


func _execute_mill(data: Dictionary) -> Dictionary:
	"""Ejecuta animación de botar una carta"""
	var result = {"success": true, "card": null}
	var player_id = data.get("player_id", 0)
	var destination = data.get("destination", Constants.Zone.CEMENTERIO)

	var game_board = _get_game_board()

	if not game_board:
		result.success = false
		return result

	var deck = game_board.get_cards_in_zone(Constants.Zone.CASTILLO, player_id)

	if deck.is_empty():
		# 'En medida de lo posible' - no hay más cartas, terminar sin error
		result.success = true
		result["no_more_cards"] = true
		return result

	var card = deck[0]
	result.card = card

	# Voltear carta (es información pública)
	if card.has_method("flip_face_up"):
		card.flip_face_up()

	# Mover con animación
	await _animations.animate_card_move(card, Constants.Zone.CASTILLO, destination, player_id)

	# Emitir trigger
	EffectController.on_card_milled.emit(player_id, card, destination)

	var card_name = card.card_name if card.get("card_name") else "Carta"
	var dest_name = Constants.ZONE_NAMES.get(destination, "?")
	print("[AnimationQueue] Botada: %s → %s" % [card_name, dest_name])

	return result


func _execute_discard(data: Dictionary) -> Dictionary:
	"""Ejecuta animación de descartar una carta"""
	var result = {"success": true}
	var player_id = data.get("player_id", 0)
	var card = data.get("card")

	if not card:
		result.success = false
		return result

	var game_board = _get_game_board()
	if not game_board:
		result.success = false
		return result

	# Mover con animación
	await _animations.animate_card_move(card, Constants.Zone.MANO, Constants.Zone.CEMENTERIO, player_id)

	# Emitir trigger
	EffectController.on_card_discarded.emit(player_id, card)

	return result


func _execute_move(data: Dictionary) -> Dictionary:
	"""Ejecuta animación de mover carta"""
	var result = {"success": true}
	var card = data.get("card")
	var destination = data.get("destination", 0)
	var player_id = data.get("player_id", 0)

	if not card:
		result.success = false
		return result

	var from_zone = card.current_zone if card.get("current_zone") != null else -1
	await _animations.animate_card_move(card, from_zone, destination, player_id)

	return result


func _execute_flip(data: Dictionary) -> Dictionary:
	"""Ejecuta animación de voltear carta"""
	var result = {"success": true}
	var card = data.get("card")
	var face_up = data.get("face_up", true)

	if card and card.has_method("flip_card"):
		await _animations.animate_card_flip(card, face_up)

	return result


func _execute_destroy(data: Dictionary) -> Dictionary:
	"""Ejecuta animación de destruir carta"""
	var result = {"success": true}
	var card = data.get("card")
	var player_id = data.get("player_id", 0)

	if not card:
		result.success = false
		return result

	# Efecto visual de destrucción
	await _animations.animate_destruction(card)

	# Mover al cementerio
	var game_board = _get_game_board()
	if game_board:
		game_board.move_card(card, Constants.Zone.CEMENTERIO, player_id, true)

	return result


func _execute_exile(data: Dictionary) -> Dictionary:
	"""Ejecuta animación de desterrar carta"""
	var result = {"success": true}
	var card = data.get("card")
	var player_id = data.get("player_id", 0)

	if not card:
		result.success = false
		return result

	# Efecto visual de destierro
	await _animations.animate_exile(card)

	# Mover al destierro
	var game_board = _get_game_board()
	if game_board:
		game_board.move_card(card, Constants.Zone.DESTIERRO, player_id, true)

	return result


func _execute_damage(data: Dictionary) -> Dictionary:
	"""Ejecuta animación de daño"""
	var result = {"success": true}
	var target = data.get("target")
	var damage = data.get("damage", 0)

	if target:
		await _animations.animate_damage(target, damage)

		# Aplicar daño si la carta tiene método
		if target.has_method("take_damage"):
			target.take_damage(damage)

	return result


func _execute_buff(data: Dictionary) -> Dictionary:
	"""Ejecuta animación de buff/debuff"""
	var result = {"success": true}
	var card = data.get("card")
	var amount = data.get("amount", 0)
	var is_buff = data.get("is_buff", amount > 0)

	if card:
		await _animations.animate_buff(card, amount, is_buff)

	return result


func _execute_heal(data: Dictionary) -> Dictionary:
	"""Ejecuta animación de curación"""
	var result = {"success": true}
	var target = data.get("target")
	var amount = data.get("amount", 0)

	if target:
		await _animations.animate_heal(target, amount)

	return result


func _execute_play_card(data: Dictionary) -> Dictionary:
	"""Ejecuta animación de jugar una carta"""
	var result = {"success": true}
	var card = data.get("card")
	var player_id = data.get("player_id", 0)
	var destination_zone = data.get("destination", Constants.Zone.LINEA_DEFENSA)

	if card:
		await _animations.animate_card_move(card, Constants.Zone.MANO, destination_zone, player_id)
		# Efecto de entrada
		await _animations.animate_enter_play(card)

	return result


func _execute_custom(data: Dictionary) -> Dictionary:
	"""Ejecuta un Callable personalizado"""
	var result = {"success": true}
	var callable: Callable = data.get("callable", Callable())

	if callable.is_valid():
		var custom_result = await callable.call()
		if custom_result is Dictionary:
			result.merge(custom_result, true)

	return result


func _execute_parallel(data: Dictionary) -> Dictionary:
	"""Ejecuta múltiples callables en paralelo"""
	var result = {"success": true, "results": []}
	var callables: Array = data.get("callables", [])

	# Crear array de tareas
	var tasks: Array = []
	for c in callables:
		if c is Callable and c.is_valid():
			tasks.append(c.call())

	# Esperar a que todas terminen
	for task in tasks:
		var task_result = await task
		result.results.append(task_result)

	return result


# =============================================================================
# UTILIDADES
# =============================================================================
func _get_game_board() -> Node:
	"""Obtiene referencia al GameBoard"""
	if GameManager and GameManager.game_board:
		return GameManager.game_board
	return null


func _generate_command_id() -> String:
	"""Genera ID único para comando"""
	return "%d_%d" % [Time.get_ticks_msec(), randi() % 1000]


func get_queue_size() -> int:
	"""Retorna cantidad de comandos pendientes"""
	return command_queue.size()


func is_queue_empty() -> bool:
	"""Verifica si la cola está vacía"""
	return command_queue.is_empty()


func clear_queue() -> void:
	"""Limpia la cola sin ejecutar"""
	command_queue.clear()
	print("[AnimationQueue] Cola limpiada")


func set_speed(speed: float) -> void:
	"""Establece velocidad de animación"""
	animation_speed = clampf(speed, 0.1, 10.0)


func set_delays(between_cards: float, between_batches: float) -> void:
	"""Configura los delays entre animaciones"""
	delay_between_cards = between_cards
	delay_between_batches = between_batches


# =============================================================================
# ANIMACIÓN DE BARAJADO (DAR Sección 8)
# =============================================================================
func queue_shuffle_animation(player_id: int, source: String = "") -> String:
	"""Encola una animación de barajado del Castillo

	DAR Sección 8: Después de buscar en el Castillo, se debe barajar.
	"""
	var batch_id = "shuffle_%d_%d" % [player_id, Time.get_ticks_msec()]

	add_command(CommandType.CUSTOM, {
		"callable": Callable(self, "_animate_shuffle").bind(player_id),
		"description": "Barajar Castillo",
		"batch_id": batch_id,
		"source": source
	})

	print("[AnimationQueue] Encolada animación de barajado (batch: %s)" % batch_id)
	return batch_id


func animate_shuffle(player_id: int) -> void:
	"""Ejecuta animación de barajado directamente (sin encolar)"""
	await _animate_shuffle(player_id)


func _animate_shuffle(player_id: int) -> Dictionary:
	"""Anima el barajado del mazo de un jugador"""
	var result = {"success": true}
	var game_board = _get_game_board()

	if not game_board:
		result.success = false
		return result

	# Obtener el nodo visual del mazo
	var deck_container = game_board.get_zone_container(Constants.Zone.CASTILLO, player_id)

	if not deck_container:
		result.success = false
		return result

	print("[AnimationQueue] Animando barajado del Castillo (Jugador %d)" % (player_id + 1))

	# Animación de barajado: sacudir el mazo
	var duration = 0.5 / animation_speed
	var shake_amount = 8.0
	var shake_count = 5

	var original_pos = deck_container.position if deck_container.get("position") else Vector2.ZERO
	var original_rotation = deck_container.rotation if deck_container.get("rotation") else 0.0

	# Crear tween para la sacudida
	var tween = create_tween()
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.set_trans(Tween.TRANS_SINE)

	# Secuencia de sacudidas
	for i in range(shake_count):
		var offset_x = shake_amount * (1.0 if i % 2 == 0 else -1.0)
		var offset_rotation = 0.05 * (1.0 if i % 2 == 0 else -1.0)

		tween.tween_property(deck_container, "position", original_pos + Vector2(offset_x, 0), duration / (shake_count * 2))
		tween.tween_property(deck_container, "rotation", original_rotation + offset_rotation, duration / (shake_count * 2))

	# Volver a posición original
	tween.tween_property(deck_container, "position", original_pos, duration / 4)
	tween.tween_property(deck_container, "rotation", original_rotation, duration / 4)

	await tween.finished

	# Efecto visual adicional: flash
	if deck_container.get("modulate"):
		var flash_tween = create_tween()
		flash_tween.tween_property(deck_container, "modulate", Color(1.3, 1.3, 1.0, 1), 0.1)
		flash_tween.tween_property(deck_container, "modulate", Color.WHITE, 0.1)
		await flash_tween.finished

	# Barajar el mazo internamente
	if game_board.has_method("shuffle_zone"):
		game_board.shuffle_zone(Constants.Zone.CASTILLO, player_id)
	elif GameManager and GameManager.has_method("shuffle_deck"):
		GameManager.shuffle_deck(player_id)

	print("[AnimationQueue] Barajado completado")
	return result


# =============================================================================
# SEÑAL DE COLA VACÍA (para TurnManager)
# =============================================================================
signal queue_empty  # Emitida cuando la cola queda vacía después de procesar

func wait_until_empty() -> void:
	"""Espera hasta que la cola de animaciones esté vacía

	Uso: await AnimationQueue.wait_until_empty()
	"""
	while is_running or not command_queue.is_empty():
		await get_tree().process_frame

	print("[AnimationQueue] Cola vacía - continuando")
