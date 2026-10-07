extends RefCounted
## WeaponAbilityPatterns — Patrones "try_execute_*_pattern" para Armas
## detectadas sin cobertura en la auditoría de 539 cartas (2026-09-20, ver
## arquitectura.md). Mismo criterio que TotemAbilityPatterns.gd (detección
## por substring, no por nombre de carta) pero para el tipo Arma, que tiene
## su propio ciclo de vida (equipar/desequipar, "el portador gana X") ya
## cubierto en su mayor parte por GoldManager._register_weapon_strength_
## bonus() — este archivo cubre las cláusulas ADICIONALES de cada Arma que
## ese parser genérico no toca (triggers de entrada/salida, habilidades
## activadas de Vigilia/Fase Final).
## Instanciado directo en TriggerSystem._ready() como _weapon_patterns (mismo
## patrón que _totem_patterns), llamado desde TriggerResolution.gd.

var _main: Node


func setup(main: Node) -> void:
	_main = main


# =============================================================================
# Cañón Naval ("Libertadores")
# =============================================================================
func try_execute_canon_naval_shared_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Una vez por turno o cuando salga del juego, tu oponente Bota cinco
	cartas y Destierra hasta tres cartas de un Cementerio' (Cañón Naval,
	2026-09-20). Un solo efecto compartido entre dos disparadores distintos
	(activada 'una vez por turno' Y trigger automático al salir de juego) —
	el cupo de 'una vez por turno' vía UniversalCardParser.turn_registry solo
	aplica al camino ACTIVADO (llamado desde _resolve_look_and_play_patterns);
	el camino on_leave_play llama directo a _execute_canon_naval_effect() sin
	pasar por el chequeo de cupo, porque salir de juego es un disparador
	aparte, no una segunda activación manual el mismo turno.

	Registrada en el despachador compartido (a diferencia de try_execute_
	canon_naval_final_pattern() más abajo) porque ESTA cláusula sí es una
	habilidad ACTIVADA real (vía StackStepResolver._resolve_ability(), que
	aísla el texto antes de llegar aquí) — la guardia 'el portador gana' es
	la misma usada en try_execute_sable_corto_vigilia_pattern(), necesaria
	para no disparar también durante on_enter_play (que pasa el texto
	COMPLETO de la carta, el cual sí contiene esa otra cláusula)."""
	var lower := ability_text.to_lower()
	if not ("bota cinco cartas y destierra hasta tres cartas de un cementerio" in lower):
		return false
	if "el portador gana" in lower:
		return false
	if UniversalCardParser.turn_registry.was_used(str(card.get_instance_id()), 0, GameManager.current_turn):
		return true
	UniversalCardParser.turn_registry.register(str(card.get_instance_id()), 0, GameManager.current_turn)
	await _execute_canon_naval_effect(card, controller_id)
	return true


func try_execute_canon_naval_leave_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	var lower := ability_text.to_lower()
	if not ("bota cinco cartas y destierra hasta tres cartas de un cementerio" in lower):
		return false
	await _execute_canon_naval_effect(card, controller_id)
	return true


func _execute_canon_naval_effect(card: Node, controller_id: int) -> void:
	"""Ventana única para todo el efecto (mismo criterio que asedio naval en
	SearchOwnZonePatterns.gd) — la elección de QUÉ desterrar es interactiva y
	se recolecta ANTES, pero la ventana de respuesta se abre DESPUÉS de
	recolectar y ANTES de ejecutar cualquier parte del efecto (mill Y
	destierro), para que una Anulación/Cancelación pueda evitar las DOS
	partes, no solo la mitad que ya se hubiera ejecutado."""
	var main := _main.get_node_or_null("/root/Main")
	var picked: Array = []
	if main and main._zone_viewer:
		var no_filter := func(_c: Node) -> bool: return true
		picked = await main._zone_viewer.open_cemetery_target_picker(
			"Cañón Naval — Destierra hasta tres cartas de un Cementerio", no_filter, 3, "cemetery", true, false, controller_id)

	if await TriggerSystem.open_response_window(card, "Cañón Naval", controller_id):
		return

	var opponent_id: int = 1 - controller_id
	await ActionModule.mill(opponent_id, 5, false, "Cañón Naval", true)
	for entry in picked:
		var owner_of_picked: int = entry.owner_id
		var picked_data: Dictionary = entry.data
		var idx: int = CardManager.get_cemetery(owner_of_picked).find(picked_data)
		if idx < 0:
			continue
		CardManager.remove_from_cemetery(owner_of_picked, idx)


func try_execute_canon_naval_final_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'En tu Fase Final, puedes Botar las primeras dos cartas de tu Castillo
	para agrupar un Oro' (Cañón Naval) — 'agrupar' aquí se interpreta como
	'generar' (mismo verbo con el que el resto del catálogo describe un Oro
	virtual puntual, p.ej. kotoku-in/metropolitan 'genera un Oro'), SIN
	restricción de para qué sirve (el texto no dice 'para jugar cartas de
	tipo X' como los demás Oro virtuales de esta sesión), así que el
	predicado es siempre-verdadero.

	IMPORTANTE (2026-09-20): a diferencia del resto de las funciones de este
	archivo, esta NO está registrada en el despachador compartido
	_resolve_look_and_play_patterns() — se llama EXPLÍCITAMENTE desde el
	branch on_turn_end de TriggerResolution._execute_trigger_effect(), con
	la cláusula ya aislada ('en tu fase final'). Motivo: ese branch, como
	todos los de _execute_trigger_effect(), pasa el texto COMPLETO de la
	carta (sin aislar) como primer argumento a _resolve_look_and_play_
	patterns() — si esta función estuviera en la lista compartida, se
	intentaría también durante on_enter_play (con el texto completo, que
	SÍ contiene esta cláusula como substring), disparando la elección de
	Fase Final apenas se equipa el Arma en vez de en la Fase Final real.
	Ver la guardia real usada en try_execute_sable_corto_vigilia_pattern()
	para el caso INVERSO (habilidad activada real, que sí necesita estar en
	la lista compartida porque StackStepResolver._resolve_ability() aísla el
	texto antes de llegar aquí)."""
	var lower := ability_text.to_lower()
	if not ("botar las primeras dos cartas de tu castillo para agrupar un oro" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true
	var deck: Array = CardManager.get_deck(controller_id)
	if deck.is_empty():
		return true
	var use_it: bool = await SelectionManager.await_two_choice(
		main, "¿Botar las primeras dos cartas de tu Castillo para generar un Oro?", "Sí", "No", controller_id)
	if not use_it:
		return true

	await ActionModule.mill(controller_id, 2, false, "Cañón Naval", true)
	var always_true := func(_t, _r, _c) -> bool: return true
	main._gold_manager.generar_oro_virtual_restringido(1, always_true, "Cañón Naval")
	return true


# =============================================================================
# flechar xoon ("Libertadores")
# =============================================================================
func try_execute_flechar_xoon_leave_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando salga del juego, puedes Desterrar una carta de coste 2 o
	menos' (flechar xoon, 2026-09-20). La otra cláusula adicional ('Una vez
	por turno, puedes subir una carta que controles a la mano de su dueño
	para Anular un Talismán o Tótem de coste 2 o menos') se implementó aparte
	en EffectController.offer_flechar_xoon_annul() — no es un trigger propio
	de esta carta sino una reacción a que el RIVAL juegue algo, mismo
	mecanismo real de Almirante Akari (offer_counter_annul), así que vive en
	el mismo choke point que esa carta, no aquí."""
	var lower := ability_text.to_lower()
	if not ("cuando salga del juego, puedes desterrar una carta de coste 2 o menos" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		return true
	var filter := func(c: Node) -> bool:
		if c.get("card_type") == Constants.CardType.ORO:
			return false
		if c.get("current_zone") not in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO]:
			return false
		return ContinuousEffectManager.get_modified_cost(c) <= 2
	var target: Node = await main._card_interaction.await_target(
		"flechar xoon: puedes Desterrar una carta de coste 2 o menos (ESC para no hacerlo)", filter, true, controller_id)
	if not target or not is_instance_valid(target):
		return true
	await ActionModule.banish([target], card, true, true)
	return true


# =============================================================================
# sable corto ("Libertadores")
# =============================================================================
func try_execute_sable_corto_vigilia_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'En tu Vigilia, una vez por turno, tu oponente muestra tantas cartas
	del tope de su Castillo como Fuerza tenga un Aliado que controles y
	ponlas en su Cementerio' (sable corto, 2026-09-20). Habilidad ACTIVADA
	(mismo camino compartido que kotoku-in/la rueda de la fortuna en
	TotemAbilityPatterns.gd) — elige UN Aliado propio, el oponente mill tantas
	cartas como la Fuerza actual (ya modificada) de ese Aliado.

	Guardia 'el portador gana' (2026-09-20): esta función SÍ está en la lista
	compartida de _resolve_look_and_play_patterns() porque una habilidad
	activada real necesita estarlo (StackStepResolver._resolve_ability() la
	invoca con el texto YA AISLADO a esta sola cláusula) — pero esa misma
	lista compartida también se recorre durante on_enter_play con el texto
	COMPLETO de la carta (sin aislar), donde SÍ aparece 'el portador gana 1
	de fuerza e indesterrable' (otra cláusula de sable corto). Sin esta
	guardia, equipar sable corto dispararía esta elección de inmediato en
	vez de esperar a una activación real en Vigilia."""
	var lower := ability_text.to_lower()
	if not ("tu oponente muestra tantas cartas del tope de su castillo como fuerza tenga un aliado que controles" in lower):
		return false
	if "el portador gana" in lower:
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		return true
	var filter := func(c: Node) -> bool:
		if c.get("card_type") != Constants.CardType.ALIADO:
			return false
		if c.get("current_zone") not in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO]:
			return false
		var owner: int = c.get("controller_id") if c.get("controller_id") != null else 0
		return owner == controller_id
	var chosen: Node = await main._card_interaction.await_target(
		"sable corto: elige un Aliado (tu oponente Bota tantas cartas como su Fuerza)", filter, true, controller_id)
	if not chosen or not is_instance_valid(chosen):
		return true
	var strength: int = ContinuousEffectManager.get_modified_strength(chosen)
	if strength <= 0:
		return true
	await ActionModule.mill(1 - controller_id, strength, false, "sable corto", true)
	return true


