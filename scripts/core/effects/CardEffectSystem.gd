extends Node
## CardEffectSystem - Sistema de resolución de habilidades de cartas
## Escucha entradas a zonas y procesa triggers/habilidades automáticas

# =============================================================================
# SIGNALS
# =============================================================================
# Triggers de entrada a zonas específicas
signal on_entered_gold_reserve(player_id: int, card: Node)
signal on_entered_defense_line(player_id: int, card: Node)
signal on_entered_support_line(player_id: int, card: Node)
signal on_entered_attack_line(player_id: int, card: Node)

# Habilidades Continuas
signal continuous_ability_activated(card: Node, ability: Dictionary)
signal continuous_ability_deactivated(card: Node, ability: Dictionary)
signal continuous_effect_applied(source: Node, target: Node, effect: Dictionary)
signal continuous_effect_removed(source: Node, target: Node, effect: Dictionary)

# =============================================================================
# ZONAS DE ENTRADA MONITOREADAS
# =============================================================================
const MONITORED_ZONES: Array[int] = [
	Constants.Zone.RESERVA_ORO,
	Constants.Zone.LINEA_DEFENSA,
	Constants.Zone.LINEA_APOYO,
	Constants.Zone.LINEA_ATAQUE
]

# =============================================================================
# ESTADO
# =============================================================================
## Habilidades continuas activas (por carta fuente)
## Estructura: {card_id: {ability_id: {type, effect, targets, zone_required}}}
var active_continuous_abilities: Dictionary = {}

## Efectos continuos aplicados a cartas
## Estructura: {target_card_id: [{source, effect_type, value, ability_id}]}
var applied_continuous_effects: Dictionary = {}


func _ready() -> void:
	print("[CardEffectSystem] Inicializado")
	_connect_to_effect_controller()


func _connect_to_effect_controller() -> void:
	"""Conecta al EffectController para escuchar entradas y salidas de zonas"""
	var effect_ctrl = get_node_or_null("/root/EffectController")

	if effect_ctrl:
		# Conectar a la señal de entrada al juego
		var enter_callable = Callable(self, "_on_card_entered_play")
		if not effect_ctrl.on_card_entered_play.is_connected(enter_callable):
			effect_ctrl.on_card_entered_play.connect(enter_callable)

		# Conectar a la señal de salida del juego (para desactivar habilidades continuas)
		var leave_callable = Callable(self, "_on_card_left_play")
		if not effect_ctrl.on_card_left_play.is_connected(leave_callable):
			effect_ctrl.on_card_left_play.connect(leave_callable)

		print("[CardEffectSystem] Conectado a EffectController (entrada y salida)")
	else:
		# Reintentar en el siguiente frame (por orden de autoloads)
		call_deferred("_connect_to_effect_controller")


# =============================================================================
# LISTENER DE ENTRADA A ZONAS
# =============================================================================
func _on_card_entered_play(player_id: int, card: Node, zone: int) -> void:
	"""Listener principal: se activa cuando una carta entra a cualquier zona de juego
	Filtra y emite señales específicas según la zona
	"""
	print("[CardEffectSystem] Carta entró a %s: %s" % [
		Constants.ZONE_NAMES.get(zone, "?"),
		card.card_name if card.get("card_name") else str(card)
	])

	# Verificar si es una zona monitoreada
	if zone not in MONITORED_ZONES:
		return

	# Emitir señal específica según la zona
	match zone:
		Constants.Zone.RESERVA_ORO:
			_handle_gold_reserve_entry(player_id, card)

		Constants.Zone.LINEA_DEFENSA:
			_handle_defense_line_entry(player_id, card)

		Constants.Zone.LINEA_APOYO:
			_handle_support_line_entry(player_id, card)

		Constants.Zone.LINEA_ATAQUE:
			_handle_attack_line_entry(player_id, card)

	# NO llamar aquí a _process_etb_trigger(): TriggerSystem también escucha
	# esta misma señal (on_card_entered_play) y ejecuta el texto de habilidad
	# vía UniversalCardParser → ActionModule, que es el camino más completo
	# (respeta conectores Y/Luego/O, orden APNAP entre jugadores). Si ambos
	# se ejecutaran, un "roba 2" robaría el doble. _process_etb_trigger()
	# queda como código muerto a propósito — ver docs/audit, hallazgo de
	# efectos de carta (sesión 2026-08-16).


