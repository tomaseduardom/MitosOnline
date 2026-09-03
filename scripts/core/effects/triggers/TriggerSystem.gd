extends Node
## TriggerSystem - Gestiona la cola de habilidades disparadas (DAR 7.4)
## Orden: Primero jugador activo elige orden, luego oponente

# =============================================================================
# SIGNALS
# =============================================================================
signal triggers_pending(active_player_triggers: Array, opponent_triggers: Array)
signal trigger_resolved(card: Node, trigger_type: String, result: Dictionary)
signal trigger_cancelled(card: Node, trigger_type: String, cancelled_by: Node)
signal all_triggers_resolved

# Ventana de respuesta (DAR Sección 8 - Cancelar)
signal waiting_for_responses(trigger: Dictionary, responding_player: int)
signal response_window_closed(trigger: Dictionary, was_cancelled: bool)

# =============================================================================
# ESTADO
# =============================================================================
## Cola de triggers pendientes (se resuelven en orden FIFO)
var trigger_queue: Array[Dictionary] = []

## Triggers recolectados durante un evento (antes de ordenar)
var pending_active_triggers: Array[Dictionary] = []
var pending_opponent_triggers: Array[Dictionary] = []

## Flag para saber si estamos recolectando triggers
var is_collecting: bool = false

## Flag para saber si estamos resolviendo
var is_resolving: bool = false

## Ventana de respuesta
var awaiting_response: bool = false
var current_trigger_for_response: Dictionary = {}
var response_timeout: float = 10.0  # Segundos para responder

## Señales para buffs
signal buff_applied(target: Node, buff: Dictionary)
signal buff_expired(target: Node, buff: Dictionary)
signal buffs_cleared(count: int, duration: String)

## Callback de cancelación pendiente
var pending_cancel_callback: Callable = Callable()

## Módulos extraídos (Fase 4 de reestructuración)
var _resolution: TriggerResolution
var _targeted_executor: TargetedEffectExecutor
var _restrictions: TriggerRestrictions
var _buffs: TemporaryBuffSystem
## Patrones "mira/muestra y juega" (Signo Amarillo, Tangata Manu, Presente,
## Perder la Razón) — sacado de TargetedEffectExecutor.gd (2026-08-28,
## "módulos gordos").
var _look_and_play: LookAndPlayResolver
## Buscador de cartas por nombre para efectos "nombra una carta" (2026-08-29,
## p.ej. Alicia en Wonderland, Tesoro de los Césares). Cargado con preload()
## en vez del nombre de clase global (a diferencia de los módulos de arriba)
## porque es un script nuevo — el editor todavía no lo había escaneado para
## registrar su class_name, y referenciarlo por nombre tiraba "Could not
## find type" hasta el próximo reimport manual del proyecto.
const CardNameSearchDialogScript = preload("res://scripts/ui/selection/CardNameSearchDialog.gd")
var _card_name_search: RefCounted
## Familias de patrones "try_execute_*_pattern" extraídas de
## TargetedEffectExecutor.gd (2026-08-30, "módulos gordos") — mismo corte
## que ya separó LookAndPlayResolver.gd de este mismo archivo. preload()
## en vez del nombre de clase global: son scripts NUEVOS de esta sesión, ver
## el comentario de arriba sobre CardNameSearchDialogScript.
const DrawShuffleResolverScript = preload("res://scripts/core/effects/triggers/DrawShuffleResolver.gd")
const ConvertAndMiscResolverScript = preload("res://scripts/core/effects/triggers/ConvertAndMiscResolver.gd")
var _draw_shuffle_resolver: RefCounted
var _convert_misc_resolver: RefCounted


