extends RefCounted
class_name RegretSystem
## RegretSystem — Derecho de Arrepentimiento (DAR): permite devolver una
## carta a la mano antes del Paso B (pago de costes) si el jugador cancela
## la selección de objetivo. Opera sobre TargetSelector via _main
## (GameManager). Extraído de TargetSelector.gd (Fase 4 de reestructuración).

var _main: Node

var _can_regret: bool = false           # Si el jugador puede arrepentirse
var _regret_card: Dictionary = {}       # Carta que se puede devolver
var _regret_player_id: int = -1         # Jugador que puede arrepentirse


func setup(main: Node) -> void:
	_main = main


func _enable_regret(card_data: Dictionary) -> void:
	"""Habilita el derecho de arrepentimiento para una carta"""
	_can_regret = true
	_regret_card = card_data.duplicate(true)
	_regret_player_id = card_data.get("controller_id", card_data.get("player_id", 0))

	print("[TargetSelector] Arrepentimiento habilitado para '%s'" %
		  card_data.get("nombre", card_data.get("name", "???")))


func _disable_regret() -> void:
	"""Deshabilita el derecho de arrepentimiento"""
	_can_regret = false
	_regret_card = {}
	_regret_player_id = -1


func can_regret() -> bool:
	"""Retorna si el jugador puede ejercer arrepentimiento"""
	return _can_regret


func get_regret_card() -> Dictionary:
	"""Retorna la carta que se puede devolver por arrepentimiento"""
	return _regret_card


func get_regret_player_id() -> int:
	"""Retorna el ID del jugador que puede ejercer arrepentimiento"""
	return _regret_player_id


func _return_card_to_hand(card_data: Dictionary, player_id: int) -> void:
	"""Devuelve una carta a la mano del jugador

	Esta función debe integrarse con el sistema de manos del juego.
	"""
	# (2026-08-28, "módulos gordos" punto 1): GameManager es autoload, así
	# que la búsqueda en sí nunca fallaba — el problema real es que
	# return_card_to_hand()/add_card_to_hand() no existen ni existieron
	# nunca en GameManager.gd, esto cae siempre acá. Función sin terminar,
	# no algo que este punto de la limpieza deba resolver.
	print("[TargetSelector] WARN: No se pudo devolver carta a mano - GameManager no implementa return_card_to_hand/add_card_to_hand")
	# La señal card_returned_to_hand ya fue emitida


func notify_step_b_started() -> void:
	"""Notifica que el Paso B (pago) ha comenzado - ya no se puede arrepentir"""
	if _can_regret:
		print("[TargetSelector] Paso B iniciado - arrepentimiento ya no disponible")
		_disable_regret()
