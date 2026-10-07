extends RefCounted
class_name CardTriggerRuntime
## CardTriggerRuntime — Sistema de triggers de una carta (DAR 7.2, 7.3, 7.4):
## parseo de triggers desde el texto de habilidad, verificación de
## condiciones, ejecución de efectos vía Callable, y los hooks de
## entrar/salir de juego. Opera sobre el nodo Card via _card. Card.gd
## reenvía como wrappers públicos los métodos que otros sistemas llaman
## directamente sobre la carta (parse_triggers_from_ability, is_in_play,
## has_trigger, _trigger_conditions_met, _on_trigger_event, on_entered_play,
## on_left_play — TriggerSystem/ActionModule/ConvertAndMiscResolver los
## llaman así en varios puntos).
## Extraído de Card.gd (2026-09-06, "módulos gordos" — mismo corte que ya
## separó CardInteraction.gd/CardAnimations.gd, Fase 4 de reestructuración).
## Nota: Card.TRIGGER_KEYWORDS queda en Card.gd (no aquí) porque se accede de
## forma ESTÁTICA vía la clase (Card.TRIGGER_KEYWORDS[...] en
## TriggerResolution.gd) — moverlo rompería ese acceso estático.

var _card: Card

## Triggers parseados del texto de habilidad
var triggers: Array[Dictionary] = []

## Handlers de efectos personalizados por tipo de trigger
var effect_handlers: Dictionary = {}

var _triggers_connected: bool = false


func setup(card: Card) -> void:
	_card = card


func _connect_trigger_listeners() -> void:
	"""Inicializa el sistema de triggers de la carta
	Nota: TriggerSystem maneja la recolección global de eventos (DAR 7.4)
	La carta solo expone has_trigger() y _trigger_conditions_met()
	"""
	_triggers_connected = true


func parse_triggers_from_ability() -> void:
	"""Parsea el texto de habilidad para extraer triggers"""
	triggers.clear()

	if _card.card_ability.is_empty():
		return

	var ability_lower = _card.card_ability.to_lower()

	for trigger_type in Card.TRIGGER_KEYWORDS:
		var keywords: Array = Card.TRIGGER_KEYWORDS[trigger_type]
		for keyword in keywords:
			if ability_lower.contains(keyword):
				triggers.append({
					"type": trigger_type,
					"keyword": keyword,
					"ability_text": _card.card_ability
				})
				# Solo un trigger por tipo
				break
	# Nota (2026-08-27): los Talismanes NO se resuelven por aquí — no
	# "disparan" nada (DAR Sección 7.4 es para habilidades disparadas de
	# permanentes). Su texto se resuelve directo al jugarlos, ver
	# TriggerSystem.resolve_talisman() / GoldManager._trigger_enter_play().


func is_in_play() -> bool:
	"""Verifica si la carta está en una zona de juego"""
	return _card.current_zone in Constants.ZONES_IN_PLAY


func has_trigger(trigger_type: String) -> bool:
	"""Verifica si la carta tiene un trigger específico"""
	for trigger in triggers:
		if trigger.type == trigger_type:
			return true
	return false


func _check_and_activate_trigger(trigger_type: String, event_data: Dictionary) -> void:
	"""Verifica si el trigger aplica y lo registra con TriggerSystem"""
	# Solo activar si está en juego
	if not is_in_play():
		return

	# Verificar si tiene el trigger
	if not has_trigger(trigger_type):
		return

	# Verificar condiciones adicionales (ej: "tu" vs "oponente")
	if not _trigger_conditions_met(trigger_type, event_data):
		return

	print("[Card] Trigger detectado: %s en %s" % [trigger_type, _card.card_name])

	# Registrar con TriggerSystem para gestión de cola (DAR 7.4)
	TriggerSystem.register_trigger(_card, trigger_type, event_data)

	# También emitir señal local para conexiones directas
	_card.emit_signal("trigger_activated", _card, trigger_type, event_data)


func _trigger_conditions_met(trigger_type: String, event_data: Dictionary) -> bool:
	"""Verifica condiciones adicionales del trigger"""
	var ability_lower = _card.card_ability.to_lower()

	# Verificar si es "tu" o del "oponente"
	var event_player = event_data.get("player_id", -1)

	if ability_lower.contains("cuando tú") or ability_lower.contains("cuando robes"):
		# Solo se activa si es nuestro evento
		if event_player != _card.controller_id:
			return false

	if ability_lower.contains("cuando tu oponente") or ability_lower.contains("cuando el oponente"):
		# Solo se activa si es evento del oponente
		if event_player == _card.controller_id:
			return false

	# Verificar "otro aliado" (no esta carta)
	if trigger_type == "on_ally_enters" or trigger_type == "on_ally_dies":
		var event_card = event_data.get("card", null)
		if event_card == _card:
			return false

	return true


func register_effect_handler(trigger_type: String, handler: Callable) -> void:
	"""Registra un handler personalizado para un tipo de trigger
	Permite definir efectos específicos por carta
	"""
	effect_handlers[trigger_type] = handler


func _on_trigger_event(trigger_type: String, event_data: Dictionary) -> Dictionary:
	"""Handler principal llamado por TriggerSystem cuando se resuelve un trigger
	Usa Callable para ejecutar el efecto específico de la carta
	Resuelve 'en medida de lo posible' (DAR Sección 8)
	"""
	var result = {
		"success": true,
		"partial": false,
		"effects_applied": []
	}

	# Buscar handler específico registrado
	if effect_handlers.has(trigger_type):
		var handler: Callable = effect_handlers[trigger_type]
		if handler.is_valid():
			var handler_result = await handler.call(event_data)
			if handler_result is Dictionary:
				result.merge(handler_result, true)
			return result

	# Sin handler específico registrado (2026-08-22): NO usar
	# _resolve_default_effect() aquí — es un escaneo de palabras clave sobre
	# el texto COMPLETO de la carta (sin aislar por oración), así que una
	# carta con VARIAS habilidades en el mismo bloque (p.ej. Tyet: 'Cuando
	# entra en juego, busca un Arma o un Oro...' + más adelante 'Robar dos
	# cartas' de una habilidad de Oro completamente distinta) disparaba la
	# frase equivocada — Tyet buscaba nada y robaba una carta en su lugar.
	# TriggerSystem._execute_trigger_effect() ya tiene el parser bueno
	# (aísla la oración correcta, reconoce SEARCH/DESTROY/BUFF/etc., no solo
	# 'roba') y lo corre él mismo cuando este resultado no aplicó nada.
	result["no_handler"] = true
	return result


func on_entered_play() -> void:
	"""Llamado cuando la carta entra al juego
	Vincula la carta al TriggerSystem con Callable
	"""
	# Parsear triggers de la habilidad
	parse_triggers_from_ability()

	# Registrar con TriggerSystem
	TriggerSystem.bind_card_to_triggers(_card)

	print("[Card] %s entró al juego con %d triggers" % [_card.card_name, triggers.size()])


func on_left_play() -> void:
	"""Llamado cuando la carta deja el juego
	Limpia efectos continuos y handlers
	"""
	# Desregistrar efectos continuos
	TriggerSystem.unregister_continuous_effect(_card)

	effect_handlers.clear()
	# 2026-09-23, a pedido del usuario: este mensaje solo duplicaba lo que ya
	# informa EffectController ("X fue destruida"/"X resuelve su efecto y va
	# al Cementerio") — 3 líneas distintas para el mismo evento de salida de
	# juego. Se mantiene gateado para depuración profunda.
	if Constants.VERBOSE_DIAG_LOGS:
		print("[Card] %s dejó el juego" % _card.card_name)