func _ready() -> void:
	_resolution = TriggerResolution.new()
	_resolution.setup(self)
	_targeted_executor = TargetedEffectExecutor.new()
	_targeted_executor.setup(self)
	_draw_shuffle_resolver = DrawShuffleResolverScript.new()
	_draw_shuffle_resolver.setup(_targeted_executor)
	_convert_misc_resolver = ConvertAndMiscResolverScript.new()
	_convert_misc_resolver.setup(_targeted_executor)
	_restrictions = TriggerRestrictions.new()
	_restrictions.setup(self)
	_buffs = TemporaryBuffSystem.new()
	_buffs.setup(self)
	_look_and_play = LookAndPlayResolver.new()
	_look_and_play.setup(self)
	_card_name_search = CardNameSearchDialogScript.new()
	_card_name_search.setup(self)

	# Conectar a señales de EffectController para recolectar triggers.
	# on_card_entered_play y on_card_attacks NO se conectan acá — esos dos
	# los llama el código que juega/ataca directamente (GoldManager,
	# GameManager) con 'await', para que el trigger termine de resolverse
	# ANTES de que el juego siga de fase. Conectados por señal (fire-and-
	# forget, como el resto de abajo) el emisor no espera a que el handler
	# async termine, y el trigger podía resolverse varias fases después de
	# jugarse la carta (se vio con Drácula y Signo Amarillo resolviendo en
	# Bloqueo). Ver _collect_triggers_for_event(), llamado directo con await.
	if EffectController:
		EffectController.on_card_drawn.connect(_on_global_event.bind("on_card_drawn"))
		EffectController.on_card_milled.connect(_on_global_event_with_dest.bind("on_card_milled"))
		EffectController.on_card_discarded.connect(_on_global_event.bind("on_discard"))
		EffectController.on_card_left_play.connect(_on_global_event_with_zone.bind("on_leave_play"))
		EffectController.on_card_destroyed.connect(_on_global_event.bind("on_destroyed"))
		EffectController.on_card_exiled.connect(_on_global_event.bind("on_exiled"))


# =============================================================================
# RECOLECCIÓN DE TRIGGERS
# =============================================================================
func begin_collecting() -> void:
	"""Inicia la recolección de triggers para un evento"""
	is_collecting = true
	pending_active_triggers.clear()
	pending_opponent_triggers.clear()


func end_collecting_and_queue() -> void:
	"""Finaliza recolección y encola los triggers en orden correcto (DAR 7.4)"""
	is_collecting = false

	if pending_active_triggers.is_empty() and pending_opponent_triggers.is_empty():
		return

	var active_player = GameManager.active_player_id if GameManager else 0

	# Notificar que hay triggers pendientes
	emit_signal("triggers_pending", pending_active_triggers, pending_opponent_triggers)

	# Si hay múltiples triggers del jugador activo, ELIGE el orden (DAR 7.4:
	# el dueño de varios triggers simultáneos decide en qué orden resuelven
	# — 2026-08-30, a pedido del usuario: p.ej. Espada de O'Higgins y
	# Capitán O'Brien disparando juntos en Fase Final, donde puede importar
	# barajar el Cementerio con uno ANTES de robar con el otro. Antes esto
	# era un TODO sin implementar — emitía trigger_ordering_requested pero
	# nadie lo escuchaba nunca, así que siempre caía a 'orden de llegada'
	# silenciosamente). Solo el jugador humano elige por ahora, mismo
	# criterio ya establecido para el resto de decisiones interactivas de
	# esta sesión — el oponente sigue en orden de llegada.
	if pending_active_triggers.size() > 1 and active_player == 0:
		pending_active_triggers = await _prompt_trigger_order(pending_active_triggers)

	# Añadir triggers del jugador activo primero
	for trigger in pending_active_triggers:
		trigger_queue.append(trigger)

	# Añadir triggers del oponente después (orden de llegada — el bot no
	# elige todavía)
	for trigger in pending_opponent_triggers:
		trigger_queue.append(trigger)

	print("[TriggerSystem] Cola de triggers: %d total" % trigger_queue.size())


