extends Node
class_name CardInteractionModule
## CardInteractionModule — Gestiona clicks, hover y arrastre de cartas.
## Se instancia como hijo de Main en _ready().

var _main: Node = null

var selected_card: Node = null
var is_placing_gold: bool = false
var _card_clicked_this_frame: bool = false
var _opponent_card_original_pos: Dictionary = {}
## Traba de reentrada por carta para _declare_attacker() (2026-08-23):
## la función es async con varios await ANTES de llegar a
## GameManager.attackers.append() — un segundo click (p.ej. el eco de
## card_double_clicked sobre un Aliado ya en juego) podía entrar de nuevo
## mientras el primero seguía en vuelo, ganándole la carrera a
## GameManager.declare_attacker() y quedando rechazado con 'no puede
## atacar todavía' aunque el primero sí se hubiera declarado bien.
var _declaring_attackers: Dictionary = {}

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
## Si false, ESC no cancela la selección en curso (2026-09-13, a pedido del
## usuario — ver §10.29: una selección MANDATORIA, p.ej. "Descarta N
## cartas" sin "puedes", no debe poder esquivarse con ESC como si fuera un
## costo opcional). Default true preserva el comportamiento de siempre.
var _selection_cancellable: bool = true
## "Seleccionar todo" para await_multi_target() (2026-09-13, Abrazo de Maipú)
## — ver request_select_all() y el docstring de await_multi_target().
var _select_all_requested: bool = false
## Debounce del eco de doble-click (ver _resolve_target_selection): un
## double-click real dispara PRIMERO card_clicked (press 1) y LUEGO
## card_double_clicked (press 2, mismo gesto) — si press 1 ya resolvió la
## selección, press 2 no debe caer en "Solo puedes jugar cartas de la mano".
var _last_resolved_target: Node = null
var _last_resolved_at_ms: int = -100000
## Cartas a las que start_target_selection() les forzó can_interact=true
## (2026-09-14, bug real reportado por el usuario: eligiendo objetivo para
## Capitán O'Brien —'Convertir un Oro o una carta de coste 2 o menos', DAR
## Sección 8, objetivo propio o enemigo— el click izquierdo sobre el Aliado
## RIVAL no hacía absolutamente nada, ni siquiera el mensaje de "objetivo no
## válido"; tuvo que targetear su propio Aliado como única forma de
## continuar). Causa real: Card.on_gui_input() corta el click IZQUIERDO por
## completo si can_interact es false (línea "Otras interacciones requieren
## can_interact") — el evento nunca llega a _on_card_clicked(), así que ni
## el filtro ni el mensaje de error se ejecutan nunca. Las cartas PROPIAS
## quedan can_interact=true apenas terminan de entrar en juego, pero nada
## garantizaba lo mismo para las del RIVAL en todo momento (a diferencia de
## los pickers de mano/Cementerio, que sí lo fuerzan explícitamente al
## construir sus nodos temporales — ver ZoneViewerModule/HandCementerio
## AbilityHandler/SearchAbilityHandler_JV). Se guarda aquí qué cartas se
## forzaron para poder devolverlas a su estado real al cerrar la selección
## (nunca se toca una carta que YA estaba en true).
var _forced_interact_cards: Array = []
## Cartas con el brillo celeste "objetivo válido" prendido por una selección
## de UN solo objetivo (2026-09-15, a pedido del usuario: await_target() no
## tenía ningún indicador visual de candidatos — solo await_multi_target()
## lo tenía — así que no había forma de distinguir a simple vista "no hay
## ningún objetivo rival válido" de "el bug de targeting volvió"). Ver
## _glow_valid_targets()/_unglow_target_cards().
var _glowing_target_cards: Array = []
## Puente para selecciones de objetivo cuyos candidatos del Cementerio NO
## viven en ningún contenedor real del tablero (2026-09-25, bug real
## reportado por el usuario: "con lobo sagrado no me permite jugar armas
## del cementerio" — el jugador clickeaba el visor de Cementerio de
## SIEMPRE, que no sabía nada de la selección pendiente y probaba Exhumar
## en su lugar). Nodos temporales tipo Lobo Sagrado (WeaponSearchShuffle
## Executor._execute_play_weapon_discount_draw()) se registran aquí antes
## de abrir la selección — ZoneViewerModule._on_exhumar_card_clicked()
## los consulta ANTES de intentar Exhumar, y si el Dictionary clickeado
## coincide con uno de estos Nodos (misma referencia de card_data),
## resuelve la selección real en vez de la acción de Exhumar.
var _cemetery_target_nodes: Array = []


func try_resolve_cemetery_click(card_data: Dictionary) -> bool:
	"""Ver _cemetery_target_nodes arriba. Devuelve true si el click se
	resolvió como parte de una selección de objetivo pendiente (el
	llamador no debe seguir con su propia lógica de Exhumar/etc.)."""
	if not is_selecting_target or _cemetery_target_nodes.is_empty():
		return false
	for c in _cemetery_target_nodes:
		if is_instance_valid(c) and c.get("card_data") == card_data:
			_resolve_target_selection(c)
			return true
	return false


func setup(main: Node) -> void:
	_main = main


func _force_board_interactable() -> void:
	"""Fuerza can_interact=true en toda carta de campo (ambos jugadores,
	Línea de Defensa/Ataque/Apoyo + Reserva/Pagado de Oro) que no lo tuviera
	ya, mientras dura una selección de objetivo. Barrido amplio a propósito
	(no evalúa el filtro aquí): el filtro real se sigue aplicando en
	_resolve_target_selection() al clickear, así que forzar de más solo
	habilita el click en cartas que de todos modos van a ser rechazadas con
	el mensaje normal — evita mantener una lista paralela de contenedores
	por cada llamador distinto de await_target()/await_multi_target()."""
	if not _main:
		return
	var containers: Array = []
	for name in ["player_field", "player_linea_ataque", "player_linea_apoyo",
			"opponent_field", "opponent_linea_ataque", "opponent_linea_apoyo",
			"player_gold", "opponent_gold", "player_oro_pagado", "opponent_oro_pagado"]:
		var container = _main.get(name)
		if container:
			containers.append(container)
	for container in containers:
		for c in container.get_children():
			if is_instance_valid(c) and c.get("can_interact") == false:
				c.can_interact = true
				_forced_interact_cards.append(c)