func _handle_gold_reserve_entry(player_id: int, card: Node) -> void:
	"""Maneja entrada a Reserva de Oro
	Activa habilidades continuas del Oro si las tiene
	"""
	print("[CardEffectSystem] Oro colocado en Reserva: %s" % (
		card.card_name if card.get("card_name") else "Carta"
	))

	emit_signal("on_entered_gold_reserve", player_id, card)

	# Verificar si la carta tiene habilidad especial de oro
	if card.has_method("on_placed_as_gold"):
		card.on_placed_as_gold()

	# Procesar habilidades continuas del Oro (ej: "Tus Aliados ganan +1 Fuerza")
	await _process_gold_continuous_ability(card, player_id)

	# Recalcular efectos continuos del tablero
	await recalculate_all_continuous_effects()


func _handle_defense_line_entry(player_id: int, card: Node) -> void:
	"""Maneja entrada a Línea de Defensa
	Los Aliados entran aquí cuando se juegan
	"""
	var card_name = card.card_name if card.get("card_name") else "Carta"
	print("[CardEffectSystem] Aliado entró a Línea de Defensa: %s" % card_name)

	emit_signal("on_entered_defense_line", player_id, card)

	# Recalcular efectos continuos (este aliado puede recibir buffs)
	call_deferred("recalculate_all_continuous_effects")


func _handle_support_line_entry(player_id: int, card: Node) -> void:
	"""Maneja entrada a Línea de Apoyo
	Armas, Tótems y algunas cartas de apoyo van aquí
	"""
	var card_name = card.card_name if card.get("card_name") else "Carta"
	print("[CardEffectSystem] Carta entró a Línea de Apoyo: %s" % card_name)

	emit_signal("on_entered_support_line", player_id, card)

	# Recalcular efectos continuos
	call_deferred("recalculate_all_continuous_effects")


func _handle_attack_line_entry(player_id: int, card: Node) -> void:
	"""Maneja entrada a Línea de Ataque
	Los Aliados se mueven aquí durante la Agrupación o al atacar
	"""
	var card_name = card.card_name if card.get("card_name") else "Carta"
	print("[CardEffectSystem] Aliado entró a Línea de Ataque: %s" % card_name)

	emit_signal("on_entered_attack_line", player_id, card)

	# Recalcular efectos continuos
	call_deferred("recalculate_all_continuous_effects")


# =============================================================================
# SISTEMA ETB / PIPELINE DE EJECUCIÓN DE ACCIONES — ELIMINADO (2026-08-17)
# =============================================================================
# Todo lo que vivía acá (cola de habilidades ETB/activadas/disparadas,
# execute_draw/execute_search/execute_look/execute_mill/execute_discard/
# execute_return_to_deck, execute_action_pipeline y su parser de texto
# propio) tenía CERO llamadores en todo el proyecto — código muerto desde
# antes de esta sesión. _on_card_entered_play() ya documentaba (más abajo)
# que _process_etb_trigger() no se llama a propósito: TriggerSystem
# escucha la misma señal on_card_entered_play y resuelve el texto de
# habilidad vía UniversalCardParser → ActionModule, que es el camino real.
# Auditado función por función (68 funciones revisadas) antes de recortar
# — lo único que SÍ estaba vivo de este archivo (el sistema de habilidades
# continuas de Oro y los handlers on_card_entered_play/on_card_left_play)
# sigue más abajo, intacto.
# =============================================================================
# LISTENER DE SALIDA DE ZONAS
# =============================================================================
func _on_card_left_play(player_id: int, card: Node, from_zone: int) -> void:
	"""Handler para cuando una carta sale del juego
	Desactiva todas las habilidades continuas de esa carta
	"""
	var card_id = card.get_instance_id()

	print("[CardEffectSystem] Carta salió de %s: %s" % [
		Constants.ZONE_NAMES.get(from_zone, "?"),
		card.card_name if card.get("card_name") else str(card)
	])

	# Desactivar habilidades continuas de esta carta
	if active_continuous_abilities.has(card_id):
		await _deactivate_all_continuous_abilities(card)


# =============================================================================
# SISTEMA DE HABILIDADES CONTINUAS (DAR 7.3)
# =============================================================================

## Tipos de habilidades continuas
enum ContinuousAbilityType {
	BUFF_ALLIES,        # "Tus Aliados ganan +X Fuerza"
	DEBUFF_ENEMIES,     # "Los Aliados rivales tienen -X Fuerza"
	COST_REDUCTION,     # "Tus cartas cuestan X menos"
	PROTECTION,         # "Tus Aliados no pueden ser destruidos"
	RESTRICTION,        # "Los Aliados rivales no pueden atacar"
	KEYWORD_GRANT,      # "Tus Aliados tienen Furia"
	STAT_MODIFICATION   # Modificación genérica de stats
}


