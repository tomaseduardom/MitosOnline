extends RefCounted
class_name StackTargetHighlight
## StackTargetHighlight — Resaltado de objetivos válidos/inválidos (usado por
## TargetSelector via los wrappers públicos de StackVisualizer) y tooltip de
## hover de los items. Opera sobre el StackVisualizer via _main.
## Extraído de StackVisualizer.gd (Fase 4 de reestructuración).

var _main: Control

var _highlight_tweens: Dictionary = {}  # {stack_id: Tween}
var is_target_selection_mode: bool = false
var _hover_tooltip: Control = null


func setup(main: Control) -> void:
	_main = main


# =============================================================================
# HOVER TOOLTIP
# =============================================================================
func on_item_mouse_entered(stack_id: int) -> void:
	"""Cuando el mouse entra en un item - hover effect"""
	_main.emit_signal("stack_item_hovered", stack_id, true)

	if _main._stack_items.has(stack_id):
		var item = _main._stack_items[stack_id]
		if is_instance_valid(item):
			var tween = _main.create_tween()
			tween.set_ease(Tween.EASE_OUT)
			tween.tween_property(item, "scale", Vector2(1.03, 1.03), 0.1)

			# Mostrar tooltip breve
			_show_hover_tooltip(item, stack_id)


func on_item_mouse_exited(stack_id: int) -> void:
	"""Cuando el mouse sale de un item"""
	_main.emit_signal("stack_item_hovered", stack_id, false)

	if _main._stack_items.has(stack_id):
		var item = _main._stack_items[stack_id]
		if is_instance_valid(item):
			var tween = _main.create_tween()
			tween.tween_property(item, "scale", Vector2.ONE, 0.1)

			_hide_hover_tooltip()


func _show_hover_tooltip(item: Control, stack_id: int) -> void:
	"""Muestra tooltip al hacer hover"""
	var stack_obj = _main._get_stack_object_by_id(stack_id)
	if stack_obj.is_empty():
		return

	# Crear tooltip si no existe
	if _hover_tooltip == null:
		_hover_tooltip = PanelContainer.new()
		_hover_tooltip.name = "HoverTooltip"

		var tooltip_style = StyleBoxFlat.new()
		tooltip_style.bg_color = Color(0.1, 0.1, 0.1, 0.95)
		tooltip_style.corner_radius_top_left = 4
		tooltip_style.corner_radius_top_right = 4
		tooltip_style.corner_radius_bottom_left = 4
		tooltip_style.corner_radius_bottom_right = 4
		_hover_tooltip.add_theme_stylebox_override("panel", tooltip_style)

		var label = Label.new()
		label.name = "TooltipLabel"
		label.add_theme_font_size_override("font_size", 10)
		_hover_tooltip.add_child(label)

		_main.add_child(_hover_tooltip)

	# Actualizar contenido
	var label = _hover_tooltip.get_node_or_null("TooltipLabel")
	if label:
		var tip = "Click derecho: Opciones\n"
		if _main._can_be_annulled(stack_obj):
			tip += "• Puede ser anulado"
		elif _main._can_be_cancelled(stack_obj):
			tip += "• Puede ser cancelado"
		else:
			tip += "• Sin acciones disponibles"
		label.text = tip

	# Posicionar
	_hover_tooltip.position = item.global_position + Vector2(item.size.x + 10, 0)
	_hover_tooltip.visible = true


func _hide_hover_tooltip() -> void:
	"""Oculta el tooltip de hover"""
	if _hover_tooltip:
		_hover_tooltip.visible = false


# =============================================================================
# INTEGRACIÓN CON TARGETSELECTOR - Resaltado de objetivos válidos
# =============================================================================
func highlight_target(stack_id: int, color: Color, is_valid: bool) -> void:
	"""Resalta un item como objetivo válido/inválido para selección"""
	if not _main._stack_items.has(stack_id):
		return

	var item = _main._stack_items[stack_id]
	if not is_instance_valid(item):
		return

	# Cancelar tween anterior si existe
	if _highlight_tweens.has(stack_id):
		var old_tween = _highlight_tweens[stack_id]
		if old_tween and old_tween.is_valid():
			old_tween.kill()

	var style = item.get_theme_stylebox("panel") as StyleBoxFlat
	if not style:
		return

	if is_valid:
		# Objetivo válido: borde brillante + animación de pulso
		style.border_color = color
		style.border_width_left = 4
		style.border_width_right = 4
		style.border_width_top = 4
		style.border_width_bottom = 4

		# Pulso continuo
		var tween = _main.create_tween()
		tween.set_loops()
		tween.tween_property(item, "modulate", Color(1.3, 1.3, 1.1), 0.4)
		tween.tween_property(item, "modulate", Color.WHITE, 0.4)
		_highlight_tweens[stack_id] = tween

		# Añadir indicador visual
		_show_target_indicator(item, true)
	else:
		# Objetivo inválido: atenuado
		style.border_color = Color(0.4, 0.4, 0.4, 0.5)
		style.border_width_left = 1
		style.border_width_right = 1
		style.border_width_top = 1
		style.border_width_bottom = 1
		item.modulate = Color(0.5, 0.5, 0.5, 0.6)

		_show_target_indicator(item, false)

	is_target_selection_mode = true


func clear_all_highlights() -> void:
	"""Limpia todos los resaltados de selección de objetivo"""
	# Detener todos los tweens
	for stack_id in _highlight_tweens:
		var tween = _highlight_tweens[stack_id]
		if tween and tween.is_valid():
			tween.kill()
	_highlight_tweens.clear()

	# Restaurar estilos de todos los items
	for stack_id in _main._stack_items:
		var item = _main._stack_items[stack_id]
		if not is_instance_valid(item):
			continue

		# Restaurar modulate
		item.modulate = Color.WHITE

		# Restaurar borde
		var style = item.get_theme_stylebox("panel") as StyleBoxFlat
		if style:
			style.border_color = Color(1, 1, 1, 0.3)
			style.border_width_left = 2
			style.border_width_right = 2
			style.border_width_top = 2
			style.border_width_bottom = 2

		# Ocultar indicador
		_hide_target_indicator(item)

	is_target_selection_mode = false


func _show_target_indicator(item: Control, is_valid: bool) -> void:
	"""Muestra indicador de que el item es un objetivo seleccionable"""
	var indicator = item.find_child("TargetIndicator", true, false)

	if not indicator:
		# Crear indicador si no existe
		indicator = Label.new()
		indicator.name = "TargetIndicator"
		indicator.add_theme_font_size_override("font_size", 14)
		indicator.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

		var content = item.find_child("Content", true, false)
		if content:
			content.add_child(indicator)
			content.move_child(indicator, 0)

	indicator.visible = true
	if is_valid:
		indicator.text = "[OBJETIVO]"
		indicator.add_theme_color_override("font_color", Color.GREEN)
	else:
		indicator.text = "[BLOQUEADO]"
		indicator.add_theme_color_override("font_color", Color.RED)


func _hide_target_indicator(item: Control) -> void:
	"""Oculta el indicador de objetivo"""
	var indicator = item.find_child("TargetIndicator", true, false)
	if indicator:
		indicator.visible = false