func _restore_board_interactable() -> void:
	"""Contraparte de _force_board_interactable() — se llama al cerrar la
	selección (objetivo resuelto, cancelado, o 'seleccionar todo')."""
	for c in _forced_interact_cards:
		if is_instance_valid(c):
			c.can_interact = false
	_forced_interact_cards.clear()


func _glow_color_for_owner(c: Node) -> Color:
	"""Celeste para tus propias cartas, rojo para las del rival (2026-09-15,
	a pedido del usuario: antes TODO objetivo válido brillaba dorado sin
	distinguir de quién es — ahora el color mismo dice 'tuya' o 'rival' de
	un vistazo, sin tener que leer el owner_id)."""
	if c.get("owner_id") == 0:
		return CardBadges.GLOW_COLOR_CELESTE
	return CardBadges.GLOW_COLOR_RED


func _glow_valid_targets(filter: Callable) -> void:
	"""Prende el brillo 'objetivo válido' (CardBadges.set_activatable(), el
	mismo indicador que ya usa await_multi_target()) en toda carta
	candidata real de una selección de UN solo objetivo (2026-09-15, a
	pedido del usuario: sin esto no había forma VISUAL de distinguir 'no hay
	ningún objetivo rival válido ahora mismo' de 'el bug de targeting
	volvió' — await_target() nunca mostraba ningún indicador, a diferencia
	de await_multi_target()). Celeste/rojo según dueño — ver _glow_color_
	for_owner(). A diferencia de _force_board_interactable() (que fuerza
	can_interact de más a propósito, sin mirar el filtro), aquí SÍ se evalúa
	el filtro real — es puramente visual, no cambia qué click es válido.
	Barre las mismas 10 zonas de tablero que _force_board_interactable()
	más mano/abanico rival, ya que await_target() también se usa para
	elegir cartas de la mano (p.ej. Golpe Solar)."""
	if not filter.is_valid() or not _main:
		return
	for name in ["player_field", "player_linea_ataque", "player_linea_apoyo",
			"opponent_field", "opponent_linea_ataque", "opponent_linea_apoyo",
			"player_gold", "opponent_gold", "player_oro_pagado", "opponent_oro_pagado"]:
		var container = _main.get(name)
		if not container:
			continue
		for c in container.get_children():
			if is_instance_valid(c) and c.has_method("set_activatable") and filter.call(c):
				c.set_activatable(true, _glow_color_for_owner(c), &"target_select")
				_glowing_target_cards.append(c)
	for hand_name in ["player_hand", "_opponent_fan"]:
		var hand = _main.get(hand_name)
		if not hand or not hand.get("cards"):
			continue
		for c in hand.cards:
			if is_instance_valid(c) and c.has_method("set_activatable") and filter.call(c):
				c.set_activatable(true, _glow_color_for_owner(c), &"target_select")
				_glowing_target_cards.append(c)


func _unglow_target_cards() -> void:
	"""Contraparte de _glow_valid_targets() — apaga el brillo de todo lo que
	se prendió, sin importar si el objetivo se resolvió o se canceló."""
	for c in _glowing_target_cards:
		if is_instance_valid(c) and c.has_method("set_activatable"):
			c.set_activatable(false, CardBadges.GLOW_COLOR_GOLD, &"target_select")
	_glowing_target_cards.clear()


func request_select_all() -> void:
	"""Llamar desde un botón "Seleccionar todo" mientras await_multi_target()
	está esperando un click — en el próximo frame, todo lo que quede
	elegible (respetando lock_group_key/dynamic_filter si están activos)
	se toma de una sola vez. No hace nada si no hay una selección múltiple
	en curso (la próxima vuelta del while de await_multi_target() consume
	el flag; si nadie lo hace, se pierde en silencio, sin efecto)."""
	_select_all_requested = true


func start_target_selection(prompt: String, filter: Callable, on_selected: Callable, cancellable: bool = true) -> void:
	"""Activa el modo de selección de objetivo.
	filter: Callable(card) -> bool — decide si esa carta es un objetivo legal.
	on_selected: Callable(card) — se llama con la carta elegida al resolver.
	cancellable: false para selecciones MANDATORIAS (ver _selection_
	cancellable arriba) — ESC no hace nada, el jugador tiene que clickear
	un objetivo válido si es que hay alguno disponible.
	2026-09-14, bug real reportado por el usuario (log en vivo: 'Elige un
	Oro o una carta de coste 2 o menos para Convertir' seguido, ~200ms
	después, de 'Jugador 1 pasa prioridad' → 'Ambos pasaron' →
	awaiting_response atascado en true para siempre): PhaseFlowController.
	_human_pass_after() auto-pasa la prioridad del humano solo mirando
	PriorityManager.suppress_human_autopass — nunca sabía que había una
	selección de objetivo real pendiente, así que la auto-pasaba de
	debajo justo cuando la ventana de prioridad (Paso D del propio
	trigger) coincidía en el tiempo con este await_target(). El fix en
	PhaseFlowController._on_paso_pressed() (mismo día) bloquea el CLICK
	manual del botón ¿Paso?, pero este auto-pase por timer es un camino
	totalmente aparte que no pasa por ahí. Se reusa el mismo flag que ya
	usa ResponseWindowHandler._offer_signo_amarillo_for_step_d() para su
	propio diálogo reactivo — mismo criterio, un caso más de 'hay una
	decisión real esperando, no auto-pases'."""
	is_selecting_target = true
	_target_filter = filter
	_target_callback = on_selected
	_selection_cancellable = cancellable
	_force_board_interactable()
	PriorityManager.suppress_human_autopass = true
	_main._update_debug(prompt)


