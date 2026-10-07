extends RefCounted
## TotemAbilityPatterns — Patrones "try_execute_*_pattern" para Tótems
## detectados sin cobertura en la auditoría de 539 cartas (2026-09-20, ver
## arquitectura.md). Mismo criterio que las 7 mitades de LookAndPlayResolver.gd
## (detección por substring, no por nombre de carta) pero en su propio archivo
## porque ninguna de esas 7 mitades cubría este tipo de carta todavía.
## Instanciado directo en TriggerSystem._ready() como _totem_patterns (mismo
## patrón que _convert_misc_resolver/_draw_shuffle_resolver), llamado desde
## TriggerResolution.gd en los branches on_enter_play/on_leave_play.

var _main: Node

## kotoku-in (2026-09-20): "hacer que el próximo Talismán que juegue tu
## oponente este turno se resuelva sin efecto" — flag de una sola vez por
## controller_id afectado, consumida por TriggerSystem.resolve_talisman() al
## principio de la resolución (mismo canal de retorno que Anular/Cancelar:
## true = no resuelve, va directo al Cementerio). Se guarda el número de
## turno junto al flag para que nunca sobreviva al cambio de turno si el
## rival no llega a jugar ningún Talismán (chequeado en el consumo, no hace
## falta limpieza activa en TurnManager).
var _kotoku_in_talisman_fizzle: Dictionary = {}

## metropolitan (2026-09-20): "convertirlo en un Aliado con Fuerza 3 hasta la
## Fase Final" — Card -> modifier_id de la Fuerza fija, para revertir tipo/
## zona/modificador cuando la fase cambie a FINAL. GameManager.phase_changed
## se conecta una sola vez (guard _metropolitan_signal_connected) la primera
## vez que se usa esta conversión, no en setup() (evita un listener global
## permanente para una carta que puede no estar nunca en la partida).
var _metropolitan_pending_reverts: Dictionary = {}
var _metropolitan_signal_connected: bool = false


func setup(main: Node) -> void:
	_main = main


func register_kotoku_in_talisman_fizzle(target_controller_id: int) -> void:
	_kotoku_in_talisman_fizzle[target_controller_id] = GameManager.current_turn


func consume_kotoku_in_talisman_fizzle(controller_id: int) -> bool:
	if not _kotoku_in_talisman_fizzle.has(controller_id):
		return false
	var set_turn: int = _kotoku_in_talisman_fizzle[controller_id]
	_kotoku_in_talisman_fizzle.erase(controller_id)
	return set_turn == GameManager.current_turn


