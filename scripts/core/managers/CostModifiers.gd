extends RefCounted
class_name CostModifiers
## CostModifiers — Alta/baja de modificadores de coste (DAR Sección 6.B).
## Los arrays viven en PaymentManager (_main) porque calcular_coste_real()
## los lee directamente en el hot path de cada carta. Extraído de
## PaymentManager.gd (Fase 4 de reestructuración).

var _main: Node


func setup(main: Node) -> void:
	_main = main


func agregar_modificador_coste(source: Node, modifier: int, condition: Callable = Callable(), allow_zero: bool = false) -> void:
	"""Modifica el COSTE IMPRESO de las cartas que cumplan 'condition'.
	modifier negativo = reduce (piso 1, o 0 si allow_zero=true — usar cuando
	la carta dice explícitamente 'hasta un mínimo de 0'); positivo = aumenta."""
	_main.cost_modifiers.append({
		"source": source,
		"modifier": modifier,
		"condition": condition if condition.is_valid() else null,
		"allow_zero": allow_zero
	})


func remover_modificador_coste(source: Node) -> void:
	_main.cost_modifiers = _main.cost_modifiers.filter(func(m): return m.source != source)


func agregar_oros_menos(source: Node, reduction: int, condition: Callable = Callable()) -> void:
	"""'Jugar por X Oros menos' — descuento sobre el pago, no toca el coste
	impreso. Sin piso propio (puede dejar el pago en 0)."""
	_main.oros_menos_modifiers.append({
		"source": source,
		"reduction": reduction,
		"condition": condition if condition.is_valid() else null
	})


func remover_oros_menos(source: Node) -> void:
	_main.oros_menos_modifiers = _main.oros_menos_modifiers.filter(func(m): return m.source != source)


func agregar_oros_mas(source: Node, increase: int, condition: Callable = Callable()) -> void:
	"""'Cuesta X Oro(s) adicional(es)' para pagar — inverso de oros_menos:
	sube el pago sin tocar el coste impreso de la carta."""
	_main.oros_mas_modifiers.append({
		"source": source,
		"increase": increase,
		"condition": condition if condition.is_valid() else null
	})


func remover_oros_mas(source: Node) -> void:
	_main.oros_mas_modifiers = _main.oros_mas_modifiers.filter(func(m): return m.source != source)