func await_target(prompt: String, filter: Callable, cancellable: bool = true, chooser_id: int = 0) -> Node:
	"""Envoltorio de start_target_selection() que espera la respuesta —
	extraído (2026-08-30) del mismo bloque de 8 líneas que se repetía
	copiado en _select_ally_target()/_select_convert_target()
	(TargetedEffectExecutor.gd), la elección de portador de Tyet/Aho
	(CardManager.gd) y GoldManager._select_weapon_wielder(). Dictionary de
	estado a propósito, no 'var chosen'/'var done' sueltas — mismo motivo
	de siempre (los lambdas de GDScript capturan variables locales por
	VALOR, ver comentarios de esta clase). Devuelve la carta elegida, o
	null si se canceló (ESC) o no había forma de abrir la selección.

	'chooser_id' (2026-09-30, Fase 3 del plan de paridad remota, cuarto
	sistema — ver docs/plans/2026-09-20-remote-multiplayer-parity.md): si
	quien elige es el jugador 1 y hay un Remoto real conectado, se delega
	por red en vez de activar el modo de selección local (que de otro modo
	esperaría un click en la pantalla del Anfitrión)."""
	if not is_instance_valid(self):
		return null
	if chooser_id == 1 and NetworkClient.room_code != "" and NetworkClient.is_host:
		return await _delegate_target_to_remote(prompt, filter, cancellable)
	var state := {"done": false, "chosen": null}
	var on_selected := func(c: Node) -> void:
		state.chosen = c
		state.done = true
	start_target_selection(prompt, filter, on_selected, cancellable)
	# 2026-09-15, a pedido del usuario: brillo celeste en cada candidato real
	# (propio o rival) — ver _glow_valid_targets(). Solo aquí, NO dentro de
	# start_target_selection() en sí, porque await_multi_target() también
	# usa start_target_selection() puertas adentro con su propio manejo de
	# brillo por lock_group_key/dynamic_filter — duplicarlo ahí pisaría esa
	# lógica más fina.
	_glow_valid_targets(filter)
	while not state.done:
		await get_tree().process_frame
	return state.chosen


func await_multi_target(prompt_prefix: String, candidates: Array, max_count: int = -1, lock_group_key: Callable = Callable(), dynamic_filter: Callable = Callable(), cancellable: bool = true, glow_color_override = null, chooser_id: int = 0) -> Array:
	"""Selección de 0 a 'max_count' objetivos (-1 = sin tope) clickeando
	directo sobre las cartas reales, en vez de un modal de lista — extraído
	(2026-09-13, a pedido del usuario) del mismo mecanismo que ya usaba
	GoldManager._choose_physical_gold_to_spend() para elegir qué Oro físico
	gastar (brillo celeste de "activable" + await_target() repetido).
	'candidates' puede mezclar cartas de VARIAS zonas a la vez (mano,
	Cementerio, en juego) — así el jugador ve y elige directo, sin que el
	juego le pregunte antes 'desde dónde' con un modal separado; DÓNDE está
	cada carta ya se ve con solo mirar la mesa/mano/Cementerio.
	'lock_group_key' (opcional): Callable(Node) -> Variant — si se pasa,
	tras el PRIMER pick el resto de la selección queda restringida a
	candidatos cuyo key coincida con el del primero (p.ej. Hanta el
	Samurai: 'hasta N cartas de UN Cementerio' — un solo Cementerio, no un
	pool combinado — key = owner_id del candidato).
	'dynamic_filter' (opcional): Callable(chosen: Array, candidate: Node) ->
	bool — se re-evalúa en CADA click con el 'chosen' acumulado hasta ese
	momento; false excluye al candidato de la vuelta siguiente. Útil para
	presupuestos que se consumen con cada pick (p.ej. Tempilcahue: 'Baraja
	cartas cuyos costes sumen hasta 4' — el filtro rechaza cualquier carta
	que haría superar la suma con lo ya elegido).
	ESC en cualquier punto TERMINA la selección con lo ya elegido hasta
	ahí (no cancela todo) — mismo criterio ya usado en otros flujos
	'Baraja hasta una carta... ESC para no barajar ninguna'.
	'Seleccionar todo' (2026-09-13, a pedido del usuario: Abrazo de Maipú,
	'Baraja CUALQUIER CANTIDAD de cartas de tu Cementerio y Destierro' —
	con muchas cartas disponibles, clickear una por una es tedioso): un
	botón de UI puede llamar a request_select_all() en cualquier momento
	mientras esta función espera un click; en el próximo frame, todo lo
	que quede en 'remaining' (respetando el lock/dynamic_filter vigentes)
	se toma de una sola vez y la selección termina ahí.
	'glow_color_override' (2026-09-15, a pedido del usuario): por defecto el
	brillo es celeste/rojo según dueño (ver _glow_color_for_owner()) — pasar
	un Color aquí (p.ej. CardBadges.GLOW_COLOR_GOLD) lo fuerza igual para
	TODOS los candidatos, para usos que no son "elegir un objetivo" sino
	otra cosa (p.ej. TriggerSystem._prompt_trigger_order(): elegir el ORDEN
	de resolución entre tus propios triggers ya disparados, no un objetivo
	propio/rival)."""
	var chosen: Array = []
	if not is_instance_valid(self):
		return chosen
	# 2026-09-30, Fase 3 del plan de paridad remota, cuarto sistema — mismo
	# criterio que await_target(). SIMPLIFICACIÓN a propósito: la contraparte
	# remota no enforcea 'lock_group_key'/'dynamic_filter' (ninguna de las
	# conversiones hechas hasta ahora los necesita) — si se convierte un
	# patrón que sí los usa de verdad, hay que volver a esto.
	if chooser_id == 1 and NetworkClient.room_code != "" and NetworkClient.is_host:
		return await _delegate_multi_target_to_remote(prompt_prefix, candidates, max_count, cancellable)
	var glow_of := func(c: Node) -> Color:
		return glow_color_override if glow_color_override != null else _glow_color_for_owner(c)
	var remaining: Array = candidates.duplicate()
	for c in remaining:
		if is_instance_valid(c) and c.has_method("set_activatable"):
			c.set_activatable(true, glow_of.call(c), &"target_select")
	var locked_key = null
	var has_lock: bool = lock_group_key.is_valid()
	var has_dynamic: bool = dynamic_filter.is_valid()
	while (max_count < 0 or chosen.size() < max_count) and not remaining.is_empty():
		var filter := func(c: Node) -> bool:
			if c not in remaining:
				return false
			if has_lock and chosen.size() > 0 and lock_group_key.call(c) != locked_key:
				return false
			if has_dynamic and not dynamic_filter.call(chosen, c):
				return false
			return true
		var count_label: String = " (%d elegidas)" % chosen.size() if chosen.size() > 0 else ""
		var prompt: String = "%s%s%s" % [prompt_prefix, count_label, " — ESC para terminar" if cancellable else ""]

		var card_state := {"done": false, "chosen": null}
		var on_selected := func(c: Node) -> void:
			card_state.chosen = c
			card_state.done = true
		start_target_selection(prompt, filter, on_selected, cancellable)
		var select_all_triggered := false
		while not card_state.done:
			if _select_all_requested:
				_select_all_requested = false
				select_all_triggered = true
				# Resolver el pick pendiente directo (NO vía cancel_target_
				# selection() — "seleccionar todo" es una acción de UI
				# distinta de "cancelar con ESC" y debe funcionar incluso
				# si esta selección es no-cancelable, ver cancellable arriba).
				is_selecting_target = false
				PriorityManager.suppress_human_autopass = false
				_target_filter = Callable()
				_target_callback = Callable()
				_restore_board_interactable()
				break
			await get_tree().process_frame

		if select_all_triggered:
			for c in remaining.duplicate():
				if max_count >= 0 and chosen.size() >= max_count:
					break
				if not filter.call(c):
					continue  # un candidato que el lock ya había excluido
				if is_instance_valid(c) and c.has_method("set_activatable"):
					c.set_activatable(false, CardBadges.GLOW_COLOR_GOLD, &"target_select")
				chosen.append(c)
				remaining.erase(c)
			break

		var picked: Node = card_state.chosen
		if not picked or not is_instance_valid(picked):
			break
		if has_lock and chosen.is_empty():
			locked_key = lock_group_key.call(picked)
			# Apagar el brillo de los candidatos que el lock acaba de excluir
			# (2026-09-13) — sin esto seguían brillando como "elegibles"
			# aunque el filtro ya los rechazara.
			for c in remaining:
				if is_instance_valid(c) and c.has_method("set_activatable") and lock_group_key.call(c) != locked_key:
					c.set_activatable(false, CardBadges.GLOW_COLOR_GOLD, &"target_select")
		remaining.erase(picked)
		picked.set_activatable(false, CardBadges.GLOW_COLOR_GOLD, &"target_select")
		chosen.append(picked)
		if has_dynamic:
			# Re-evaluar el brillo de lo que queda contra el presupuesto YA
			# reducido por este pick — una carta que calzaba antes puede
			# haber dejado de calzar ahora.
			for c in remaining:
				if is_instance_valid(c) and c.has_method("set_activatable"):
					c.set_activatable(dynamic_filter.call(chosen, c), glow_of.call(c), &"target_select")
	for c in remaining:
		if is_instance_valid(c) and c.has_method("set_activatable"):
			c.set_activatable(false, CardBadges.GLOW_COLOR_GOLD, &"target_select")
	return chosen