func try_execute_arco_del_triunfo_pattern(ability_text: String, card: Node, controller_id: int, is_entering: bool) -> bool:
	"""'Cuando entra o sale del juego, muestra cartas de la parte superior de
	tu Castillo hasta mostrar un Aliado o Tótem de coste 2. Ponlo en juego o
	en tu mano y Baraja el resto. Los Aliados que controlas ganan 1 de Fuerza
	y su daño de combate es enviado al Destierro' (arco del triunfo, "Ángeles
	y Demonios: Vigilantes"). Un solo disparador de texto cubre AMBOS
	trigger_type (on_enter_play Y on_leave_play — TriggerResolution.gd ya
	aísla 'cuando entra o sale del juego' para los dos), por eso se llama con
	is_entering explícito desde los dos branches en vez de inferirlo aquí.

	El aura de +1 Fuerza y la redirección de daño son EFECTOS ESTÁTICOS
	'mientras esté en juego' — se registran solo al ENTRAR (is_entering) y
	se limpian solas o se desregistran al SALIR, no dependen de si la
	búsqueda encuentra algo."""
	var lower := ability_text.to_lower()
	if not ("muestra cartas de la parte superior de tu castillo hasta mostrar un aliado o t" in lower):
		return false

	if is_entering:
		# Aura permanente "Tus Aliados ganan 1 de Fuerza" — mecanismo ya
		# usado para auras "Tus Aliados" (ver _card_matches_global_target()
		# en ModifierRegistry.gd), limpieza automática al salir de juego vía
		# EffectController.on_card_left_play → _on_card_left_zone (mismo
		# mecanismo que cualquier otro modificador con source=esta carta).
		ContinuousEffectManager.register_modifier({
			"source": card,
			"target": "ALLIES",
			"filter": {"type": Constants.CardType.ALIADO},
			"stat": "strength",
			"operation": "add",
			"value": 1,
			"duration": ContinuousEffectManager.ModifierDuration.PERMANENT,
			"description": "arco del triunfo: +1 Fuerza a tus Aliados"
		})
		# "Su daño de combate es enviado al Destierro" — infraestructura
		# MUERTA encontrada (2026-09-20, mismo hallazgo que Segundo Sello con
		# Card.damage_goes_to_exile, pero esta vez el otro camino que
		# BattleManager._check_damage_to_exile_effect() ya consultaba y
		# nadie registraba nunca: TriggerSystem.get_active_continuous_
		# effects("damage_to_exile"), filtrado por 'targets contiene
		# player_id' donde player_id es SIEMPRE el DEFENSOR (quien recibe el
		# daño) — no el atacante. Como esta aura cubre TODOS los Aliados
		# propios, presentes y futuros, sin necesitar taggear cada Card, el
		# target correcto es el oponente actual (1 - controller_id): "cuando
		# el oponente reciba daño de mis Aliados, va al Destierro".
		TriggerSystem.register_continuous_effect(card, {
			"type": "damage_to_exile",
			"targets": [1 - controller_id]
		})
	else:
		TriggerSystem.unregister_continuous_effect(card)

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main.has_method("_create_card") or not main._gold_manager:
		return true

	var deck: Array = CardManager.get_deck(controller_id)
	var revealed: Array = []
	var found: Dictionary = {}
	while not deck.is_empty() and found.is_empty():
		var top: Dictionary = deck.pop_front()
		revealed.append(top)
		var t: int = top.get("tipo", -1)
		if (t == Constants.CardType.ALIADO or t == Constants.CardType.TOTEM) and int(top.get("coste", -1)) == 2:
			found = top

	if not found.is_empty():
		revealed.erase(found)
		var options: Array = ["Ponerla en juego (sin pagar su coste)", "Ponerla en tu mano"]
		var choice: int = await SelectionManager.await_choice(main, "%s: ¿dónde poner la carta encontrada?" % (card.card_name if card.get("card_name") else "arco del triunfo"), options, controller_id)
		if choice == 0:
			await main._gold_manager.play_card_for_free(found, controller_id)
		else:
			var card_node = main._create_card(found, false)
			var arco_hand_container = main.player_hand if controller_id == 0 else main._opponent_fan
			arco_hand_container.add_card(card_node)
			main._connect_card_signals(card_node)

	for c in revealed:
		deck.append(c)
	CardManager.shuffle_deck(controller_id)
	AnimationQueue.add_command(AnimationQueue.CommandType.CUSTOM, {
		"callable": Callable(AnimationQueue, "animate_shuffle").bind(controller_id),
		"description": "Barajar mazo (arco del triunfo)"
	})
	if main.get("_zone_manager"):
		main._zone_manager._update_castillo_counts()
	return true