func _prompt_trigger_order(triggers: Array[Dictionary]) -> Array[Dictionary]:
	"""Deja elegir al jugador el orden de resolución entre varios triggers
	simultáneos propios — reutiliza que SelectionManager.await_multi_pick()
	preserva el ORDEN DE CLICK (mismo truco que usa Infernum Vox para
	'mirar 6 y repartir/ordenar entre tope y fondo'): forzar max=min=total
	convierte la selección en un simple 'elegí el orden clickeando', sin
	necesitar ninguna UI de arrastre nueva.
	Returns: los mismos triggers, en el orden elegido (o el orden original
	si algo falla, para no perder ningún trigger en el camino).

	2026-09-02: firma corregida de Array genérico a Array[Dictionary] — el
	llamador (end_collecting_and_queue()) asigna el resultado directo a
	pending_active_triggers, que SÍ está tipado Array[Dictionary]; GDScript
	rechaza en tiempo de ejecución asignar un Array sin tipar a una variable
	tipada, aunque el contenido real fueran todo Dictionary."""
	var candidates: Array[Dictionary] = []
	var by_data: Dictionary = {}
	for t in triggers:
		var card: Node = t.get("card")
		if not is_instance_valid(card) or card.get("card_data") == null:
			return triggers  # falta algo para armar el picker — no arriesgar el orden
		var data: Dictionary = card.card_data
		candidates.append(data)
		by_data[data] = t

	var result: Dictionary = await SelectionManager.await_multi_pick(
		candidates, "Elige el orden en que se resuelven (primero la que quieras que actúe antes)",
		candidates.size(), candidates.size(), false)

	var ordered: Array[Dictionary] = []
	for data in result.picked:
		if by_data.has(data):
			ordered.append(by_data[data])
	return ordered if ordered.size() == triggers.size() else triggers


func register_trigger(card: Node, trigger_type: String, event_data: Dictionary) -> void:
	"""Registra un trigger disparado por una carta"""
	var trigger_data = {
		"card": card,
		"trigger_type": trigger_type,
		"event_data": event_data,
		"controller_id": card.controller_id if card.get("controller_id") != null else 0
	}

	var active_player = GameManager.active_player_id if GameManager else 0

	if is_collecting:
		# Durante recolección, separar por jugador
		if trigger_data.controller_id == active_player:
			pending_active_triggers.append(trigger_data)
		else:
			pending_opponent_triggers.append(trigger_data)
	else:
		# Fuera de recolección, añadir directo a la cola
		trigger_queue.append(trigger_data)


# =============================================================================
# RESOLUCIÓN DE TRIGGERS (implementación en TriggerResolution.gd, con
# ejecución de efectos con objetivo en TargetedEffectExecutor.gd)
# =============================================================================
func resolve_next_trigger() -> Dictionary:
	return await _resolution.resolve_next_trigger()


func cancel_current_trigger(cancelling_card: Node = null) -> bool:
	return _resolution.cancel_current_trigger(cancelling_card)


func pass_response() -> void:
	_resolution.pass_response()


func resolve_all_triggers() -> void:
	await _resolution.resolve_all_triggers()


func has_pending_triggers() -> bool:
	return _resolution.has_pending_triggers()


func clear_triggers() -> void:
	_resolution.clear_triggers()


func resolve_talisman(card: Node) -> void:
	"""Resuelve el efecto impreso de un Talismán al jugarlo (DAR Sección 8).
	A diferencia de una habilidad disparada (Sección 7.4), un Talismán no
	'dispara' nada — su texto ES el efecto de jugarlo, se resuelve directo
	acá, sin pasar por has_trigger(), register_trigger() ni la cola
	compartida de triggers (2026-08-27, a pedido del usuario). Llamado
	desde GoldManager._trigger_enter_play() para cartas tipo TALISMAN."""
	if not is_instance_valid(card):
		return
	var ability_text: String = card.get("card_ability") if card.get("card_ability") != null else ""
	if ability_text.is_empty():
		return
	var controller_id: int = card.get("owner_id") if card.get("owner_id") != null else 0
	await _resolution._resolve_look_and_play_patterns(card, ability_text, ability_text, controller_id, {"card": card})