func _delegate_target_to_remote(prompt: String, filter: Callable, cancellable: bool) -> Node:
	"""Contraparte en red de await_target() — ver _glow_valid_targets() para
	el mismo barrido de las 10 zonas de tablero + mano/abanico rival. A
	diferencia de SelectionManager/ZoneViewerModule, acá las cartas YA son
	Nodos reales y persistentes del tablero (no datos ni Nodos temporales)
	— se identifican por get_instance_id(), mismo criterio que
	RemotePlayerController._card_ref()/_find_card_by_id()."""
	if not filter.is_valid() or not _main:
		return null
	var candidates: Array = []
	for name in ["player_field", "player_linea_ataque", "player_linea_apoyo",
			"opponent_field", "opponent_linea_ataque", "opponent_linea_apoyo",
			"player_gold", "opponent_gold", "player_oro_pagado", "opponent_oro_pagado"]:
		var container = _main.get(name)
		if not container:
			continue
		for c in container.get_children():
			if is_instance_valid(c) and filter.call(c):
				candidates.append(c)
	for hand_name in ["player_hand", "_opponent_fan"]:
		var hand = _main.get(hand_name)
		if not hand or not hand.get("cards"):
			continue
		for c in hand.cards:
			if is_instance_valid(c) and filter.call(c):
				candidates.append(c)
	if candidates.is_empty():
		return null

	var payload: Array = []
	for c in candidates:
		payload.append({
			"card_id": str(c.get_instance_id()),
			"nombre": str(c.get("card_name")) if c.get("card_name") != null else "?",
			"coste": c.get("card_cost") if c.get("card_cost") != null else "?",
		})
	NetworkClient.send_message({
		"op": "prompt", "kind": "await_target",
		"title": prompt,
		"candidates": payload,
		"cancellable": cancellable,
	})
	var intent: Dictionary = await NetworkClient.await_intent(["await_target_choice"])
	if bool(intent.get("cancelled", false)):
		return null
	var id_str: String = str(intent.get("card_id", ""))
	if id_str.is_empty() or not id_str.is_valid_int():
		return null
	var obj: Object = instance_from_id(int(id_str))
	if obj is Node and is_instance_valid(obj) and obj in candidates:
		return obj
	return null


func _delegate_multi_target_to_remote(prompt_prefix: String, candidates: Array, max_count: int, cancellable: bool) -> Array:
	"""Contraparte en red de await_multi_target() — ver _delegate_target_
	to_remote() para el mismo criterio de identificar por get_instance_id().
	No enforcea lock_group_key/dynamic_filter (ver nota en await_multi_
	target())."""
	var live_candidates: Array = candidates.filter(func(c): return is_instance_valid(c))
	if live_candidates.is_empty():
		return []
	var payload: Array = []
	for c in live_candidates:
		payload.append({
			"card_id": str(c.get_instance_id()),
			"nombre": str(c.get("card_name")) if c.get("card_name") != null else "?",
			"coste": c.get("card_cost") if c.get("card_cost") != null else "?",
		})
	NetworkClient.send_message({
		"op": "prompt", "kind": "await_multi_target",
		"title": prompt_prefix,
		"candidates": payload,
		"max_selections": max_count,
		"cancellable": cancellable,
	})
	var intent: Dictionary = await NetworkClient.await_intent(["await_multi_target_choice"])
	var result: Array = []
	for id_str in intent.get("card_ids", []):
		if not str(id_str).is_valid_int():
			continue
		var obj: Object = instance_from_id(int(str(id_str)))
		if obj is Node and is_instance_valid(obj) and obj in live_candidates:
			result.append(obj)
	return result


