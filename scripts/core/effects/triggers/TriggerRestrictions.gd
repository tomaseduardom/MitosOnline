extends RefCounted
class_name TriggerRestrictions
## TriggerRestrictions — Registro de efectos continuos negativos que bloquean
## triggers o acciones específicas (DAR: la restricción siempre gana).
## Opera sobre TriggerSystem via _main (solo para print de contexto).
## Extraído de TriggerSystem.gd (Fase 4 de reestructuración).

var _main: Node

## Efectos continuos activos (para resolver conflictos de prioridad)
var continuous_effects: Array[Dictionary] = []


func setup(main: Node) -> void:
	_main = main


func register_continuous_effect(source_card: Node, effect: Dictionary) -> void:
	"""Registra un efecto continuo activo
	effect debe contener:
	- type: String (ej: "prevent_draw", "prevent_damage", "block_triggers")
	- is_negative: bool (las restricciones son negativas y ganan conflictos)
	- condition: Callable opcional para verificar si aplica
	- targets: Array de tipos de carta o "all"
	"""
	effect["source"] = source_card
	effect["id"] = "%s_%d" % [source_card.get_instance_id(), Time.get_ticks_msec()]
	continuous_effects.append(effect)
	print("[TriggerSystem] Efecto continuo registrado: %s de %s" % [effect.type, source_card.card_name])


func unregister_continuous_effect(source_card: Node) -> void:
	"""Elimina todos los efectos continuos de una carta"""
	continuous_effects = continuous_effects.filter(func(e): return e.source != source_card)


func is_blocked_by_continuous_effect(card: Node, trigger_type: String) -> bool:
	"""Verifica si un trigger está bloqueado por un efecto continuo negativo
	DAR: El efecto negativo (restricción) siempre gana
	"""
	for effect in continuous_effects:
		if not effect.get("is_negative", false):
			continue

		if effect.type == "block_triggers":
			# Verificar si bloquea este tipo de trigger
			var blocked_types = effect.get("blocked_triggers", [])
			if trigger_type in blocked_types or "all" in blocked_types:
				# Verificar condición si existe
				if effect.has("condition"):
					var condition: Callable = effect.condition
					if condition.is_valid() and condition.call(card):
						return true
				else:
					return true

		if effect.type == "block_card":
			# Bloquea triggers de una carta específica
			var target_card = effect.get("target_card")
			if target_card == card:
				return true

	return false


func get_active_continuous_effects(filter_type: String = "") -> Array:
	"""Retorna efectos continuos activos, opcionalmente filtrados por tipo"""
	if filter_type.is_empty():
		return continuous_effects.duplicate()

	return continuous_effects.filter(func(e): return e.type == filter_type)


func check_continuous_prevention(action_type: String, target: Node = null) -> Dictionary:
	"""Verifica si una acción está prevenida por efectos continuos
	Retorna: {prevented: bool, by: Node, effect: Dictionary}
	"""
	for effect in continuous_effects:
		if effect.type != action_type:
			continue

		if effect.get("is_negative", false):
			# Verificar si aplica al target
			var applies = true
			if target and effect.has("condition"):
				var condition: Callable = effect.condition
				applies = condition.is_valid() and condition.call(target)

			if applies:
				return {
					"prevented": true,
					"by": effect.source,
					"effect": effect
				}

	return {"prevented": false, "by": null, "effect": {}}