# =============================================================================
# HANDLERS DE EVENTOS GLOBALES
# =============================================================================
func _on_global_event(player_id: int, card: Node, event_type: String) -> void:
	"""Handler genérico para eventos de 2 parámetros"""
	_collect_triggers_for_event(event_type, {
		"player_id": player_id,
		"card": card
	})


func _on_global_event_with_zone(player_id: int, card: Node, zone: int, event_type: String) -> void:
	"""Handler para eventos con zona"""
	_collect_triggers_for_event(event_type, {
		"player_id": player_id,
		"card": card,
		"zone": zone
	})


func _on_global_event_with_dest(player_id: int, card: Node, destination: int, event_type: String) -> void:
	"""Handler para eventos con destino"""
	_collect_triggers_for_event(event_type, {
		"player_id": player_id,
		"card": card,
		"destination": destination
	})


func _collect_triggers_for_event(event_type: String, event_data: Dictionary) -> void:
	"""Recolecta todos los triggers que responden a un evento.

	GUARDIA DE REENTRADA (2026-08-16): esta función se llama con 'await' desde
	varios sitios (GoldManager al jugar una carta, GameManager al declarar un
	atacante). trigger_queue/pending_* son variables de módulo COMPARTIDAS —
	si un jugador dispara un segundo evento (p.ej. declara un ataque) mientras
	la ventana de respuesta del trigger anterior (p.ej. 'roba 2' de un oro
	recién jugado) sigue abierta, la segunda llamada empezaba a recolectar y
	encolar SOBRE la misma cola que el primer resolve_all_triggers() todavía
	estaba vaciando en su propio bucle — dos bucles compitiendo por el mismo
	trigger_queue. Resultado real reportado: el efecto del oro se resolvía
	recién al intentar atacar, y la ventana de prioridad quedaba en un estado
	que ya no dejaba pasar. Se espera a que la recolección/resolución anterior
	termine antes de empezar una nueva — así siempre queda serializado."""
	# Reentrada segura (2026-08-23): si esta llamada ocurre DENTRO de la
	# resolución de otro trigger (p.ej. Lobo Sagrado equipa un Arma cuyo
	# propio 'cuando entra en juego' dispara este mismo camino vía
	# _trigger_enter_play), esperar a que is_resolving baje a false es un
	# DEADLOCK: is_resolving no baja hasta que ESTA MISMA llamada anidada
	# retorne, porque es parte de la cadena de await de la resolución
	# externa. Confirmado con log real: Lobo Sagrado nunca robaba las 2
	# cartas (el código quedaba después de este punto sin ejecutarse jamás),
	# y cualquier otro trigger posterior tampoco podía avanzar. Distinguir
	# la reentrada es seguro: is_collecting solo es true durante un tramo
	# 100% síncrono (sin ningún await) de esta función, así que una llamada
	# anidada real solo puede darse con is_collecting ya en false — se sigue
	# esperando si hay una recolección concurrente genuina en curso, pero
	# nunca por estar anidada dentro de su propia resolución.
	var is_nested_reentry := is_resolving and not is_collecting
	if not is_nested_reentry:
		# Salvaguarda (2026-08-26): esta espera estaba pensada para durar como
		# mucho unos pocos frames (una recolección/resolución concurrente
		# real). Causa raíz real encontrada y corregida (ver "camino
		# completo" más abajo: _get_related_triggers() recibía una
		# event_card ya liberada sin chequeo de validez, tiraba un error de
		# tipo y cortaba la función antes de llegar a
		# end_collecting_and_queue() — is_collecting quedaba en true para
		# siempre y esta espera colgaba TODOS los triggers del resto de la
		# partida en silencio). Se deja igual esta salvaguarda de 3s como
		# defensa extra ante cualquier otro error no previsto en ese mismo
		# tramo síncrono: fuerza el reset y avisa por consola en vez de
		# trabar el juego entero.
		var waited := 0.0
		while (is_collecting or is_resolving) and waited < 3.0:
			await get_tree().process_frame
			waited += get_process_delta_time()
		if is_collecting or is_resolving:
			push_warning("[TriggerSystem] is_collecting/is_resolving atascado >3s — forzando reset (ver causa raíz pendiente)")
			is_collecting = false
			is_resolving = false
	begin_collecting()

	var event_card = event_data.get("card", null)

	# ── Camino directo: el propio disparador de la carta del evento ────────
	# (p.ej. "Cuando entra en juego" de la carta que se acaba de jugar). No
	# depende de GameManager.game_board — ese es el GameBoard legacy huérfano
	# (docs/audit-2026-08-13.html, hallazgo 2/4), nunca registrado en la
	# escena real; exigirlo aquí hacía que NINGUNA carta disparara NUNCA
	# ningún trigger por este camino.
	if event_card and is_instance_valid(event_card) and event_card.has_method("has_trigger"):
		if event_card.has_trigger(event_type):
			if _check_trigger_conditions(event_card, event_type, event_data):
				register_trigger(event_card, event_type, event_data)

	# ── Camino completo: triggers de OTRAS cartas que reaccionan a este
	# evento (p.ej. "Cuando otro Aliado entre al juego..."). Antes dependía
	# de GameManager.game_board (el GameBoard legacy huérfano, siempre null)
	# y nunca se ejecutaba — usa el campo real de Main (un solo contenedor
	# por jugador, no hay zonas separadas de Defensa/Ataque/Apoyo).
	#
	# CORRECCIÓN (2026-08-17): este bucle también revisaba si OTRAS cartas
	# tenían el mismo event_type ("on_enter_play", "on_attack", etc.) que
	# la carta que disparó el evento — pero esos triggers son propios de
	# CADA carta ("cuando ESTA carta entra en juego"), no algo que otra
	# carta deba compartir solo por tener una frase parecida en su propio
	# texto. Resultado real: cada vez que se jugaba una carta nueva, TODAS
	# las demás cartas del campo con su propio 'cuando entra en juego' (ya
	# resuelto hace turnos) volvían a dispararse. Solo debe revisarse
	# related_triggers (p.ej. on_ally_enters), que sí está pensado para
	# difundirse a otras cartas bajo un trigger_type distinto.
	var main = get_node_or_null("/root/Main")
	if main:
		# event_card puede llegar ya liberada (p.ej. una carta que salió de
		# juego) — _get_related_triggers() declara 'event_card: Node'
		# tipado, y pasarle una instancia liberada tira un error de tipo en
		# Godot ("previously freed") que corta la función ACÁ MISMO, antes
		# de llegar a end_collecting_and_queue() (2026-08-26 — causa real de
		# que is_collecting quedara trabado en true para siempre y ningún
		# trigger volviera a dispararse en lo que quedaba de partida). El
		# "camino directo" de arriba ya tenía este chequeo, este bloque no.
		var safe_event_card: Node = event_card if is_instance_valid(event_card) else null
		var related_triggers = _get_related_triggers(event_type, safe_event_card)

		if not related_triggers.is_empty():
			for player_id in [0, 1]:
				var fields = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo] if player_id == 0 \
					else [main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
				for field in fields:
					if not field:
						continue
					for card in field.get_children():
						if card == event_card:
							continue  # ya se registró arriba
						if not card.has_method("has_trigger"):
							continue
						for related in related_triggers:
							if card.has_trigger(related):
								if _check_trigger_conditions(card, related, event_data):
									register_trigger(card, related, event_data)

	await end_collecting_and_queue()

	# Si hay triggers, resolverlos — con 'await': sin esto, esta función
	# volvía a quien la llamó apenas EMPEZABA a resolver, no cuando terminaba
	# (ese era el resto del bug de Drácula/Signo Amarillo resolviendo fases
	# después de jugarse — la cadena de espera se cortaba justo acá).
	#
	# EXCEPTO si esta recolección fue anidada (ver guardia de reentrada más
	# arriba): en ese caso NO se llama a resolve_all_triggers() de nuevo —
	# el bucle externo que nos contiene (TriggerResolution.resolve_all_
	# triggers, un 'while not trigger_queue.is_empty()') ya sigue drenando
	# la cola sola y va a recoger lo que acabamos de encolar en su próxima
	# vuelta, apenas esta cadena de await retorne. Lanzar OTRO
	# resolve_all_triggers() acá competiría por la misma cola compartida.
	if not is_nested_reentry and has_pending_triggers():
		await resolve_all_triggers()


func resolve_turn_end_triggers(player_id: int) -> void:
	"""Dispara 'En tu Fase Final'/'Al final del turno' (on_turn_end) para
	CADA carta que el jugador controla y tenga este trigger (2026-08-30,
	p.ej. Espada de O'Higgins) — llamar al ENTRAR a Fase Final, antes del
	robo/límite de mano normales (PhaseFlowController._resolve_fase_final()).
	A diferencia de on_enter_play/on_attack/etc. (una carta puntual
	dispara por algo que le pasó a ELLA), Fase Final es un evento de FASE
	que puede afectar a varias cartas en juego a la vez — no tiene sentido
	forzarlo por _collect_triggers_for_event() (pensada para un event_card
	puntual + 'triggers relacionados' de otras cartas, un concepto
	distinto). Reusa los mismos primitivos de siempre (begin_collecting/
	register_trigger/end_collecting_and_queue/resolve_all_triggers) en vez
	de inventar un camino de resolución aparte."""
	var main = get_node_or_null("/root/Main")
	if not main:
		return
	var fields = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo] if player_id == 0 \
		else [main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]

	var waited := 0.0
	while (is_collecting or is_resolving) and waited < 3.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	if is_collecting or is_resolving:
		push_warning("[TriggerSystem] is_collecting/is_resolving atascado >3s en resolve_turn_end_triggers — forzando reset")
		is_collecting = false
		is_resolving = false

	begin_collecting()
	var event_data := {"player_id": player_id}
	for field in fields:
		if not field:
			continue
		for card in field.get_children():
			if not is_instance_valid(card) or not card.has_method("has_trigger"):
				continue
			if card.has_trigger("on_turn_end") and _check_trigger_conditions(card, "on_turn_end", event_data):
				register_trigger(card, "on_turn_end", event_data)
			var weapons = card.get("equipped_weapons")
			if weapons is Array:
				for w in weapons:
					if is_instance_valid(w) and w.has_method("has_trigger") and w.has_trigger("on_turn_end") \
							and _check_trigger_conditions(w, "on_turn_end", event_data):
						register_trigger(w, "on_turn_end", event_data)
	await end_collecting_and_queue()

	if has_pending_triggers():
		await resolve_all_triggers()