func register_continuous_ability(source_card: Node, ability: Dictionary) -> String:
	"""Registra una habilidad continua de una carta
	Se activa mientras la carta esté en la zona requerida

	ability debe contener:
	- type: ContinuousAbilityType
	- effect_type: String ("attack", "defense", "cost", etc.)
	- value: int (puede ser negativo para debuffs)
	- targets: String ("own_allies", "enemy_allies", "all_allies", "self")
	- zone_required: int (zona donde debe estar la fuente, -1 para cualquiera)
	- condition: Callable opcional

	Returns: ID único de la habilidad
	"""
	var card_id = source_card.get_instance_id()
	var ability_id = "%d_%d" % [card_id, Time.get_ticks_msec()]

	ability["id"] = ability_id
	ability["source"] = source_card
	ability["active"] = false

	if not active_continuous_abilities.has(card_id):
		active_continuous_abilities[card_id] = {}

	active_continuous_abilities[card_id][ability_id] = ability

	print("[CardEffectSystem] Habilidad continua registrada: %s de %s" % [
		ability.get("effect_type", "?"),
		source_card.card_name if source_card.get("card_name") else str(source_card)
	])

	return ability_id


func activate_continuous_ability(source_card: Node, ability_id: String) -> bool:
	"""Activa una habilidad continua registrada
	Aplica los efectos a todos los objetivos válidos
	"""
	var card_id = source_card.get_instance_id()

	if not active_continuous_abilities.has(card_id):
		return false

	if not active_continuous_abilities[card_id].has(ability_id):
		return false

	var ability = active_continuous_abilities[card_id][ability_id]

	# Verificar zona requerida
	var zone_required = ability.get("zone_required", -1)
	if zone_required >= 0:
		var current_zone = source_card.current_zone if source_card.get("current_zone") != null else -1
		if current_zone != zone_required:
			print("[CardEffectSystem] Zona incorrecta para activar habilidad")
			return false

	# Marcar como activa
	ability["active"] = true

	# Aplicar efectos a objetivos
	await _apply_continuous_effects(source_card, ability)

	emit_signal("continuous_ability_activated", source_card, ability)
	print("[CardEffectSystem] Habilidad continua ACTIVADA: %s" % ability_id)

	return true


func deactivate_continuous_ability(source_card: Node, ability_id: String) -> bool:
	"""Desactiva una habilidad continua y remueve sus efectos"""
	var card_id = source_card.get_instance_id()

	if not active_continuous_abilities.has(card_id):
		return false

	if not active_continuous_abilities[card_id].has(ability_id):
		return false

	var ability = active_continuous_abilities[card_id][ability_id]

	if not ability.get("active", false):
		return false

	# Remover efectos de todos los objetivos
	await _remove_continuous_effects(source_card, ability)

	ability["active"] = false

	emit_signal("continuous_ability_deactivated", source_card, ability)
	print("[CardEffectSystem] Habilidad continua DESACTIVADA: %s" % ability_id)

	return true


func _deactivate_all_continuous_abilities(source_card: Node) -> void:
	"""Desactiva todas las habilidades continuas de una carta"""
	var card_id = source_card.get_instance_id()

	if not active_continuous_abilities.has(card_id):
		return

	var abilities = active_continuous_abilities[card_id].duplicate()

	for ability_id in abilities:
		await deactivate_continuous_ability(source_card, ability_id)

	active_continuous_abilities.erase(card_id)
	print("[CardEffectSystem] Todas las habilidades continuas desactivadas para carta")


func _apply_continuous_effects(source_card: Node, ability: Dictionary) -> void:
	"""Aplica los efectos continuos a todos los objetivos válidos"""
	var targets = _get_continuous_ability_targets(source_card, ability)
	var effect_type = ability.get("effect_type", "")
	var value = ability.get("value", 0)
	var ability_id = ability.get("id", "")

	for target in targets:
		await _apply_single_continuous_effect(source_card, target, ability)