func await_target_or_castillo_pick(prompt: String, filter: Callable, castillo_title: String, allow_cancel: bool = true, castillo_own_only: bool = false) -> Dictionary:
	"""Carrera entre clickear una carta real (que pase 'filter') y clickear
	un Panel de Castillo entero (propio o rival) — extraído (2026-09-13, a
	pedido del usuario, ver arquitectura.md §10.14/La Ouija) del mismo
	mecanismo ya usado a mano por ConvertAndMiscResolver.try_execute_mill_
	convert_to_ally_pattern() (Sherlock Holmes: 'convierte cartas en juego
	O del tope de un Castillo'). Útil para habilidades que ofrecen elegir
	entre una carta visible (mano/campo/Cementerio) y 'el tope/fondo de un
	Castillo' — no hay nada que clickear DENTRO del Castillo (es
	información oculta hasta que se elige), así que el Panel del Castillo
	entero actúa como el objetivo; el primer click real (carta o Castillo)
	decide la fuente, el otro deja de ser clickeable.
	'allow_cancel': si true (habilidad opcional, 'puedes'), ESC en el
	picker de cartas cancela TODA la elección (incluye el Castillo en
	paralelo) y devuelve {type: "none"}. Si false (habilidad obligatoria,
	sin 'puedes'), ESC solo reintenta el picker de cartas — el Castillo
	sigue esperando en paralelo, la habilidad tiene que resolverse por
	algún lado.
	'castillo_own_only': si true (p.ej. La Ouija: 'del tope de TU
	Castillo', con posesivo — a diferencia de Sherlock Holmes, 'un
	Castillo' sin posesivo, cualquiera de los dos), un click en el
	Castillo rival se ignora (se re-arma el listener del Castillo, sigue
	esperando) en vez de resolver la carrera con ese lado inválido.
	Devuelve {type: "card", card: Node}, {type: "castillo", own: bool}, o
	{type: "none"} si se canceló sin elegir nada."""
	if not is_instance_valid(self):
		return {"type": "none"}
	# 2026-09-23, bug real reportado ("Attempt to call function 'null::null
	# (Callable)' on a null instance"): los lambdas de GDScript capturan las
	# variables locales POR VALOR, no por referencia (ver misma causa raíz
	# documentada en arquitectura.md §13.17 para el cuelgue de mazos). Un
	# lambda auto-referenciado como "arm_castillo_pick = func(): ...
	# arm_castillo_pick.call()..." se rompe: adentro del lambda,
	# "arm_castillo_pick" es la copia (vacía) de ANTES de la asignación, así
	# que reintentar el pick del Castillo llamaba un Callable nulo. Lo mismo
	# le pasaba en silencio a race_done/castillo_own/castillo_chosen (se
	# reasignaban adentro del lambda sin que el bucle de abajo se enterara
	# nunca). Arreglado guardando todo en un Dictionary ("_state"): SÍ se
	# captura por referencia (la copia por valor es una copia del puntero al
	# mismo objeto), así que mutar sus claves adentro del lambda es visible
	# afuera, y el lambda puede llamarse a sí mismo vía _state["arm"].
	var _state := {"race_done": false, "castillo_own": true, "castillo_chosen": false, "arm": Callable()}
	_state["arm"] = func() -> void:
		SelectionManager.start_castillo_pick(_main, castillo_title,
			func(picked_own: bool) -> void:
				if _state["race_done"]:
					return
				if castillo_own_only and not picked_own:
					_main._update_debug("%s: solo tu propio Castillo es válido aquí" % castillo_title)
					_state["arm"].call()
					return
				_state["race_done"] = true
				_state["castillo_own"] = picked_own
				_state["castillo_chosen"] = true
				cancel_target_selection())
	_state["arm"].call()

	var chosen_card: Node = null
	while not _state["race_done"]:
		var card_state := {"done": false, "chosen": null}
		start_target_selection(prompt, filter, func(c: Node) -> void:
			card_state.chosen = c
			card_state.done = true)
		while not card_state.done and not _state["race_done"]:
			await get_tree().process_frame
		if _state["race_done"]:
			break
		if card_state.chosen:
			chosen_card = card_state.chosen
			_state["race_done"] = true
			SelectionManager.cancel_castillo_pick()
		elif allow_cancel:
			_state["race_done"] = true
			SelectionManager.cancel_castillo_pick()
		# else: ESC sin elegir carta en una habilidad OBLIGATORIA — se
		# vuelve a armar el listener de cartas, el Castillo sigue
		# esperando en paralelo.

	if chosen_card:
		return {"type": "card", "card": chosen_card}
	if _state["castillo_chosen"]:
		return {"type": "castillo", "own": _state["castillo_own"]}
	return {"type": "none"}


func cancel_target_selection() -> void:
	"""Cancela con ESC. Llama al callback con null (en vez de dejarlo sin
	invocar) — quien esperaba con 'while not done: await process_frame'
	(TriggerSystem._select_ally_target, GoldManager._select_weapon_wielder,
	etc.) se quedaba colgado para siempre si el jugador cancelaba, porque
	'done' nunca se ponía en true.
	No hace nada si la selección actual es NO cancelable (2026-09-13, ver
	_selection_cancellable arriba) — p.ej. un descarte MANDATORIO ('Descarta
	N cartas', sin 'puedes') no debe poder esquivarse con ESC como si fuera
	un costo opcional; el jugador tiene que clickear un objetivo válido."""
	if not is_selecting_target or not _selection_cancellable:
		return
	is_selecting_target = false
	PriorityManager.suppress_human_autopass = false
	var callback = _target_callback
	_target_filter = Callable()
	_target_callback = Callable()
	_cemetery_target_nodes.clear()
	_restore_board_interactable()
	_unglow_target_cards()
	_main._update_debug("Selección de objetivo cancelada")
	if callback.is_valid():
		callback.call(null)