# =============================================================================
# nehushtan ("Bestiarium")
# =============================================================================
func try_execute_nehushtan_leave_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando salga del juego, Roba dos cartas' (nehushtan, 2026-09-20). Solo
	esta cláusula — 'Si el portador está en Línea de Defensa los jugadores no
	pueden Desterrar cartas del Castillo de su oponente ni Botar cartas'
	queda SIN implementar a propósito: mismo hallazgo de arquitectura ya
	documentado para hojo-shi en arquitectura.md §12.8 (el bloqueo global vía
	ActionValidator.gd es poco confiable porque la mayoría de las llamadas
	reales a Botar/Desterrar del proyecto pasan skip_validation=true) — no es
	un problema de esta carta puntual, es deuda de arquitectura preexistente.
	'Puedes jugarla en Guerra de Talismanes' tampoco se implementó: es una
	excepción de fase AUTO-REFERENCIADA (solo sobre sí misma, no un habilitador
	general como Lobo Sagrado — GoldManagerRestrictions._can_play_weapons_in_
	guerra_talismanes() solo detecta el segundo caso), y modificar el punto
	único de verdad de excepciones de fase (has_phase_exception(), compartido
	por TODA carta del juego) no se alcanzó a hacer con la seguridad debida
	en esta tarea."""
	var lower := ability_text.to_lower()
	if not ("cuando salga del juego, roba dos cartas" in lower):
		return false
	await ActionModule.draw(controller_id, 2, "nehushtan", true)
	return true


# =============================================================================
# azusa yumi ("Espíritu Samurái")
# =============================================================================
func try_execute_azusa_yumi_enter_leave_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando entra o salga del juego, tú Robas una carta y tu oponente Bota
	dos cartas' (azusa yumi, 2026-09-20) — mismo texto cubre AMBOS disparadores
	(on_enter_play y on_leave_play), igual que arco del triunfo. El bono de
	Fuerza dinámico y 'hace daño al Destierro' se resuelven en GoldManager.
	_register_weapon_strength_bonus() al equipar (ver bloque 'azusa_rx' ahí),
	no aquí. 'Puedes jugarla al comienzo de cualquier Fase y puedes tener más
	de tres copias en tu Castillo' queda sin implementar (excepción de fase +
	de construcción de mazo, mismo motivo que la cláusula de fase de
	nehushtan arriba)."""
	var lower := ability_text.to_lower()
	if not ("cuando entra o salga del juego, t" in lower and "robas una carta" in lower and "bota dos cartas" in lower):
		return false
	await ActionModule.draw(controller_id, 1, "azusa yumi", true)
	await ActionModule.mill(1 - controller_id, 2, false, "azusa yumi", true)
	return true


