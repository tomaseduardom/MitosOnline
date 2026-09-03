extends RefCounted
class_name StackItemAnimations
## StackItemAnimations — Animaciones LIFO de entrada/salida/anulación/fizzle
## de los items del StackVisualizer. Opera sobre nodos Control via _main
## (el propio StackVisualizer, para create_tween()/get_tree()) y sobre el
## item recibido como parámetro. Extraído de StackVisualizer.gd (Fase 4).

var _main: Control

const FALL_DISTANCE: float = 100.0      # Distancia de caída
const FALL_DURATION: float = 0.3        # Duración de caída
const FADE_DURATION: float = 0.25       # Duración de desvanecimiento
const PUSH_DOWN_AMOUNT: float = 5.0     # Cuánto se empujan los items inferiores
const RESOLUTION_DELAY: float = 0.4     # Pausa antes de activar siguiente

## Estado de animación
var is_animating: bool = false


func setup(main: Control) -> void:
	_main = main


func animate_item_in(item: Control) -> void:
	"""Anima la entrada LIFO - El item 'cae' desde arriba sobre los demás"""
	if not is_instance_valid(item):
		return

	is_animating = true

	# Estado inicial: arriba y transparente
	item.modulate.a = 0.0
	item.position.y = -FALL_DISTANCE
	item.scale = Vector2(0.8, 0.8)

	# Empujar items existentes hacia abajo (efecto de "peso")
	await _push_existing_items_down()

	# Animación de caída
	var tween = _main.create_tween()
	tween.set_ease(Tween.EASE_OUT)
	tween.set_trans(Tween.TRANS_BOUNCE)

	# Fase 1: Aparecer y caer
	tween.set_parallel(true)
	tween.tween_property(item, "modulate:a", 1.0, FALL_DURATION * 0.5)
	tween.tween_property(item, "position:y", 0.0, FALL_DURATION)
	tween.tween_property(item, "scale", Vector2.ONE, FALL_DURATION * 0.7)

	# Efecto de "impacto" sutil
	tween.chain().tween_property(item, "scale", Vector2(1.02, 0.98), 0.05)
	tween.tween_property(item, "scale", Vector2.ONE, 0.1)

	await tween.finished
	is_animating = false

	# Efecto de brillo al aterrizar
	flash_item(item, Color(1, 1, 1, 0.5))


func _push_existing_items_down() -> void:
	"""Empuja los items existentes ligeramente hacia abajo"""
	var items_to_push = _main._stack_items.values()

	if items_to_push.is_empty():
		return

	var tween = _main.create_tween()
	tween.set_parallel(true)
	tween.set_ease(Tween.EASE_OUT)

	for item in items_to_push:
		if is_instance_valid(item):
			# Pequeño empujón hacia abajo
			var current_y = item.position.y
			tween.tween_property(item, "position:y", current_y + PUSH_DOWN_AMOUNT, 0.1)

	await tween.finished

	# Restaurar posiciones (el VBoxContainer las maneja)
	for item in items_to_push:
		if is_instance_valid(item):
			item.position.y = 0


func animate_item_out(item: Control) -> void:
	"""Anima la salida - El item se desvanece hacia arriba antes del siguiente"""
	if not is_instance_valid(item):
		return

	is_animating = true

	# Resaltar brevemente antes de salir
	await flash_item(item, Color(0.5, 1, 0.5, 0.5))

	var tween = _main.create_tween()
	tween.set_ease(Tween.EASE_IN)
	tween.set_trans(Tween.TRANS_QUAD)

	# Fase 1: Elevarse y desvanecerse
	tween.set_parallel(true)
	tween.tween_property(item, "modulate:a", 0.0, FADE_DURATION)
	tween.tween_property(item, "position:y", -30.0, FADE_DURATION)
	tween.tween_property(item, "scale", Vector2(0.9, 0.9), FADE_DURATION)

	await tween.finished

	# Pausa antes de activar el siguiente (visual de "procesamiento")
	await _main.get_tree().create_timer(RESOLUTION_DELAY).timeout

	is_animating = false


func animate_item_annulled(item: Control) -> void:
	"""Animación especial para anulación - efecto de 'destrucción'"""
	if not is_instance_valid(item):
		return

	is_animating = true

	# Flash rojo
	await flash_item(item, Color.RED)

	var tween = _main.create_tween()

	# Sacudida
	for i in range(3):
		tween.tween_property(item, "position:x", 10.0, 0.03)
		tween.tween_property(item, "position:x", -10.0, 0.03)
	tween.tween_property(item, "position:x", 0.0, 0.03)

	# Colapsar y desvanecer
	tween.set_parallel(true)
	tween.tween_property(item, "scale:y", 0.0, 0.2)
	tween.tween_property(item, "modulate:a", 0.0, 0.2)

	await tween.finished
	is_animating = false


func animate_item_fizzled(item: Control) -> void:
	"""Animación para fizzle - efecto de 'desintegración'"""
	if not is_instance_valid(item):
		return

	is_animating = true

	var tween = _main.create_tween()

	# Parpadeo gris
	tween.tween_property(item, "modulate", Color(0.5, 0.5, 0.5, 1.0), 0.1)
	tween.tween_property(item, "modulate", Color(0.3, 0.3, 0.3, 0.8), 0.1)
	tween.tween_property(item, "modulate", Color(0.5, 0.5, 0.5, 0.5), 0.1)
	tween.tween_property(item, "modulate:a", 0.0, 0.2)

	await tween.finished
	is_animating = false


func flash_item(item: Control, flash_color: Color) -> void:
	"""Efecto de destello en un item"""
	if not is_instance_valid(item):
		return

	var original_modulate = item.modulate

	var tween = _main.create_tween()
	tween.tween_property(item, "modulate", flash_color, 0.05)
	tween.tween_property(item, "modulate", original_modulate, 0.1)

	await tween.finished


func animate_stack_shift_up() -> void:
	"""Anima los items restantes subiendo cuando se remueve el tope"""
	var items = _main._stack_items.values()

	if items.is_empty():
		return

	var tween = _main.create_tween()
	tween.set_parallel(true)
	tween.set_ease(Tween.EASE_OUT)
	tween.set_trans(Tween.TRANS_BACK)

	for item in items:
		if is_instance_valid(item):
			# Pequeño salto hacia arriba
			var current_y = item.position.y
			tween.tween_property(item, "position:y", current_y - 5.0, 0.1)

	await tween.finished

	# El VBoxContainer restaurará las posiciones