func resolve_agrupacion_triggers(player_id: int) -> void:
	"""Dispara 'En tu Agrupación' (on_agrupacion) para CADA carta que el
	jugador controla y tenga este trigger (2026-08-30, p.ej. Espada del
	Juicio: 'Cuando entra en juego y en tu Agrupación, Destierra...') —
	llamar al ENTRAR a la fase Agrupación (PhaseFlowController). Mismo
	patrón que resolve_turn_end_triggers(), copiado tal cual en vez de
	parametrizado: es un evento de FASE distinto (no un event_card puntual
	de _collect_triggers_for_event())."""
	var main = get_node_or_null("/root/Main")
	if not main:
		return
	var fields = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo] if player_id == 0 \
		else [main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]

	var waited := 0.0
	while (is_collecting or is_resolving) and waited < 3.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	if is_collecting or is_resolving:
		push_warning("[TriggerSystem] is_collecting/is_resolving atascado >3s en resolve_agrupacion_triggers — forzando reset")
		is_collecting = false
		is_resolving = false

	begin_collecting()
	var event_data := {"player_id": player_id}
	for field in fields:
		if not field:
			continue
		for card in field.get_children():
			if not is_instance_valid(card) or not card.has_method("has_trigger"):
				continue
			if card.has_trigger("on_agrupacion") and _check_trigger_conditions(card, "on_agrupacion", event_data):
				register_trigger(card, "on_agrupacion", event_data)
			var weapons = card.get("equipped_weapons")
			if weapons is Array:
				for w in weapons:
					if is_instance_valid(w) and w.has_method("has_trigger") and w.has_trigger("on_agrupacion") \
							and _check_trigger_conditions(w, "on_agrupacion", event_data):
						register_trigger(w, "on_agrupacion", event_data)
	await end_collecting_and_queue()

	if has_pending_triggers():
		await resolve_all_triggers()