func _resolve_target_selection(card: Node) -> void:
	if _target_filter.is_valid() and not _target_filter.call(card):
		# 2026-09-06, bug reportado por el usuario: quedarse pegado
		# clickeando la mano repetidamente sin saber que ESC cancela la
		# selección (p.ej. Golpe Solar: 'Baraja hasta una carta rival...
		# ESC para no barajar ninguna' — sin este recordatorio, cada click
		# en la mano solo repetía este mensaje para siempre, sin pista de
		# cómo salir). El mensaje ahora lo dice explícito.
		_main._update_debug("Objetivo no válido — elige otra carta o presiona ESC para cancelar")
		return
	var callback = _target_callback
	is_selecting_target = false
	PriorityManager.suppress_human_autopass = false
	_target_filter = Callable()
	_target_callback = Callable()
	_cemetery_target_nodes.clear()
	_restore_board_interactable()
	_unglow_target_cards()
	_last_resolved_target = card
	_last_resolved_at_ms = Time.get_ticks_msec()
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
	# Declarar bloqueador con un clic (2026-09-08, primera vez que se conecta
	# GameManager.declare_blocker() a una UI real — existía desde antes pero
	# sin ningún llamador, así que Bloqueo nunca dejaba hacer nada más que
	# pasar prioridad, bug real reportado por el usuario: "no funcionó el
	# sistema de bloqueos"). Solo el propio Aliado en Línea de Defensa del
	# jugador humano — si el humano es quien ataca, sus Aliados están en
	# Línea de Ataque, no Defensa, así que este bloque no interfiere.
	if GameManager.current_phase == Constants.Phase.BLOQUEO and card.card_type == Constants.CardType.ALIADO \
			and card.current_zone == Constants.Zone.LINEA_DEFENSA and card.controller_id == 0:
		await _declare_blocker(card)
		return
	# Declarar atacante con un clic (2026-08-17): el arrastre se desactivó
	# (Card.drag_enabled = false) por los bugs de posicionamiento que
	# causaba — ver Card._can_declare_attack_drag() para la condición real
	# (fase de Ataque, ya sin atajo de Vigilia — 2026-08-28). Se reutiliza
	# esa función tal cual para no duplicar la lógica de cuándo tiene
	# sentido intentar atacar.
	# Acepta Defensa (para declarar) o Ataque (para desdeclarar con un
	# segundo clic) — desde que declarar mueve de verdad la carta a Línea
	# de Ataque (consolidación 2026-08-20), ya no se queda en Defensa.
	if card.card_type == Constants.CardType.ALIADO and card.current_zone in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE]:
		# Si ya está atacando, un segundo clic lo retira del combate en vez
		# de rechazar el clic con un mensaje — a pedido del usuario, para
		# poder corregir una declaración antes de confirmar con ¿Paso?.
		if card in GameManager.attackers:
			if GameManager.current_phase in [Constants.Phase.VIGILIA, Constants.Phase.ATAQUE]:
				var undeclared = GameManager.undeclare_attacker(card)
				if undeclared:
					unmark_attackers([card])
					var name_undeclared = card.get("card_name") if card.get("card_name") else "Aliado"
					_main._update_debug("%s ya no está atacando" % name_undeclared)
			return
		if card.has_method("_can_declare_attack_drag") and card._can_declare_attack_drag():
			await _declare_attacker(card)
			return
		# No puede atacar todavía, pero SÍ estamos en una fase donde intentar
		# atacar tiene sentido (2026-08-23) — dar la razón real (enfermedad
		# de invocación, normalmente) en vez de caer al mensaje genérico de
		# selección de más abajo, que no explica nada sobre el ataque.
		if GameManager.current_phase in [Constants.Phase.VIGILIA, Constants.Phase.ATAQUE]:
			var validation_reason = TurnManager.can_attack(card)
			if not validation_reason.get("can_attack", true):
				var reason_name = card.get("card_name") if card.get("card_name") else "Aliado"
				_main._update_debug("%s: %s" % [reason_name, validation_reason.get("reason", "no puede atacar todavía")])
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
	# Un click real en Godot (Card._on_gui_input) SIEMPRE dispara card_clicked
	# primero (press 1, double_click=false) y LUEGO card_double_clicked (press
	# 2 del mismo gesto, double_click=true) — confirmado con logging en vivo
	# (2026-08-22). Si press 1 ya resolvió una selección de objetivo pendiente
	# (p.ej. elegir portador de un Arma), press 2 llega con is_selecting_target
	# ya en false — sin este chequeo caía en 'Solo puedes jugar cartas de la
	# mano' como si hubiera fallado, aunque la selección ya se había resuelto
	# bien. Se ignora en silencio ese eco (mismo objetivo, <700ms).
	if card == _last_resolved_target and Time.get_ticks_msec() - _last_resolved_at_ms < 700:
		return
	# Si la selección sigue pendiente (el objetivo de este double-click no es
	# el que se acaba de resolver), resolverla igual que un click simple —
	# evita que reentre en play_card() y pise el filtro/callback en curso.
	if is_selecting_target:
		_resolve_target_selection(card)
		return
	# Un Aliado ya en juego (Defensa/Ataque) no se 'juega' con doble-click —
	# tratarlo como el click simple de declarar/desdeclarar ataque en vez de
	# caer en el rechazo genérico de abajo (2026-08-23): antes, doble-clickear
	# por error un Aliado que no podía atacar todavía mostraba 'Solo puedes
	# jugar cartas de la mano', un mensaje que no tiene nada que ver con la
	# razón real (enfermedad de invocación, no es su turno, etc.).
	if card.card_type == Constants.CardType.ALIADO and card.current_zone in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE]:
		_on_card_clicked(card)
		return
	# No usar solo VIGILIA aquí: este gateo corría ANTES de que la carta
	# llegara a GoldManager.play_card(), así que un Arma con Lobo Sagrado en
	# juego (o cualquier Talismán) en Guerra de Talismanes nunca alcanzaba a
	# intentarse siquiera (2026-08-28, bug reportado por el usuario).
	# Talismanes de respuesta instantánea (Anula/Cancela) también quedan
	# exceptuados aquí, en CUALQUIER fase (2026-09-06) — mismo criterio que
	# GoldManager.play_card()'s is_instant_response, este gateo de UI corre
	# antes y los habría bloqueado igual sin este chequeo repetido.
	var is_instant_response_talisman: bool = card.card_type == Constants.CardType.TALISMAN \
		and _main._gold_manager._is_response_only_talisman(card)
	if GameManager.current_phase != Constants.Phase.VIGILIA and not _main._gold_manager.has_phase_exception(card.card_type) \
			and not is_instant_response_talisman:
		_main._update_debug(_main._gold_manager.get_phase_rejection_reason(card.card_type))
		return
	# 2026-09-15, mismo bug y mismo motivo que GoldManager.play_card() (ver
	# ese comentario) — este gateo de UI corre ANTES de llegar ahí, así que
	# sin esta excepción un Talismán de respuesta instantánea quedaba
	# bloqueado igual antes de siquiera intentarlo.
	if GameManager.active_player_id != 0 and not is_instant_response_talisman:
		_main._update_debug("No es tu turno")
		return
	if card.get_parent() != _main.player_hand:
		_main._update_debug("Solo puedes jugar cartas de la mano (%s)" % card.get("card_name"))
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
	# Excepción de mano (2026-08-30, p.ej. Infernum Vox): este botón genérico
	# no tiene todavía una carta elegida, así que el chequeo por-carta de
	# TurnManager.can_place_oro(phase, card) no aplica aquí — se escanea la
	# mano por si hay algún Oro con la excepción de texto propia antes de
	# bloquear la sola ENTRADA al modo "colocar Oro" (el chequeo real, con
	# la carta específica, sigue en GoldManager._place_card_as_gold()).
	if not TurnManager.can_place_oro(GameManager.current_phase) and not _hand_has_oro_chance_exception():
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