func _remove_continuous_effects(source_card: Node, ability: Dictionary) -> void:
	"""Remueve los efectos continuos de todos los objetivos"""
	var card_id = source_card.get_instance_id()
	var ability_id = ability.get("id", "")

	# Buscar todos los efectos aplicados por esta habilidad
	for target_id in applied_continuous_effects.keys():
		var effects = applied_continuous_effects[target_id]
		var to_remove: Array = []

		for i in range(effects.size()):
			if effects[i].get("ability_id") == ability_id:
				to_remove.append(i)

		# Remover en orden inverso para no afectar índices
		for i in range(to_remove.size() - 1, -1, -1):
			var effect = effects[to_remove[i]]
			var target = effect.get("target")

			# Remover modificador de la carta objetivo
			if is_instance_valid(target) and target.has_method("remove_modifier"):
				target.remove_modifier(effect.get("effect_type", ""), ability_id)

			emit_signal("continuous_effect_removed", source_card, target, effect)
			effects.remove_at(to_remove[i])


func _apply_single_continuous_effect(source_card: Node, target: Node, ability: Dictionary) -> void:
	"""Aplica un efecto continuo a un objetivo específico"""
	var effect_type = ability.get("effect_type", "")
	var value = ability.get("value", 0)
	var ability_id = ability.get("id", "")
	var target_id = target.get_instance_id()

	# Crear registro del efecto
	var effect = {
		"source": source_card,
		"target": target,
		"effect_type": effect_type,
		"value": value,
		"ability_id": ability_id
	}

	# Guardar en applied_continuous_effects
	if not applied_continuous_effects.has(target_id):
		applied_continuous_effects[target_id] = []

	applied_continuous_effects[target_id].append(effect)

	# Aplicar modificador a la carta
	if target.has_method("apply_modifier"):
		target.apply_modifier(effect_type, value, ability_id)

	var target_name = target.card_name if target.get("card_name") else str(target)
	print("[CardEffectSystem] Efecto continuo aplicado: %s %+d a %s" % [effect_type, value, target_name])

	emit_signal("continuous_effect_applied", source_card, target, effect)


func _get_continuous_ability_targets(source_card: Node, ability: Dictionary) -> Array:
	"""Obtiene todos los objetivos válidos para una habilidad continua.
	Antes usaba _get_game_board() (siempre null — el GameBoard.gd huérfano)
	y devolvía [] siempre, así que cualquier Oro con habilidad continua
	tipo 'Tus Aliados ganan +X Fuerza' no encontraba ningún objetivo. Usa
	el campo real de Main (un contenedor por jugador)."""
	var targets: Array = []
	var target_type = ability.get("targets", "self")
	var controller_id = source_card.controller_id if source_card.get("controller_id") != null else 0

	if target_type == "self":
		targets.append(source_card)
		return targets

	var main = get_node_or_null("/root/Main")
	if not main:
		return targets

	match target_type:
		"own_allies":
			for card in main.player_field.get_children() if controller_id == 0 else main.opponent_field.get_children():
				if card.get("card_type") == Constants.CardType.ALIADO:
					targets.append(card)

		"enemy_allies":
			var opponent_id = 1 - controller_id
			for card in main.player_field.get_children() if opponent_id == 0 else main.opponent_field.get_children():
				if card.get("card_type") == Constants.CardType.ALIADO:
					targets.append(card)

		"all_allies":
			for field in [main.player_field, main.opponent_field]:
				for card in field.get_children():
					if card.get("card_type") == Constants.CardType.ALIADO:
						targets.append(card)

		"own_cards":
			var field = main.player_field if controller_id == 0 else main.opponent_field
			targets.append_array(field.get_children())

	# Aplicar condición adicional si existe
	if ability.has("condition"):
		var condition: Callable = ability.condition
		if condition.is_valid():
			targets = targets.filter(func(t): return condition.call(t))

	return targets


# =============================================================================
# HABILIDADES DE ORO EN RESERVA
# =============================================================================
func _process_gold_continuous_ability(card: Node, player_id: int) -> void:
	"""Procesa la habilidad continua de un Oro en la Reserva"""
	# Verificar si el Oro tiene habilidad especial
	var ability_text = ""
	if card.get("card_ability"):
		ability_text = card.card_ability.to_lower()

	if ability_text.is_empty():
		return

	var card_id = card.get_instance_id()

	# Ya tiene habilidad registrada y activa?
	if active_continuous_abilities.has(card_id):
		var existing = active_continuous_abilities[card_id]
		for ability_id in existing:
			if existing[ability_id].get("active", false):
				return  # Ya está activo

	# Parsear habilidades continuas del texto
	var parsed_ability = _parse_gold_continuous_ability(ability_text, card)

	if parsed_ability.is_empty():
		return

	# Registrar y activar
	var ability_id = register_continuous_ability(card, parsed_ability)
	await activate_continuous_ability(card, ability_id)