# =============================================================================
# nodachi ("Espíritu Samurái")
# =============================================================================
func try_execute_nodachi_enter_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando entra en juego, mira la mano de tu oponente. Descarta de ahí
	hasta dos Talismanes cuyos costes sumen 2 o menos' (nodachi, 2026-09-20).
	'Los Talismanes cuestan un Oro adicional' se implementó aparte en
	GoldManager._register_weapon_talisman_tax() (efecto ESTÁTICO mientras
	nodachi está equipada, no un trigger de entrada). 'Si el portador es de
	Raza Caballero, Guerrero y/o Héroe, gana 2 de Fuerza y no puede ser
	Barajado' queda SIN implementar a propósito: 'no puede ser Barajado' es
	un tipo de protección que no existe todavía en ningún lado del proyecto
	(grep confirmado, cero resultados) — construir una protección nueva sin
	precedente no alcanzó el tiempo para hacerse con solidez en esta tarea."""
	var lower := ability_text.to_lower()
	if not ("mira la mano de tu oponente" in lower and "descarta de ah" in lower and "talismanes cuyos costes sumen 2 o menos" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true
	var opponent_id: int = 1 - controller_id
	var opponent_hand = main.player_hand if opponent_id == 0 else main._opponent_fan
	if not opponent_hand:
		return true
	var hand_nodes: Array[Node] = opponent_hand.get_cards()
	var talisman_nodes: Array = hand_nodes.filter(func(c: Node) -> bool:
		return is_instance_valid(c) and c.get("card_data") != null and int(c.card_data.get("tipo", -1)) == Constants.CardType.TALISMAN)
	if talisman_nodes.is_empty():
		return true

	if not main._card_interaction:
		return true
	var chosen: Array = await main._card_interaction.await_multi_target(
		"nodachi: elige hasta dos Talismanes de la mano rival cuyos costes sumen 2 o menos", talisman_nodes, 2, Callable(), Callable(), true, null, controller_id)
	var total_cost: int = 0
	var to_discard: Array = []
	for c in chosen:
		if not is_instance_valid(c) or c.get("card_data") == null:
			continue
		var c_cost: int = int(c.card_data.get("coste", 0))
		if total_cost + c_cost > 2:
			continue
		total_cost += c_cost
		to_discard.append(c)
	if to_discard.is_empty():
		return true
	if await TriggerSystem.open_response_window(card, "nodachi", controller_id):
		return true
	for c in to_discard:
		if is_instance_valid(c):
			opponent_hand.remove_card(c, true)
	return true


# =============================================================================
# Armadura Celestial ("Ángeles y Demonios: Vigilantes")
# =============================================================================
func try_execute_armadura_celestial_leave_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando esta Arma salga del juego, puedes Descartar una carta para
	ponerla en tu mano' (Armadura Celestial, 2026-09-20) — 'ponerla' concuerda
	en género con 'esta Arma' (femenino), no con 'una carta' (también
	femenino, ambigüedad real del español impreso): se interpretó como
	recuperar la PROPIA Armadura Celestial del Cementerio a la mano pagando
	el costo de descartar otra carta — lectura fiel al patrón real de MyL de
	'reciclar' un Arma que se va al Cementerio, no 'guardar la carta recién
	descartada'. Se resuelve DESPUÉS de que la carta ya está en el
	Cementerio (no intenta interceptar la transición), así que funciona sin
	importar el orden exacto de eventos de salida de juego.
	'Puedes Destruir el portador para Anular un Talismán de coste 2 o menos o
	cancelar la habilidad de una carta que afecte a un Aliado' queda SIN
	implementar a propósito: es una habilidad ACTIVADA sin disparador fijo
	(el jugador la usa cuando quiera, no en reacción a un evento concreto
	como offer_counter_annul()/flechar xoon), y 'cancelar la habilidad de una
	carta que afecte a un Aliado' no tiene un objetivo claro de a qué
	apuntar en este motor (no hay una cola de efectos-en-curso interceptable,
	ver arquitectura.md §2 sobre el clúster LinkedEffectRegistry/
	TargetSelector) — no alcanzó el tiempo para diseñar esto con solidez."""
	var lower := ability_text.to_lower()
	if not ("cuando esta arma salga del juego, puedes descartar una carta para ponerla en tu mano" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true
	var hand_container = main.player_hand if controller_id == 0 else main._opponent_fan
	if not hand_container or hand_container.cards.is_empty():
		return true
	var card_name: String = str(card.get("card_name")) if card.get("card_name") != null else "Armadura Celestial"
	var cemetery: Array = CardManager.get_cemetery(controller_id)
	var idx: int = -1
	for i in range(cemetery.size()):
		if str(cemetery[i].get("nombre", "")) == card_name:
			idx = i
			break
	if idx < 0:
		return true  # no está en el Cementerio (p.ej. desterrada en vez de destruida) — no hay de dónde recuperarla

	if not main._card_interaction:
		return true
	var hand_cards: Array = hand_container.cards.duplicate()
	var discard_filter := func(c: Node) -> bool: return c in hand_cards
	var to_discard: Node = await main._card_interaction.await_target(
		"%s: puedes Descartar una carta para recuperarla del Cementerio (ESC para no hacerlo)" % card_name, discard_filter, true, controller_id)
	if not to_discard or not is_instance_valid(to_discard):
		return true
	var discard_result: Dictionary = await ActionModule.discard(controller_id, [to_discard], card_name, true)
	if discard_result.get("actual", 0) <= 0:
		return true

	var refreshed_cemetery: Array = CardManager.get_cemetery(controller_id)
	var refreshed_idx: int = -1
	for i in range(refreshed_cemetery.size()):
		if str(refreshed_cemetery[i].get("nombre", "")) == card_name:
			refreshed_idx = i
			break
	if refreshed_idx < 0:
		return true
	var data: Dictionary = refreshed_cemetery[refreshed_idx]
	CardManager.remove_from_cemetery(controller_id, refreshed_idx)
	if main.has_method("_create_card"):
		var new_node = main._create_card(data, false)
		hand_container.add_card(new_node)
		main._connect_card_signals(new_node)
	return true