func _hand_has_oro_chance_exception() -> bool:
	"""¿Hay en la mano algún Oro con la excepción de Infernum Vox (ver
	TurnManager.ignores_oro_chance_lost())? oro_placed_this_turn NO tiene
	excepción (ni Infernum Vox se salta esa parte), así que se corta antes
	si ya se colocó Oro este turno o no es Vigilia."""
	if TurnManager.oro_placed_this_turn or GameManager.current_phase != Constants.Phase.VIGILIA:
		return false
	if not _main.player_hand:
		return false
	for c in _main.player_hand.cards:
		if is_instance_valid(c) and c.get("card_type") == Constants.CardType.ORO and TurnManager.ignores_oro_chance_lost(c):
			return true
	return false


# =============================================================================
# BATALLA — DECLARAR ATACANTE
# =============================================================================
func _declare_attacker(card: Node) -> void:
	"""Declara un Aliado como atacante. Se llama al soltarlo en la Línea de
	Ataque — DropZone solo deja soltar aquí durante el paso de Ataque (DAR
	5.3.1, ya sin atajo de Vigilia — ver 2026-08-28), y
	GameManager.declare_attacker() valida enfermedad de invocación (Furia
	la evita, pero ya no salta la fase). Antes esta función solo se usaba
	(y nombraba) para Furia, pero el drop de DropZone ya aceptaba ambos
	casos — ver hallazgo 5.

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
	# Traba de reentrada (2026-08-23): un segundo click/eco sobre la MISMA
	# carta mientras una declaración anterior sigue en vuelo (ver comentario
	# de _declaring_attackers) no debe iniciar una segunda declaración en
	# paralelo — se ignora en silencio en vez de competir por
	# GameManager.attackers.
	if _declaring_attackers.has(card):
		return
	_declaring_attackers[card] = true
	# Con el clic reemplazando al arrastre, es fácil volver a clickear un
	# Aliado que ya está atacando (por error, o para revisarlo). Antes esto
	# caía en GameManager.declare_attacker(), que lo rechaza en silencio
	# (ally in attackers), y el mensaje genérico de más abajo ('no puede
	# atacar todavía') daba a entender que el ataque había fallado, cuando
	# en realidad ya estaba registrado y el combate seguía su curso normal.
	if card in GameManager.attackers:
		_main._update_debug("%s ya está atacando" % (card.get("card_name") if card.get("card_name") else "Aliado"))
		_declaring_attackers.erase(card)
		return
	# Si hay una ventana de prioridad abierta (p.ej. respuesta a un 'cuando
	# entre en juego' que se acaba de disparar), no dejar declarar un nuevo
	# atacante todavía — eso hacía que el efecto pendiente (p.ej. el 'roba 2'
	# de un oro) quedara pospuesto y se resolviera solo al momento de
	# atacar, en vez de cuando se jugó la carta. Hay que resolver esa
	# ventana primero (presionando ¿Paso?).
	if PriorityManager.priority_window_active:
		_main._update_debug("Resuelve la respuesta pendiente (¿Paso?) antes de declarar otro atacante")
		card.return_to_hand()
		_declaring_attackers.erase(card)
		return
	var card_name = card.get("card_name") if card.get("card_name") else "Aliado"
	# KeywordManager.can_attack_immediately() (2026-09-02, refactor), no
	# card.has_keyword() directo — mismo motivo que el resto de checks de
	# keyword movidos a KeywordManager: respeta silencio/remociones
	# temporales, y ya es la misma función que usa TurnManager.can_attack()
	# para la validación real, así que el mensaje ahora no puede
	# desincronizarse de si el ataque de verdad contó como 'con Furia'.
	var has_furia = KeywordManager.can_attack_immediately(card)
	await get_tree().process_frame
	var declared = await GameManager.declare_attacker(card)
	if not declared:
		var reason = TurnManager.can_attack(card).get("reason", "")
		_main._update_debug("%s no puede atacar%s" % [card_name, (": " + reason) if not reason.is_empty() else " todavía"])
		_declaring_attackers.erase(card)
		return

	var ataque_container: HBoxContainer = _main.player_linea_ataque if card.controller_id == 0 else _main.opponent_linea_ataque
	await _advance_card_to_attack_line(card, ataque_container)
	_mark_card_as_attacker(card)
	_main._game_hud.start_paso_glow()
	_main._update_debug("%s declara ataque%s! Puedes seguir declarando o presionar ¿Paso?" % [card_name, " con Furia" if has_furia else ""])
	print("[CardInteraction] '%s' declaró ataque%s" % [card_name, " (Furia)" if has_furia else ""])
	_declaring_attackers.erase(card)


func _declare_blocker(card: Node) -> void:
	"""Declara 'card' como bloqueador de un atacante (fase BLOQUEO, DAR
	5.3.2). Con exactamente un atacante sin bloquear, se asigna directo sin
	preguntar. Con más de uno, pide clickear DIRECTO sobre el atacante rival
	en el tablero (2026-09-12, a pedido del usuario — antes era una lista de
	texto con nombres, no clickeable). Un segundo clic sobre un bloqueador ya
	declarado no hace nada especial todavía (deselección/reasignación queda
	fuera de alcance de este primer cableado real)."""
	if not card or not is_instance_valid(card):
		return
	if card in GameManager.blockers.values():
		var blocking_name: String = card.get("card_name") if card.get("card_name") else "Aliado"
		_main._update_debug("%s ya está bloqueando" % blocking_name)
		return

	var unblocked_attackers: Array = []
	for attacker in GameManager.attackers:
		if is_instance_valid(attacker) and not GameManager.blockers.has(attacker):
			unblocked_attackers.append(attacker)
	if unblocked_attackers.is_empty():
		_main._update_debug("No hay atacantes sin bloquear")
		return

	var attacker: Node = unblocked_attackers[0]
	if unblocked_attackers.size() > 1:
		# 2026-09-12 (a pedido del usuario): click directo sobre el atacante en
		# el tablero, no una lista de texto — mismo mecanismo (await_target)
		# que usa el resto del juego para elegir objetivo (Anular, Convertir,
		# Barajar una carta puntual, etc.), en vez de un modal con nombres.
		var filter := func(c: Node) -> bool:
			return c in unblocked_attackers
		var clicked_attacker: Node = await await_target(
			"%s bloquea — elige a qué atacante rival" % (card.get("card_name") if card.get("card_name") else "Tu Aliado"),
			filter)
		if not clicked_attacker or not is_instance_valid(clicked_attacker):
			_main._update_debug("Bloqueo cancelado")
			return
		attacker = clicked_attacker

	GameManager.declare_blocker(card, attacker)
	var card_name: String = card.get("card_name") if card.get("card_name") else "Aliado"
	var attacker_name: String = attacker.get("card_name") if attacker.get("card_name") else "Aliado"
	var tween = create_tween()
	tween.tween_property(card, "modulate", Color(0.4, 0.7, 1.0, 1.0), 0.2)
	_main._update_debug("%s bloquea a %s" % [card_name, attacker_name])
	print("[CardInteraction] '%s' bloquea a '%s'" % [card_name, attacker_name])


func _mark_card_as_attacker(card: Node) -> void:
	"""Aspecto visual de 'atacando': tinte naranja."""
	if not card or not is_instance_valid(card):
		return
	var tween = create_tween()
	tween.tween_property(card, "modulate", Color(1.0, 0.55, 0.35, 1.0), 0.2)


func unmark_attackers(cards: Array) -> void:
	"""Revierte el aspecto visual de 'atacando' y mueve al sobreviviente
	de vuelta a Línea de Defensa en línea recta por el eje Y."""
	for card in cards:
		if not card or not is_instance_valid(card):
			continue
		var tween = create_tween()
		tween.tween_property(card, "modulate", Color.WHITE, 0.2)
		var defensa_container: HBoxContainer = _main.player_field if card.controller_id == 0 else _main.opponent_field
		await _move_card_to_line(card, defensa_container, Constants.Zone.LINEA_DEFENSA)
	if _main and _main.get("_zone_manager") != null:
		_main._zone_manager.compact_all_fields(true)


func _advance_card_to_attack_line(card: Node, ataque_container: HBoxContainer) -> void:
	"""Avanza el Aliado en línea recta exclusivamente sobre el eje vertical Y,
	manteniendo su coordenada X fija en su carril sin recentrar ni desviar."""
	if not card or not is_instance_valid(card) or not ataque_container:
		return
	var start_pos: Vector2 = card.global_position
	var slot_x: float = card.get_meta("field_slot_x", start_pos.x)

	var previous_parent: Node = card.get_parent()
	if previous_parent and previous_parent != ataque_container:
		previous_parent.remove_child(card)
	if card.get_parent() != ataque_container:
		ataque_container.add_child(card)

	card.set_zone(Constants.Zone.LINEA_ATAQUE)
	card.top_level = true
	card.global_position = start_pos

	var card_height: float = (card.size.y * card.scale.y) if card.size.y > 0 else 210.0
	var target_y: float = ataque_container.global_position.y + (ataque_container.size.y - card_height) / 2.0
	var target_pos: Vector2 = Vector2(slot_x, target_y)
	card.set_meta("field_slot_pos", target_pos)

	var tween = create_tween()
	tween.tween_method(
		func(y: float): card.global_position = Vector2(slot_x, y),
		start_pos.y, target_y, 0.25
	).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	await tween.finished
	if is_instance_valid(card) and "equipped_weapons" in card and card.equipped_weapons is Array:
		for w_idx in range(card.equipped_weapons.size()):
			var w: Node = card.equipped_weapons[w_idx]
			if is_instance_valid(w):
				w.top_level = false
				w.position = Vector2(0.0, Constants.WEAPON_OFFSET_Y + w_idx * Constants.WEAPON_STACK_STEP_Y)
				w.set_zone(card.current_zone)
				if "base_scale" in card and "base_scale" in w:
					w.scale = card.base_scale
					w.base_scale = card.base_scale


func _move_card_to_line(card: Node, target_container: HBoxContainer, zone: int) -> void:
	"""Regresa un Aliado a Línea de Defensa en línea recta vertical sobre el eje Y
	hacia su slot de columna X reservado."""
	if not card or not is_instance_valid(card) or not target_container:
		return
	var start_pos: Vector2 = card.global_position
	var previous_parent: Node = card.get_parent()
	if previous_parent and previous_parent != target_container:
		previous_parent.remove_child(card)
	if card.get_parent() != target_container:
		target_container.add_child(card)

	card.set_zone(zone)
	card.top_level = true
	var end_pos: Vector2 = _main._zone_manager.pin_card_to_field_slot(card, target_container)
	var slot_x: float = card.get_meta("field_slot_x", end_pos.x)
	card.global_position = Vector2(slot_x, start_pos.y)

	var tween = create_tween()
	tween.tween_method(
		func(y: float): card.global_position = Vector2(slot_x, y),
		start_pos.y, end_pos.y, 0.25
	).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	await tween.finished
	if is_instance_valid(card) and "equipped_weapons" in card and card.equipped_weapons is Array:
		for w_idx in range(card.equipped_weapons.size()):
			var w: Node = card.equipped_weapons[w_idx]
			if is_instance_valid(w):
				w.top_level = false
				w.position = Vector2(0.0, Constants.WEAPON_OFFSET_Y + w_idx * Constants.WEAPON_STACK_STEP_Y)
				w.set_zone(card.current_zone)
				if "base_scale" in card and "base_scale" in w:
					w.scale = card.base_scale
					w.base_scale = card.base_scale