func _parse_gold_continuous_ability(text: String, source: Node) -> Dictionary:
	"""Parsea el texto de un Oro para detectar habilidades continuas
	Ejemplos:
	- "Tus Aliados ganan +1 Fuerza"
	- "Los Aliados rivales tienen -1 Defensa"
	- "Tus cartas cuestan 1 menos"
	"""
	var ability: Dictionary = {}

	# Detectar buff de Fuerza a aliados propios
	if "tus aliados" in text and ("fuerza" in text or "ataque" in text):
		var value = _extract_signed_value(text)
		if value != 0:
			ability = {
				"type": ContinuousAbilityType.BUFF_ALLIES,
				"effect_type": "attack",
				"value": value,
				"targets": "own_allies",
				"zone_required": Constants.Zone.RESERVA_ORO
			}

	# Detectar buff de Defensa a aliados propios
	elif "tus aliados" in text and "defensa" in text:
		var value = _extract_signed_value(text)
		if value != 0:
			ability = {
				"type": ContinuousAbilityType.BUFF_ALLIES,
				"effect_type": "defense",
				"value": value,
				"targets": "own_allies",
				"zone_required": Constants.Zone.RESERVA_ORO
			}

	# Detectar debuff a aliados enemigos
	elif ("aliados rival" in text or "aliados enemig" in text) and "fuerza" in text:
		var value = _extract_signed_value(text)
		if value != 0:
			ability = {
				"type": ContinuousAbilityType.DEBUFF_ENEMIES,
				"effect_type": "attack",
				"value": value,
				"targets": "enemy_allies",
				"zone_required": Constants.Zone.RESERVA_ORO
			}

	# Detectar reducción de coste
	elif "cuesta" in text and "menos" in text:
		var value = _extract_number_from_text(text)
		if value > 0:
			ability = {
				"type": ContinuousAbilityType.COST_REDUCTION,
				"effect_type": "cost",
				"value": -value,  # Negativo porque reduce
				"targets": "own_cards",
				"zone_required": Constants.Zone.RESERVA_ORO
			}

	# Detectar otorgar keyword
	for keyword_name in ["furia", "imbloqueable", "indestructible"]:
		if keyword_name in text and "tus aliados" in text:
			ability = {
				"type": ContinuousAbilityType.KEYWORD_GRANT,
				"effect_type": "keyword",
				"keyword": keyword_name,
				"value": 1,
				"targets": "own_allies",
				"zone_required": Constants.Zone.RESERVA_ORO
			}
			break

	return ability


func _extract_signed_value(text: String) -> int:
	"""Extrae un valor con signo del texto (+1, -2, etc.)"""
	var regex = RegEx.new()
	regex.compile("([+-]\\s*\\d+)")
	var match = regex.search(text)
	if match:
		var val_str = match.get_string(1).replace(" ", "")
		return int(val_str)
	return 0


func _extract_number_from_text(text: String) -> int:
	"""Extrae un número del texto"""
	var regex = RegEx.new()
	regex.compile("(\\d+)")
	var match = regex.search(text)
	if match:
		return int(match.get_string(1))
	return 0


# =============================================================================
# RECALCULAR EFECTOS CONTINUOS
# =============================================================================
func recalculate_all_continuous_effects() -> void:
	"""Recalcula todos los efectos continuos activos
	Llamar cuando cambia el estado del tablero (aliado entra/sale)
	"""
	print("[CardEffectSystem] Recalculando efectos continuos...")

	# Para cada carta con habilidades continuas activas
	for card_id in active_continuous_abilities:
		var abilities = active_continuous_abilities[card_id]

		for ability_id in abilities:
			var ability = abilities[ability_id]

			if not ability.get("active", false):
				continue

			var source = ability.get("source")
			if not is_instance_valid(source):
				continue

			# Remover efectos actuales
			await _remove_continuous_effects(source, ability)

			# Reaplicar a nuevos objetivos
			await _apply_continuous_effects(source, ability)


# =============================================================================
# ACTION PIPELINE (DAR 7.1) — ELIMINADO (2026-08-17): execute_action_pipeline()
# y todo lo que colgaba de ahí (_execute_pipeline_action, _execute_destroy_
# targets, _execute_exile_targets, _execute_damage, _execute_buff,
# _execute_shuffle, parse_ability_to_actions, _split_by_connectors,
# _parse_single_action, is_pipeline_running, get_pipeline_progress) no
# tenía NINGÚN llamador en todo el proyecto — el camino real de ejecución
# de acciones es TriggerSystem → UniversalCardParser → ActionModule.
# =============================================================================