func _get_related_triggers(event_type: String, event_card: Node) -> Array:
	"""Retorna triggers relacionados que se activan con un evento"""
	var related: Array = []

	# Si una carta entra al juego y es un aliado
	if event_type == "on_enter_play":
		if event_card and event_card.get("card_type") == Constants.CardType.ALIADO:
			related.append("on_ally_enters")

	# Si una carta es destruida y es un aliado
	if event_type == "on_destroyed":
		if event_card and event_card.get("card_type") == Constants.CardType.ALIADO:
			related.append("on_ally_dies")

	return related


func _check_trigger_conditions(card: Node, trigger_type: String, event_data: Dictionary) -> bool:
	"""Verifica las condiciones del trigger"""
	if KeywordManager.is_silenced(card):
		return false
	if _named_trigger_already_used_this_turn(card):
		return false
	if card.has_method("_trigger_conditions_met"):
		return card._trigger_conditions_met(trigger_type, event_data)
	return true


func _named_trigger_already_used_this_turn(card: Node) -> bool:
	"""'Solo puedes utilizar la habilidad de X una vez por turno' aplicado a
	un TRIGGER, no a una habilidad ACTIVADA (2026-08-30, p.ej. Tangata
	Manu: su 'Cuando entra en juego' puede jugar gratis OTRA copia de sí
	mismo desde el Castillo, cuyo propio 'Cuando entra en juego' volvería a
	dispararse sin este chequeo — la restricción del texto es por NOMBRE,
	compartida entre TODAS las copias que entren ese turno, no por
	instancia. turn_registry ya evita el reuso de una habilidad ACTIVADA
	por card_id/ability_index (CardInspectionLayer._validate_ability()),
	pero nunca se consultaba desde acá para TRIGGERs — este es el único
	choke point real por el que pasa cualquier trigger antes de encolarse
	(ver register_trigger() más abajo), así que alcanza con chequear Y
	registrar acá mismo, una sola vez por intento de disparo real."""
	if card.get("card_data") == null:
		return false
	var habilidad_text: String = card.card_data.get("habilidad", "")
	if habilidad_text.is_empty():
		return false
	var card_id: String = str(card.card_data.get("id", ""))
	var all_parsed := UniversalCardParser.parse_abilities(habilidad_text, card_id)
	var has_named_once_trigger := false
	for entry in all_parsed:
		if entry.get("ability_type", "") == "TRIGGER" and entry.get("once_per_turn", false):
			has_named_once_trigger = true
			break
	if not has_named_once_trigger:
		return false

	var card_name: String = str(card.card_data.get("nombre", "")).to_lower()
	if card_name.is_empty():
		return false
	# Prefijo 'trigger_once:' (2026-08-30) para no compartir namespace con
	# el registro de habilidades ACTIVADAS, que usa card_id/ability_index
	# numéricos — un nombre de carta nunca podría colisionar con esa clave,
	# pero el prefijo lo deja explícito.
	var name_key: String = "trigger_once:%s" % card_name
	var turn: int = GameManager.current_turn
	if UniversalCardParser.turn_registry.was_used(name_key, 0, turn):
		return true
	UniversalCardParser.turn_registry.register(name_key, 0, turn)
	return false