func try_execute_kotoku_in_enter_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando entra en juego, genera un Oro por el turno para jugar cartas
	que no sean Talismán' (kotoku-in, "Espíritu Samurái"). Solo la cláusula
	de entrada — la segunda cláusula ('En tu Vigilia, una vez por turno,
	puedes Destruir una carta de coste 4 o menos o hacer que el próximo
	Talismán que juegue tu oponente este turno se resuelva sin efecto') es
	una habilidad ACTIVADA que necesita un botón nuevo en CardInspectionLayer/
	AbilityButtonSupport (fuera de alcance de esta tarea, sin verificar con
	tiempo suficiente todavía — queda pendiente a propósito)."""
	var lower := ability_text.to_lower()
	if not ("genera un oro por el turno para jugar cartas que no sean talism" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true

	var predicate := func(card_type, _card_race, _card_cost) -> bool:
		return card_type != Constants.CardType.TALISMAN
	main._gold_manager.generar_oro_virtual_restringido(1, predicate, "kotoku-in")
	return true


func try_execute_metropolitan_enter_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando entra en juego, genera un Oro para Aliados de coste 2 o más o
	Roba dos cartas' (metropolitan, "Kaiju vs Mecha - Titanes"). Solo la
	cláusula de entrada — la conversión en Aliado de Vigilia se implementó
	aparte (try_execute_metropolitan_vigilia_convert_pattern, más abajo). La
	tercera ('Cuando ataca, un Aliado que no sea Metropolitan se convierte
	por el turno en un Aliado de Fuerza y coste 5') queda pendiente a
	propósito: solo tiene sentido una vez que metropolitan YA se convirtió en
	Aliado y de hecho ataca, y elegir/aplicar el buff a OTRO Aliado en ese
	momento puntual no alcanzó a verificarse con solidez en esta tarea."""
	var lower := ability_text.to_lower()
	if not ("genera un oro para aliados de coste 2 o m" in lower and "roba dos cartas" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._gold_manager:
		return true

	var options: Array = ["Generar un Oro (para Aliados de coste 2 o más)", "Robar dos cartas"]
	var choice: int = await SelectionManager.await_choice(main, "%s: elige un efecto" % (card.card_name if card.get("card_name") else "metropolitan"), options, controller_id)
	if choice == 0:
		var predicate := func(card_type, _card_race, card_cost) -> bool:
			return card_type == Constants.CardType.ALIADO and int(card_cost) >= 2
		main._gold_manager.generar_oro_virtual_restringido(1, predicate, "metropolitan")
	else:
		await ActionModule.draw(controller_id, 2, "metropolitan", true)
	return true


func try_execute_kotoku_in_vigilia_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'En tu Vigilia, una vez por turno, puedes Destruir una carta de coste
	2 o menos o hacer que el próximo Talismán que juegue tu oponente este
	turno se resuelva sin efecto' (kotoku-in, "Espíritu Samurái"). Habilidad
	ACTIVADA — llega aquí vía TriggerSystem.resolve_ability_effect() (el
	mismo _resolve_look_and_play_patterns() que usan los triggers, ver
	arquitectura.md 2026-08-27), el botón y el cupo 'una vez por turno' ya
	los resuelve genéricamente UniversalCardParser/ActionPipeline.
	activate_ability() antes de llegar aquí — no hay que reimplementarlos.

	La opción 'destruye coste 2 o menos' es directa (ActionModule.destroy());
	la opción 'próximo Talismán rival sin efecto' es una bandera de una sola
	vez consumida en TriggerSystem.resolve_talisman() (ver
	consume_kotoku_in_talisman_fizzle() arriba) — sin precedente de un
	'contador de anulación diferida' en el proyecto antes de esto.

	Guardia 'genera un oro por el turno' (2026-09-20, bug real encontrado en
	revisión de código, no reportado por el usuario): esta función SÍ está en
	la lista compartida de _resolve_look_and_play_patterns() porque la
	activación real necesita estarlo (StackStepResolver._resolve_ability() la
	invoca con el texto YA AISLADO a esta sola cláusula) — pero esa misma
	lista compartida también se recorre durante on_enter_play con el texto
	COMPLETO de kotoku-in (sin aislar), donde SÍ aparece su otra cláusula
	'genera un oro por el turno para jugar cartas que no sean Talismán'. Sin
	esta guardia, jugar kotoku-in disparaba esta elección de inmediato en vez
	de esperar a una activación real en Vigilia (mismo patrón de bug ya
	corregido en sable_corto_vigilia, ver WeaponAbilityPatterns.gd)."""
	var lower := ability_text.to_lower()
	if not ("destruir una carta de coste 2 o menos" in lower and "se resuelva sin efecto" in lower):
		return false
	if "genera un oro por el turno" in lower:
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		return true

	var options: Array = ["Destruir una carta de coste 2 o menos", "El próximo Talismán rival este turno no tiene efecto"]
	var choice: int = await SelectionManager.await_choice(main, "%s: elige un efecto" % (card.card_name if card.get("card_name") else "kotoku-in"), options, controller_id)
	if choice == 0:
		var filter := func(c: Node) -> bool:
			if c.get("card_type") == Constants.CardType.ORO:
				return false
			return ContinuousEffectManager.get_modified_cost(c) <= 2
		var target: Node = await main._card_interaction.await_target("Elige una carta de coste 2 o menos para Destruir", filter, true, controller_id)
		if target and is_instance_valid(target):
			await ActionModule.destroy([target], card, true, true)
	else:
		register_kotoku_in_talisman_fizzle(1 - controller_id)
	return true


func try_execute_metropolitan_vigilia_convert_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'En tu Vigilia, puedes convertirlo en un Aliado con Fuerza 3 hasta la
	Fase Final' (metropolitan). Habilidad ACTIVADA — mismo camino genérico
	que kotoku-in arriba. Mecanismo de conversión Tótem→Aliado calcado del
	precedente real ya existente en el proyecto (ConvertAndMiscResolver.
	try_execute_mill_convert_to_ally_pattern, Sherlock Holmes: mover de
	contenedor, card_type = ALIADO, set_zone(LINEA_DEFENSA), modificador de
	Fuerza fija operation='set') — la única diferencia real es que aquí la
	conversión es TEMPORAL (revierte en la Fase Final, no permanente), por
	eso el modificador se registra con source=card (para poder ubicarlo por
	source_id al revertir) y se guarda el Node en _metropolitan_pending_
	reverts hasta que GameManager.phase_changed emita FINAL.

	Guardia 'genera un oro para aliados' (2026-09-20, bug real encontrado en
	revisión de código, no reportado por el usuario): mismo motivo exacto que
	la guardia de try_execute_kotoku_in_vigilia_pattern() de arriba — esta
	función está en la lista compartida de _resolve_look_and_play_patterns()
	porque la activación real la necesita ahí (texto ya aislado), pero esa
	misma lista se recorre también durante on_enter_play con el texto
	COMPLETO de metropolitan (sin aislar), donde SÍ aparece su otra cláusula
	de entrada ('genera un oro para Aliados de coste 2 o más o Roba dos
	cartas'). Sin esta guardia, jugar metropolitan lo convertía en Aliado de
	inmediato en vez de esperar una activación real en Vigilia."""
	var lower := ability_text.to_lower()
	if not ("convertirlo en un aliado con fuerza 3 hasta la fase final" in lower):
		return false
	if "genera un oro para aliados" in lower:
		return false
	if card.get("card_type") == Constants.CardType.ALIADO:
		return true  # ya convertido este turno, nada que hacer

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true

	var target_field: HBoxContainer = main.player_field if controller_id == 0 else main.opponent_field
	var old_parent := card.get_parent()
	if old_parent and old_parent != target_field:
		old_parent.remove_child(card)
		target_field.add_child(card)
	card.card_type = Constants.CardType.ALIADO
	if card.has_method("set_zone"):
		card.set_zone(Constants.Zone.LINEA_DEFENSA)

	ContinuousEffectManager.register_modifier({
		"source": card,
		"target": card,
		"type": ContinuousEffectManager.ModifierType.STRENGTH,
		"stat": "strength",
		"value": 3,
		"operation": "set",
		"duration": ContinuousEffectManager.ModifierDuration.PERMANENT,
		"layer": ContinuousEffectManager.ModifierLayer.LAYER_7A_CHAR_SETTING,
		"description": "metropolitan convertido en Aliado: Fuerza 3"
	})
	_metropolitan_pending_reverts[card] = true
	if not _metropolitan_signal_connected:
		_metropolitan_signal_connected = true
		GameManager.phase_changed.connect(_on_phase_changed_revert_metropolitan)
	return true


func _on_phase_changed_revert_metropolitan(new_phase: Constants.Phase) -> void:
	if new_phase != Constants.Phase.FINAL:
		return
	if _metropolitan_pending_reverts.is_empty():
		return
	for target_card: Node in _metropolitan_pending_reverts.keys():
		if not is_instance_valid(target_card):
			continue
		if target_card.get("card_type") != Constants.CardType.ALIADO:
			continue  # salió de juego o ya se revirtió por otro camino
		ContinuousEffectManager.remove_modifiers_from_source(target_card)
		target_card.card_type = Constants.CardType.TOTEM
		var owner: int = target_card.get("controller_id") if target_card.get("controller_id") != null else 0
		var totem_field: HBoxContainer = _main.get_node_or_null("/root/Main").player_linea_apoyo if owner == 0 else _main.get_node_or_null("/root/Main").opponent_linea_apoyo
		var old_parent: Node = target_card.get_parent()
		if totem_field and old_parent and old_parent != totem_field:
			old_parent.remove_child(target_card)
			totem_field.add_child(target_card)
		if target_card.has_method("set_zone"):
			target_card.set_zone(Constants.Zone.LINEA_APOYO)
	_metropolitan_pending_reverts.clear()


func try_execute_metropolitan_attack_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando ataca, un Aliado que no sea Metropolitan se convierte por el
	turno en un Aliado de Fuerza y coste 5' — solo dispara de verdad cuando
	metropolitan YA se convirtió en Aliado (try_execute_metropolitan_vigilia_
	convert_pattern) y de hecho ataca; para ese momento card_type ya es
	ALIADO, así que el trigger on_attack genérico lo recoge igual que a
	cualquier otro Aliado, sin chequeo especial aquí. 'Por el turno' = TIMED
	duration_value=1 (mismo cálculo que Tercer Sello: decuenta en el primer
	fin de turno, que es el de ESTE mismo turno de ataque)."""
	var lower := ability_text.to_lower()
	if not ("un aliado que no sea metropolitan se convierte por el turno en un aliado de fuerza y coste 5" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		return true
	var filter := func(c: Node) -> bool:
		if c == card or c.get("card_type") != Constants.CardType.ALIADO:
			return false
		var owner: int = c.get("controller_id") if c.get("controller_id") != null else 0
		return owner == controller_id and c.get("current_zone") in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE]
	var target: Node = await main._card_interaction.await_target("Elige un Aliado (no Metropolitan) para volverse Fuerza y coste 5 este turno", filter, true, controller_id)
	if not target or not is_instance_valid(target):
		return true

	ContinuousEffectManager.register_modifier({
		"source": card, "target": target,
		"type": ContinuousEffectManager.ModifierType.STRENGTH, "stat": "strength",
		"value": 5, "operation": "set",
		"duration": ContinuousEffectManager.ModifierDuration.TIMED, "duration_value": 1,
		"layer": ContinuousEffectManager.ModifierLayer.LAYER_7A_CHAR_SETTING,
		"description": "metropolitan: Fuerza 5 este turno"
	})
	ContinuousEffectManager.register_modifier({
		"source": card, "target": target,
		"type": ContinuousEffectManager.ModifierType.COST, "stat": "cost",
		"value": 5, "operation": "set",
		"duration": ContinuousEffectManager.ModifierDuration.TIMED, "duration_value": 1,
		"layer": ContinuousEffectManager.ModifierLayer.LAYER_7A_CHAR_SETTING,
		"description": "metropolitan: coste 5 este turno"
	})
	return true


func try_execute_rueda_fortuna_reveal_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Una vez por turno, muestra la primera carta de tu Castillo. Tus
	Aliados ganan tanta Fuerza como coste tenga esa carta. Si es un Oro,
	puedes ponerlo en tu mano y Robar una carta' (la rueda de la fortuna,
	"Secretos Arcanos"). Habilidad ACTIVADA (mismo camino compartido que
	kotoku-in/metropolitan arriba). El pump de Fuerza es un modificador
	PERMANENT por Aliado en juego en ESE momento (mismo criterio ya usado
	para Kuchiku Kan: 'permanentemente' en el texto, no 'los Aliados que
	controles' en presente continuo — no es un aura que siga a futuros
	Aliados). La carta se MIRA (no se saca del Castillo) salvo que sea un
	Oro y el jugador elija tomarla."""
	var lower := ability_text.to_lower()
	if not ("muestra la primera carta de tu castillo" in lower and "tus aliados ganan tanta fuerza como coste tenga esa carta" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main.has_method("_create_card"):
		return true
	var deck: Array = CardManager.get_deck(controller_id)
	if deck.is_empty():
		return true
	var top: Dictionary = deck[0]
	var top_cost: int = int(top.get("coste", 0))

	var allies: Array = []
	var ally_fields: Array = [main.player_field, main.player_linea_ataque] if controller_id == 0 else [main.opponent_field, main.opponent_linea_ataque]
	for f in ally_fields:
		if not f:
			continue
		for c in f.get_children():
			if c.get("card_type") == Constants.CardType.ALIADO:
				allies.append(c)
	for ally in allies:
		if top_cost > 0:
			ContinuousEffectManager.register_modifier({
				"source": ally, "target": ally,
				"type": ContinuousEffectManager.ModifierType.STRENGTH, "stat": "strength",
				"value": top_cost, "operation": "add",
				"duration": ContinuousEffectManager.ModifierDuration.PERMANENT,
				"description": "la rueda de la fortuna: +%d Fuerza" % top_cost
			})

	if top.get("tipo", -1) == Constants.CardType.ORO:
		var options: Array = ["Ponerlo en tu mano y robar una carta", "Dejarlo en el Castillo"]
		var choice: int = await SelectionManager.await_choice(main, "%s: ¿qué hacer con el Oro revelado?" % (card.card_name if card.get("card_name") else "la rueda de la fortuna"), options, controller_id)
		if choice == 0:
			deck.pop_front()
			var card_node = main._create_card(top, false)
			var rueda_hand_container = main.player_hand if controller_id == 0 else main._opponent_fan
			rueda_hand_container.add_card(card_node)
			main._connect_card_signals(card_node)
			await ActionModule.draw(controller_id, 1, "la rueda de la fortuna", true)
			if main.get("_zone_manager"):
				main._zone_manager._update_castillo_counts()
	return true


func try_execute_rueda_fortuna_sacrifice_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Puedes Destruirlo para que tus Aliados no puedan ser afectados por
	efectos oponentes este turno' (la rueda de la fortuna). Reutiliza el
	campo protection_type='ALL' del sistema de Protección ya existente
	(KeywordQuery.has_protection(): 'ALL' matchea cualquier protection_type
	consultado) — cobertura REAL pero PARCIAL: solo bloquea en los puntos
	del código que efectivamente consultan has_protection() (hoy: selección
	de objetivo de Talismanes y 'fuera del juego mientras ataca'), no
	literalmente cualquier efecto oponente posible — mismo tipo de
	limitación ya documentada para Segundo Sello (damage_goes_to_exile solo
	cubre daño al Castillo)."""
	var lower := ability_text.to_lower()
	if not ("puedes destruirlo para que tus aliados no puedan ser afectados por efectos oponentes este turno" in lower):
		return false

	await ActionModule.destroy([card], card, false, true)
	ContinuousEffectManager.register_modifier({
		"source": card, "target": "ALLIES",
		"filter": {"type": Constants.CardType.ALIADO},
		"type": ContinuousEffectManager.ModifierType.PROTECTION, "stat": "",
		"value": 0, "operation": "add",
		"duration": ContinuousEffectManager.ModifierDuration.TIMED, "duration_value": 1,
		"layer": ContinuousEffectManager.ModifierLayer.LAYER_6_ABILITIES,
		"protection_type": "ALL",
		"description": "la rueda de la fortuna: protección este turno"
	})
	return true


func try_execute_iga_ryu_enter_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando entra en juego, agrupa dos cartas o gana el control de
	cualquier carta oponente' (iga ryu, "Espíritu Samurái"). Solo la rama
	'gana el control' — reutiliza ContinuousEffectManager.gain_control_of_
	card(), el mismo helper real ya usado por shedo titan (MiscUniquePatterns.
	gd). La rama 'agrupa dos cartas' queda SIN implementar a propósito:
	'Agrupar' no es un verbo con acción propia en ningún otro lugar del
	motor (no existe ningún Card.is_tapped ni ActionModule.agrupar()) y no
	alcanzó el tiempo para confirmar con certeza a qué corresponde en las
	reglas reales antes de inventar un mecanismo nuevo sin precedente. Las
	otras dos cláusulas ('el primer Aliado que entre bajo el control de tu
	oponente cada turno pierde su habilidad' y 'una vez por turno, convertir
	hasta tres Tótem en Aliados de Fuerza 4') también quedan pendientes."""
	var lower := ability_text.to_lower()
	if not ("gana el control de cualquier carta oponente" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main or not main._card_interaction:
		return true
	var opponent_id: int = 1 - controller_id
	var in_play_zones: Array = [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO]
	var filter := func(c: Node) -> bool:
		if c.get("card_type") == Constants.CardType.ORO:
			return false
		var owner: int = c.get("controller_id") if c.get("controller_id") != null else 0
		return owner == opponent_id and c.get("current_zone") in in_play_zones
	var target: Node = await main._card_interaction.await_target("Elige una carta oponente para ganar su control", filter, true, controller_id)
	if not target or not is_instance_valid(target):
		return true
	if await TriggerSystem.open_response_window(card, str(card.card_name) if card.get("card_name") else "iga ryu", controller_id):
		return true
	ContinuousEffectManager.gain_control_of_card(target, controller_id)
	return true


func try_execute_estacion_fantasma_name_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Una vez por turno, puedes nombrar una carta que no sea Oro. Tu
	oponente Baraja las cartas que controle con ese nombre' (Estación
	Fantasma, "Chile Oscuro 2"). Habilidad ACTIVADA. Reutiliza _main.
	_card_name_search.open_and_wait() (Malleus Maleficarum/Alicia en
	Wonderland) para el diálogo de nombrar, y ActionReturnDiscard.
	return_to_deck() (Legión Paladín) por cada carta EN JUEGO que coincida
	— busca solo en Línea de Defensa/Ataque/Apoyo del oponente (Aliados,
	Armas equipadas, Tótems; Oro excluido por el propio filtro del nombrado,
	no hace falta revisar Reserva/Oro Pagado). La segunda cláusula ('Cuando
	ataques, elige hasta dos Aliados con Furia...') queda pendiente — no
	alcanzó el tiempo para resolver con solidez la selección + prevención de
	daño + destierro proporcional a Fuerza desde el fondo del Castillo."""
	var lower := ability_text.to_lower()
	if not ("nombra una carta que no sea oro" in lower and "tu oponente baraja las cartas que controle con ese nombre" in lower):
		return false
	if controller_id != 0:
		return true  # el bot no usa esta habilidad todavía

	var picked: Dictionary = await _main._card_name_search.open_and_wait(
		"Nombra una carta que no sea Oro (tu oponente baraja las que controle con ese nombre)")
	if picked.is_empty():
		return true
	var picked_name: String = str(picked.get("nombre", ""))
	if picked_name.is_empty() or int(picked.get("tipo", -1)) == Constants.CardType.ORO:
		return true

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true
	if await TriggerSystem.open_response_window(card, str(card.card_name) if card.get("card_name") else "Estación Fantasma", controller_id):
		return true

	var opponent_id: int = 1 - controller_id
	var opponent_fields: Array = [main.player_field, main.player_linea_ataque, main.player_linea_apoyo] if opponent_id == 0 else [main.opponent_field, main.opponent_linea_ataque, main.opponent_linea_apoyo]
	var to_shuffle: Array = []
	for f in opponent_fields:
		if not f:
			continue
		for c in f.get_children():
			if str(c.get("card_name")) == picked_name:
				to_shuffle.append(c)
	for c in to_shuffle:
		# Sin await, shuffle_deck() corría antes de que return_to_deck()
		# terminara de insertar la carta en el mazo (espera la ventana de
		# Prevención real) — el barajado podía tocar un mazo que todavía no
		# tenía la carta devuelta.
		await ActionModule.return_to_deck(c, opponent_id, true, card)
	if not to_shuffle.is_empty():
		CardManager.shuffle_deck(opponent_id)
	return true


func try_execute_hangar_ciudadela_enter_pattern(ability_text: String, card: Node, controller_id: int) -> bool:
	"""'Cuando entra en juego, tu oponente Baraja una carta de su mano y tú
	Robas dos cartas' (hangar de la ciudadela, "Kaiju vs Mecha - Titanes").
	Solo la cláusula de entrada. Las otras dos ('Los Aliados de coste o
	Fuerza 0 no pueden atacar ni disparar sus habilidades' y 'Si Botas esta
	carta desde tu Castillo por daño, dejas de Botar cartas y Destierra este
	Tótem') quedan pendientes a propósito: la primera necesita un bloqueo de
	ATAQUE (no solo de habilidades, que sí tiene precedente vía Tercer
	Sello) sin ningún gancho existente en la declaración de atacantes; la
	segunda es un reemplazo de efecto sobre daño-al-Castillo específico a
	ESTA carta (no una redirección genérica como arco del triunfo), y no
	alcanzó el tiempo para verificar con solidez el punto exacto donde
	`_check_damage_to_exile_effect`-adyacente resuelve qué cartas se botan
	por daño antes de interceptarlo ahí con seguridad."""
	var lower := ability_text.to_lower()
	if not ("tu oponente baraja una carta de su mano y t" in lower and "robas dos cartas" in lower):
		return false

	var main := _main.get_node_or_null("/root/Main")
	if not main:
		return true
	# La mano real del oponente (con datos reales, boca abajo si es el Remoto)
	# vive en player_hand si el oponente es el jugador 0, o en _opponent_fan si
	# es el jugador 1 — 'opponent_hand' no existe como propiedad en Main.gd. Se
	# devuelve al MAZO de datos (CardManager.get_deck), no vía ActionModule.
	# return_to_deck() (esa función asume una carta EN JUEGO, no en la mano).
	var opponent_id: int = 1 - controller_id
	var opponent_hand_hangar = main.player_hand if opponent_id == 0 else main._opponent_fan
	if opponent_hand_hangar:
		var hand_nodes: Array[Node] = opponent_hand_hangar.get_cards()
		if not hand_nodes.is_empty():
			var chosen_node: Node = hand_nodes[randi() % hand_nodes.size()]
			if is_instance_valid(chosen_node) and chosen_node.get("card_data") != null:
				var data: Dictionary = chosen_node.card_data.duplicate()
				opponent_hand_hangar.remove_card(chosen_node, true)
				CardManager.get_deck(opponent_id).append(data)
				CardManager.shuffle_deck(opponent_id)
	await ActionModule.draw(controller_id, 2, "hangar de la ciudadela", true)
	return true