# =============================================================================
# EFECTOS CONTINUOS Y PRIORIDAD NEGATIVA (implementación en
# TriggerRestrictions.gd)
# =============================================================================
func register_continuous_effect(source_card: Node, effect: Dictionary) -> void:
	_restrictions.register_continuous_effect(source_card, effect)


func unregister_continuous_effect(source_card: Node) -> void:
	_restrictions.unregister_continuous_effect(source_card)


func get_active_continuous_effects(filter_type: String = "") -> Array:
	return _restrictions.get_active_continuous_effects(filter_type)


func check_continuous_prevention(action_type: String, target: Node = null) -> Dictionary:
	return _restrictions.check_continuous_prevention(action_type, target)


# =============================================================================
# UTILIDADES PARA CALLABLE EN CARTAS
# =============================================================================
func create_trigger_handler(card: Node) -> Callable:
	"""Crea un handler de triggers para una carta
	Usado cuando la carta entra al juego para conectar dinámicamente
	"""
	return func(trigger_type: String, event_data: Dictionary) -> Dictionary:
		return await card._on_trigger_event(trigger_type, event_data)


func bind_card_to_triggers(card: Node) -> void:
	"""Vincula una carta al sistema de triggers cuando entra al juego
	Llama a _on_trigger_event de la carta con Callable
	"""
	if not card.has_method("_on_trigger_event"):
		return

	# Parsear triggers del texto de habilidad
	if card.has_method("parse_triggers_from_ability"):
		card.parse_triggers_from_ability()

	print("[TriggerSystem] Carta %s vinculada al sistema de triggers" % card.card_name)


# =============================================================================
# SISTEMA DE BUFFS/DEBUFFS TEMPORALES (implementación en
# TemporaryBuffSystem.gd)
# =============================================================================
func apply_buff(source: Node, target: Node, buff_type: String, value: int, duration: String = "this_turn") -> Dictionary:
	return _buffs.apply_buff(source, target, buff_type, value, duration)


func remove_buff(buff_id: String) -> bool:
	return _buffs.remove_buff(buff_id)


func remove_buffs_from_source(source: Node) -> int:
	return _buffs.remove_buffs_from_source(source)


func remove_buffs_from_target(target: Node) -> int:
	return _buffs.remove_buffs_from_target(target)


func clear_expired_buffs(duration: String) -> int:
	return _buffs.clear_expired_buffs(duration)


func get_buffs_on_target(target: Node) -> Array[Dictionary]:
	return _buffs.get_buffs_on_target(target)


func get_total_modifier(target: Node, buff_type: String) -> int:
	return _buffs.get_total_modifier(target, buff_type)


func has_buff_type(target: Node, buff_type: String) -> bool:
	return _buffs.has_buff_type(target, buff_type)


# =============================================================================
# FORWARDERS - TargetedEffectExecutor
# =============================================================================
func _execute_parsed_action(action: Dictionary, card: Node, event_data: Dictionary) -> void:
	await _targeted_executor.execute_parsed_action(action, card, event_data)


func resolve_ability_effect(card: Node, effect_text: String, controller_id: int) -> bool:
	"""Resuelve el texto de efecto de una habilidad — disparada o activada
	(2026-08-27, a pedido del usuario: 'las habilidades también se
	resuelven, sean disparadas o activadas', mismo concepto que ya se
	aplicó a Talismanes). Antes StackStepResolver._resolve_ability() (el
	camino real de las habilidades ACTIVADAS, vía ActionPipeline) solo
	probaba extract_action() simple, sin los patrones compuestos ("mira/
	muestra N...") que sí usan las disparadas — una habilidad activada con
	ese tipo de efecto nunca resolvía bien. Ahora las dos comparten
	_resolve_look_and_play_patterns().
	Returns: true si se ejecutó algo."""
	return await _resolution._resolve_look_and_play_patterns(card, effect_text, effect_text, controller_id, {})


func _select_hand_cards_for_discard(hand_cards: Array, amount: int) -> Array:
	return await _targeted_executor._select_hand_cards_for_discard(hand_cards, amount)
