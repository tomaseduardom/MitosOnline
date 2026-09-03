extends Control
## StackVisualizer - Visualizador de la Pila de Efectos (DAR Sección 6)
## Muestra la jerarquía de cartas y habilidades en la pila
##
## Sincronizado con ActionPipeline para mostrar en tiempo real:
## - Cartas siendo jugadas
## - Habilidades disparadas (con fuente y descripción)
## - Estado de cada objeto (esperando, resolviendo, resuelto)

# =============================================================================
# SEÑALES
# =============================================================================
signal stack_item_clicked(stack_id: int)
signal stack_item_hovered(stack_id: int, is_hovered: bool)
signal visualizer_toggled(is_visible: bool)

# =============================================================================
# REFERENCIAS A NODOS UI
# =============================================================================
@onready var stack_container: VBoxContainer = $StackContainer
@onready var header_label: Label = $Header/Label
@onready var empty_label: Label = $EmptyLabel
@onready var background_panel: Panel = $BackgroundPanel

# =============================================================================
# ESCENA DE ITEM DE PILA (se instancia por cada objeto)
# =============================================================================
var StackItemScene: PackedScene = null

# =============================================================================
# ESTADO
# =============================================================================
var _stack_items: Dictionary = {}  # {stack_id: StackItemNode}
var _action_pipeline: Node = null
var _is_expanded: bool = true

# =============================================================================
# CONFIGURACIÓN VISUAL
# =============================================================================
const ITEM_HEIGHT: int = 80
const ITEM_SPACING: int = 8
const MAX_VISIBLE_ITEMS: int = 6
const ANIMATION_DURATION: float = 0.2

## Tipos de objeto en pila (espejo de ActionPipeline.StackObjectType)
enum StackObjectType {
	CARD_PLAYED = 0,
	TRIGGERED_ABILITY = 1,
	ACTIVATED_ABILITY = 2,
	RESPONSE_CARD = 3
}

## Colores por tipo de objeto
const TYPE_COLORS: Dictionary = {
	0: Color(0.2, 0.6, 0.9, 0.9),   # CARD_PLAYED - Azul
	1: Color(0.9, 0.7, 0.2, 0.9),   # TRIGGERED_ABILITY - Dorado
	2: Color(0.5, 0.9, 0.5, 0.9),   # ACTIVATED_ABILITY - Verde
	3: Color(0.9, 0.3, 0.3, 0.9),   # RESPONSE_CARD - Rojo
}

## Colores por estado
const STEP_COLORS: Dictionary = {
	4: Color(0.5, 0.5, 0.5, 0.8),   # ON_STACK - Gris
	5: Color(1.0, 0.8, 0.2, 1.0),   # STEP_D - Amarillo (esperando)
	6: Color(0.3, 1.0, 0.3, 1.0),   # STEP_E - Verde (resolviendo)
	7: Color(0.2, 0.8, 0.2, 0.5),   # RESOLVED - Verde tenue
	8: Color(0.8, 0.2, 0.2, 0.5),   # ANNULLED - Rojo tenue
	9: Color(0.6, 0.6, 0.6, 0.5),   # FIZZLED - Gris tenue
}


func _ready() -> void:
	# Ocultar label de vacío inicialmente
	if empty_label:
		empty_label.visible = true

	call_deferred("_connect_to_pipeline")
	call_deferred("_setup_ui")

	print("[StackVisualizer] Inicializado")


func _setup_ui() -> void:
	"""Configura la UI inicial"""
	if header_label:
		header_label.text = "PILA DE EFECTOS"

	# Crear escena de item dinámicamente si no existe
	if StackItemScene == null:
		_create_stack_item_scene()


func _connect_to_pipeline() -> void:
	"""Conecta las señales del ActionPipeline"""
	_action_pipeline = get_node_or_null("/root/ActionPipeline")

	if not _action_pipeline:
		push_warning("[StackVisualizer] ActionPipeline no encontrado")
		return

	# Señales de objetos en la pila
	if _action_pipeline.has_signal("stack_object_added"):
		_action_pipeline.stack_object_added.connect(_on_stack_object_added)

	if _action_pipeline.has_signal("stack_object_resolving"):
		_action_pipeline.stack_object_resolving.connect(_on_stack_object_resolving)

	if _action_pipeline.has_signal("stack_object_resolved"):
		_action_pipeline.stack_object_resolved.connect(_on_stack_object_resolved)

	if _action_pipeline.has_signal("stack_object_removed"):
		_action_pipeline.stack_object_removed.connect(_on_stack_object_removed)

	# Señales de pasos
	if _action_pipeline.has_signal("step_d_waiting"):
		_action_pipeline.step_d_waiting.connect(_on_step_d_waiting)

	if _action_pipeline.has_signal("step_d_completed"):
		_action_pipeline.step_d_completed.connect(_on_step_d_completed)

	# Señales de anulación/cancelación
	if _action_pipeline.has_signal("object_annulled"):
		_action_pipeline.object_annulled.connect(_on_object_annulled)

	if _action_pipeline.has_signal("object_cancelled"):
		_action_pipeline.object_cancelled.connect(_on_object_cancelled)

	if _action_pipeline.has_signal("object_fizzled"):
		_action_pipeline.object_fizzled.connect(_on_object_fizzled)

	# Señales de pila
	if _action_pipeline.has_signal("stack_empty"):
		_action_pipeline.stack_empty.connect(_on_stack_empty)

	if _action_pipeline.has_signal("pipeline_started"):
		_action_pipeline.pipeline_started.connect(_on_pipeline_started)

	print("[StackVisualizer] Conectado a ActionPipeline")


# =============================================================================
# CALLBACKS DE ACTIONPIPELINE
# =============================================================================
func _on_stack_object_added(stack_obj: Dictionary) -> void:
	"""Cuando se añade un objeto a la pila"""
	_add_stack_item(stack_obj)
	_update_empty_state()
	_reorder_items()


func _on_stack_object_resolving(stack_obj: Dictionary) -> void:
	"""Cuando un objeto comienza a resolver"""
	var stack_id = stack_obj.get("id", -1)
	if _stack_items.has(stack_id):
		_update_item_state(_stack_items[stack_id], stack_obj, "resolving")


func _on_stack_object_resolved(stack_obj: Dictionary, _result: Dictionary) -> void:
	"""Cuando un objeto termina de resolver"""
	var stack_id = stack_obj.get("id", -1)
	if _stack_items.has(stack_id):
		_update_item_state(_stack_items[stack_id], stack_obj, "resolved")
		# Animar salida
		await _animate_item_out(_stack_items[stack_id])


func _on_stack_object_removed(stack_obj: Dictionary, reason: String) -> void:
	"""Cuando un objeto es removido de la pila"""
	var stack_id = stack_obj.get("id", -1)
	_remove_stack_item(stack_id, reason)
	_update_empty_state()
	_reorder_items()


func _on_step_d_waiting(stack_obj: Dictionary, priority_player: int) -> void:
	"""Cuando un objeto está esperando respuesta (Paso D)"""
	var stack_id = stack_obj.get("id", -1)
	if _stack_items.has(stack_id):
		var item = _stack_items[stack_id]
		_update_item_state(item, stack_obj, "waiting")
		_highlight_item(item, true)
		_update_waiting_indicator(item, priority_player)


func _on_step_d_completed(stack_obj: Dictionary, had_response: bool) -> void:
	"""Cuando termina el Paso D de un objeto"""
	var stack_id = stack_obj.get("id", -1)
	if _stack_items.has(stack_id):
		var item = _stack_items[stack_id]
		_highlight_item(item, false)
		if had_response:
			_show_response_indicator(item)


func _on_object_annulled(stack_obj: Dictionary, annuller: Dictionary) -> void:
	"""Cuando un objeto es anulado - Animación de destrucción"""
	var stack_id = stack_obj.get("id", -1)
	if _stack_items.has(stack_id):
		var item = _stack_items[stack_id]
		_update_item_state(item, stack_obj, "annulled")
		_show_annulled_effect(item, annuller)
		# Animación de anulación (sacudida + colapso)
		await _animate_item_annulled(item)


func _on_object_cancelled(stack_obj: Dictionary) -> void:
	"""Cuando un objeto es cancelado"""
	var stack_id = stack_obj.get("id", -1)
	if _stack_items.has(stack_id):
		var item = _stack_items[stack_id]
		_update_item_state(item, stack_obj, "cancelled")
		# Usar animación de anulación (similar visual)
		await _animate_item_annulled(item)


func _on_object_fizzled(stack_obj: Dictionary) -> void:
	"""Cuando un objeto hace fizzle"""
	var stack_id = stack_obj.get("id", -1)
	if _stack_items.has(stack_id):
		var item = _stack_items[stack_id]
		_update_item_state(item, stack_obj, "fizzled")
		# Usar animación de desintegración
		await _animate_item_fizzled(item)


func _on_stack_empty() -> void:
	"""Cuando la pila queda vacía"""
	_clear_all_items()
	_update_empty_state()


func _on_pipeline_started() -> void:
	"""Cuando inicia el pipeline"""
	if empty_label:
		empty_label.visible = false


# =============================================================================
# GESTIÓN DE ITEMS DE PILA
# =============================================================================
func _add_stack_item(stack_obj: Dictionary) -> void:
	"""Añade un item visual para un objeto de la pila"""
	var stack_id = stack_obj.get("id", -1)

	if _stack_items.has(stack_id):
		return  # Ya existe

	var item = _create_stack_item_node(stack_obj)
	if item == null:
		return

	_stack_items[stack_id] = item

	if stack_container:
		stack_container.add_child(item)
		# Insertar al inicio (tope de la pila = arriba visualmente)
		stack_container.move_child(item, 0)

	# Animar entrada
	_animate_item_in(item)

	print("[StackVisualizer] + Añadido: %s (#%d)" % [stack_obj.get("name", "???"), stack_id])


func _remove_stack_item(stack_id: int, reason: String) -> void:
	"""Remueve un item visual"""
	if not _stack_items.has(stack_id):
		return

	var item = _stack_items[stack_id]
	_stack_items.erase(stack_id)

	if is_instance_valid(item):
		item.queue_free()

	print("[StackVisualizer] - Removido: #%d (%s)" % [stack_id, reason])


func _clear_all_items() -> void:
	"""Limpia todos los items"""
	for stack_id in _stack_items.keys():
		var item = _stack_items[stack_id]
		if is_instance_valid(item):
			item.queue_free()

	_stack_items.clear()


func _reorder_items() -> void:
	"""Reordena los items para reflejar el orden de la pila"""
	if not stack_container or not _action_pipeline:
		return

	var stack = _action_pipeline.get_stack()

	# Reordenar: tope de la pila = primer hijo (arriba)
	for i in range(stack.size() - 1, -1, -1):
		var obj = stack[i]
		var stack_id = obj.get("id", -1)
		if _stack_items.has(stack_id):
			var item = _stack_items[stack_id]
			stack_container.move_child(item, 0)


# =============================================================================
# CREACIÓN DE NODOS DE ITEM
# =============================================================================
func _create_stack_item_scene() -> void:
	"""Crea la escena de item programáticamente"""
	# En producción, esto sería una escena .tscn
	pass


func _create_stack_item_node(stack_obj: Dictionary) -> Control:
	"""Crea un nodo de item para un objeto de la pila"""
	var item = PanelContainer.new()
	item.name = "StackItem_%d" % stack_obj.get("id", 0)
	item.custom_minimum_size = Vector2(280, ITEM_HEIGHT)

	# Guardar datos en metadata
	item.set_meta("stack_id", stack_obj.get("id", -1))
	item.set_meta("stack_obj", stack_obj)

	# Panel de fondo con color según tipo
	var style = StyleBoxFlat.new()
	var type_idx = stack_obj.get("type", 0)
	style.bg_color = TYPE_COLORS.get(type_idx, Color(0.3, 0.3, 0.3, 0.9))
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.border_color = Color(1, 1, 1, 0.3)
	item.add_theme_stylebox_override("panel", style)

	# Contenedor vertical
	var vbox = VBoxContainer.new()
	vbox.name = "Content"
	vbox.add_theme_constant_override("separation", 4)
	item.add_child(vbox)

	# Margen interno
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	vbox.add_child(margin)

	var inner_vbox = VBoxContainer.new()
	inner_vbox.add_theme_constant_override("separation", 4)
	margin.add_child(inner_vbox)

	# Header: Tipo + Nombre
	var header_hbox = HBoxContainer.new()
	header_hbox.add_theme_constant_override("separation", 8)
	inner_vbox.add_child(header_hbox)

	# Icono de tipo
	var type_label = Label.new()
	type_label.name = "TypeIcon"
	type_label.text = _get_type_icon(stack_obj.get("type", 0))
	type_label.add_theme_font_size_override("font_size", 16)
	header_hbox.add_child(type_label)

	# Nombre
	var name_label = Label.new()
	name_label.name = "NameLabel"
	name_label.text = stack_obj.get("name", "???")
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.add_theme_color_override("font_color", Color.WHITE)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	header_hbox.add_child(name_label)

	# Estado
	var state_label = Label.new()
	state_label.name = "StateLabel"
	state_label.text = _get_state_text(stack_obj.get("step", 4))
	state_label.add_theme_font_size_override("font_size", 10)
	state_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 0.8))
	header_hbox.add_child(state_label)

	# Descripción del efecto
	var desc_label = Label.new()
	desc_label.name = "DescLabel"
	desc_label.text = _get_effect_description(stack_obj)
	desc_label.add_theme_font_size_override("font_size", 11)
	desc_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9, 0.9))
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_label.clip_text = true
	desc_label.custom_minimum_size.y = 20
	inner_vbox.add_child(desc_label)

	# Fuente (para habilidades disparadas)
	if stack_obj.get("type", 0) in [1, 2]:  # TRIGGERED o ACTIVATED
		var source_label = Label.new()
		source_label.name = "SourceLabel"
		var source_name = stack_obj.context.get("source_name", "")
		if not source_name.is_empty():
			source_label.text = "← %s" % source_name
			source_label.add_theme_font_size_override("font_size", 10)
			source_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, 0.8))
			inner_vbox.add_child(source_label)

	# Indicador de espera (oculto por defecto)
	var wait_indicator = Label.new()
	wait_indicator.name = "WaitIndicator"
	wait_indicator.text = ""
	wait_indicator.visible = false
	wait_indicator.add_theme_font_size_override("font_size", 10)
	wait_indicator.add_theme_color_override("font_color", Color.YELLOW)
	inner_vbox.add_child(wait_indicator)

	# Conectar señales de interacción
	item.gui_input.connect(_on_item_gui_input.bind(stack_obj.get("id", -1)))
	item.mouse_entered.connect(_on_item_mouse_entered.bind(stack_obj.get("id", -1)))
	item.mouse_exited.connect(_on_item_mouse_exited.bind(stack_obj.get("id", -1)))

	return item


func _get_type_icon(type: int) -> String:
	"""Retorna icono según tipo de objeto"""
	match type:
		0: return "🃏"  # CARD_PLAYED
		1: return "⚡"  # TRIGGERED_ABILITY
		2: return "🎯"  # ACTIVATED_ABILITY
		3: return "🛡️"  # RESPONSE_CARD
		_: return "❓"


func _get_state_text(step: int) -> String:
	"""Retorna texto de estado"""
	match step:
		4: return "En pila"
		5: return "Esperando..."
		6: return "Resolviendo"
		7: return "✓ Resuelto"
		8: return "✗ Anulado"
		9: return "✗ Fizzled"
		_: return ""


func _get_effect_description(stack_obj: Dictionary) -> String:
	"""Genera descripción breve del efecto"""
	var card_data = stack_obj.get("card_data", {})
	var obj_type = stack_obj.get("type", 0)

	# Para cartas, mostrar tipo
	if obj_type == 0 or obj_type == 3:  # CARD_PLAYED o RESPONSE
		var card_type = card_data.get("tipo", -1)
		match card_type:
			0: return "Poner Oro en Reserva"
			1: return "Entra a Línea de Defensa"
			2: return "Portar en Aliado"
			3: return "Resolver efecto"
			4: return "Entra a Línea de Apoyo"
			_: return "Resolver carta"

	# Para habilidades, buscar descripción
	if obj_type == 1 or obj_type == 2:  # TRIGGERED o ACTIVATED
		var ability_text = card_data.get("description", "")
		if ability_text.is_empty():
			ability_text = card_data.get("effect_text", "")
		if ability_text.is_empty():
			# Intentar extraer de ability_blocks
			var blocks = card_data.get("effect", [])
			if not blocks.is_empty():
				var first_effect = blocks[0] if blocks[0] is Dictionary else {}
				var effect_type = first_effect.get("type", "")
				ability_text = _effect_type_to_text(effect_type)

		if ability_text.is_empty():
			ability_text = "Habilidad disparada"

		# Truncar si es muy largo
		if ability_text.length() > 50:
			ability_text = ability_text.substr(0, 47) + "..."

		return ability_text

	return "Efecto"


func _effect_type_to_text(effect_type: String) -> String:
	"""Convierte tipo de efecto a texto legible"""
	match effect_type.to_upper():
		"DRAW": return "Robar cartas"
		"DAMAGE": return "Infligir daño"
		"DESTROY": return "Destruir objetivo"
		"BUFF": return "Aumentar Fuerza"
		"DEBUFF": return "Reducir Fuerza"
		"HEAL": return "Recuperar vida"
		"MILL": return "Botar cartas"
		"DISCARD": return "Descartar"
		"SEARCH": return "Buscar carta"
		"RETURN": return "Devolver a mano"
		"EXILE": return "Desterrar"
		"ANNUL": return "Anular objetivo"
		_: return "Efecto"


# =============================================================================
# ACTUALIZACIÓN DE ESTADO VISUAL
# =============================================================================
func _update_item_state(item: Control, stack_obj: Dictionary, state: String) -> void:
	"""Actualiza el estado visual de un item"""
	if not is_instance_valid(item):
		return

	var state_label = item.find_child("StateLabel", true, false)
	if state_label:
		match state:
			"waiting":
				state_label.text = "Esperando..."
				state_label.add_theme_color_override("font_color", Color.YELLOW)
			"resolving":
				state_label.text = "Resolviendo"
				state_label.add_theme_color_override("font_color", Color.GREEN)
			"resolved":
				state_label.text = "✓ Resuelto"
				state_label.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
			"annulled":
				state_label.text = "✗ Anulado"
				state_label.add_theme_color_override("font_color", Color.RED)
			"cancelled":
				state_label.text = "✗ Cancelado"
				state_label.add_theme_color_override("font_color", Color.ORANGE)
			"fizzled":
				state_label.text = "✗ Fizzled"
				state_label.add_theme_color_override("font_color", Color.GRAY)

	# Actualizar color de fondo según estado
	var step = stack_obj.get("step", 4)
	var style = item.get_theme_stylebox("panel") as StyleBoxFlat
	if style and STEP_COLORS.has(step):
		style.border_color = STEP_COLORS[step]


func _update_waiting_indicator(item: Control, priority_player: int) -> void:
	"""Muestra indicador de quién tiene prioridad"""
	var indicator = item.find_child("WaitIndicator", true, false)
	if indicator:
		indicator.visible = true
		indicator.text = "⏳ Esperando Jugador %d" % (priority_player + 1)


func _highlight_item(item: Control, highlight: bool) -> void:
	"""Resalta o quita resaltado de un item"""
	if not is_instance_valid(item):
		return

	var style = item.get_theme_stylebox("panel") as StyleBoxFlat
	if style:
		if highlight:
			style.border_width_left = 4
			style.border_width_right = 4
			style.border_width_top = 4
			style.border_width_bottom = 4
			style.border_color = Color.YELLOW
		else:
			style.border_width_left = 2
			style.border_width_right = 2
			style.border_width_top = 2
			style.border_width_bottom = 2
			style.border_color = Color(1, 1, 1, 0.3)


func _show_response_indicator(item: Control) -> void:
	"""Muestra indicador de que hubo respuesta"""
	var indicator = item.find_child("WaitIndicator", true, false)
	if indicator:
		indicator.text = "↑ Respuesta añadida"
		indicator.add_theme_color_override("font_color", Color.CYAN)


func _show_annulled_effect(item: Control, annuller: Dictionary) -> void:
	"""Muestra efecto visual de anulación"""
	var indicator = item.find_child("WaitIndicator", true, false)
	if indicator:
		indicator.visible = true
		var annuller_name = annuller.get("name", annuller.get("nombre", "carta"))
		indicator.text = "Anulado por: %s" % annuller_name
		indicator.add_theme_color_override("font_color", Color.RED)


# =============================================================================
# ANIMACIONES LIFO - Efectos "caen" sobre anteriores
# =============================================================================
const FALL_DISTANCE: float = 100.0      # Distancia de caída
const FALL_DURATION: float = 0.3        # Duración de caída
const FADE_DURATION: float = 0.25       # Duración de desvanecimiento
const PUSH_DOWN_AMOUNT: float = 5.0     # Cuánto se empujan los items inferiores
const RESOLUTION_DELAY: float = 0.4     # Pausa antes de activar siguiente

## Estado de animación
var _is_animating: bool = false
var _animation_queue: Array = []


func _animate_item_in(item: Control) -> void:
	"""Anima la entrada LIFO - El item 'cae' desde arriba sobre los demás"""
	if not is_instance_valid(item):
		return

	_is_animating = true

	# Estado inicial: arriba y transparente
	item.modulate.a = 0.0
	item.position.y = -FALL_DISTANCE
	item.scale = Vector2(0.8, 0.8)

	# Empujar items existentes hacia abajo (efecto de "peso")
	await _push_existing_items_down()

	# Animación de caída
	var tween = create_tween()
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
	_is_animating = false

	# Efecto de brillo al aterrizar
	_flash_item(item, Color(1, 1, 1, 0.5))


func _push_existing_items_down() -> void:
	"""Empuja los items existentes ligeramente hacia abajo"""
	var items_to_push = _stack_items.values()

	if items_to_push.is_empty():
		return

	var tween = create_tween()
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


func _animate_item_out(item: Control) -> void:
	"""Anima la salida - El item se desvanece hacia arriba antes del siguiente"""
	if not is_instance_valid(item):
		return

	_is_animating = true

	# Resaltar brevemente antes de salir
	await _flash_item(item, Color(0.5, 1, 0.5, 0.5))

	var tween = create_tween()
	tween.set_ease(Tween.EASE_IN)
	tween.set_trans(Tween.TRANS_QUAD)

	# Fase 1: Elevarse y desvanecerse
	tween.set_parallel(true)
	tween.tween_property(item, "modulate:a", 0.0, FADE_DURATION)
	tween.tween_property(item, "position:y", -30.0, FADE_DURATION)
	tween.tween_property(item, "scale", Vector2(0.9, 0.9), FADE_DURATION)

	await tween.finished

	# Pausa antes de activar el siguiente (visual de "procesamiento")
	await get_tree().create_timer(RESOLUTION_DELAY).timeout

	_is_animating = false


func _animate_item_annulled(item: Control) -> void:
	"""Animación especial para anulación - efecto de 'destrucción'"""
	if not is_instance_valid(item):
		return

	_is_animating = true

	# Flash rojo
	await _flash_item(item, Color.RED)

	var tween = create_tween()

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
	_is_animating = false


func _animate_item_fizzled(item: Control) -> void:
	"""Animación para fizzle - efecto de 'desintegración'"""
	if not is_instance_valid(item):
		return

	_is_animating = true

	var tween = create_tween()

	# Parpadeo gris
	tween.tween_property(item, "modulate", Color(0.5, 0.5, 0.5, 1.0), 0.1)
	tween.tween_property(item, "modulate", Color(0.3, 0.3, 0.3, 0.8), 0.1)
	tween.tween_property(item, "modulate", Color(0.5, 0.5, 0.5, 0.5), 0.1)
	tween.tween_property(item, "modulate:a", 0.0, 0.2)

	await tween.finished
	_is_animating = false


func _flash_item(item: Control, flash_color: Color) -> void:
	"""Efecto de destello en un item"""
	if not is_instance_valid(item):
		return

	var original_modulate = item.modulate

	var tween = create_tween()
	tween.tween_property(item, "modulate", flash_color, 0.05)
	tween.tween_property(item, "modulate", original_modulate, 0.1)

	await tween.finished


func _animate_stack_shift_up() -> void:
	"""Anima los items restantes subiendo cuando se remueve el tope"""
	var items = _stack_items.values()

	if items.is_empty():
		return

	var tween = create_tween()
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


# =============================================================================
# ESTADO DE PILA VACÍA
# =============================================================================
func _update_empty_state() -> void:
	"""Actualiza visibilidad del mensaje de pila vacía"""
	if empty_label:
		empty_label.visible = _stack_items.is_empty()


# =============================================================================
# INTERACCIÓN - Click derecho para ver carta y validar objetivo (Sección 8)
# =============================================================================
signal card_preview_requested(stack_obj: Dictionary)
signal target_validation_requested(stack_id: int, response_card: Dictionary)
signal annul_target_selected(stack_id: int)
signal cancel_target_selected(stack_id: int)

## Popup de contexto para interacción
var _context_popup: PopupMenu = null
var _selected_stack_id: int = -1
var _card_preview_window: Window = null

## IDs del menú contextual
enum ContextMenuID {
	VIEW_CARD = 0,
	CHECK_VALID_TARGET = 1,
	SELECT_AS_ANNUL_TARGET = 2,
	SELECT_AS_CANCEL_TARGET = 3
}


func _on_item_gui_input(event: InputEvent, stack_id: int) -> void:
	"""Maneja input en un item - Click izquierdo y derecho"""
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				# Click izquierdo: Seleccionar/resaltar
				emit_signal("stack_item_clicked", stack_id)
				_highlight_selected_item(stack_id)

			MOUSE_BUTTON_RIGHT:
				# Click derecho: Menú contextual (Sección 8)
				_selected_stack_id = stack_id
				_show_context_menu(stack_id, event.global_position)


func _show_context_menu(stack_id: int, position: Vector2) -> void:
	"""Muestra menú contextual para un item de la pila"""
	# Crear popup si no existe
	if _context_popup == null:
		_context_popup = PopupMenu.new()
		_context_popup.name = "StackContextMenu"
		add_child(_context_popup)
		_context_popup.id_pressed.connect(_on_context_menu_selected)

	_context_popup.clear()

	# Obtener datos del objeto
	var stack_obj = _get_stack_object_by_id(stack_id)
	if stack_obj.is_empty():
		return

	var obj_name = stack_obj.get("name", "???")
	var can_be_annulled = _can_be_annulled(stack_obj)
	var can_be_cancelled = _can_be_cancelled(stack_obj)

	# Opciones del menú
	_context_popup.add_item("👁 Ver carta: %s" % obj_name, ContextMenuID.VIEW_CARD)
	_context_popup.add_separator()
	_context_popup.add_item("🎯 Verificar como objetivo", ContextMenuID.CHECK_VALID_TARGET)

	# Opciones de Anular/Cancelar (Sección 8)
	_context_popup.add_separator()

	if can_be_annulled:
		_context_popup.add_item("⛔ Seleccionar para ANULAR", ContextMenuID.SELECT_AS_ANNUL_TARGET)
	else:
		_context_popup.add_item("⛔ No puede ser anulado", ContextMenuID.SELECT_AS_ANNUL_TARGET)
		_context_popup.set_item_disabled(_context_popup.item_count - 1, true)

	if can_be_cancelled:
		_context_popup.add_item("🚫 Seleccionar para CANCELAR", ContextMenuID.SELECT_AS_CANCEL_TARGET)
	else:
		_context_popup.add_item("🚫 No puede ser cancelado", ContextMenuID.SELECT_AS_CANCEL_TARGET)
		_context_popup.set_item_disabled(_context_popup.item_count - 1, true)

	# Mostrar popup
	_context_popup.position = Vector2i(position)
	_context_popup.popup()


func _on_context_menu_selected(id: int) -> void:
	"""Maneja selección del menú contextual"""
	var stack_obj = _get_stack_object_by_id(_selected_stack_id)

	match id:
		ContextMenuID.VIEW_CARD:
			_show_card_preview(stack_obj)

		ContextMenuID.CHECK_VALID_TARGET:
			_check_valid_target(stack_obj)

		ContextMenuID.SELECT_AS_ANNUL_TARGET:
			emit_signal("annul_target_selected", _selected_stack_id)
			_show_target_selection_feedback(_selected_stack_id, "annul")

		ContextMenuID.SELECT_AS_CANCEL_TARGET:
			emit_signal("cancel_target_selected", _selected_stack_id)
			_show_target_selection_feedback(_selected_stack_id, "cancel")


func _can_be_annulled(stack_obj: Dictionary) -> bool:
	"""Verifica si un objeto puede ser anulado (Sección 8)

	Reglas:
	- Solo cartas pueden ser anuladas (no habilidades ya en la pila)
	- Debe estar en la pila (ON_STACK o STEP_D)
	- No debe estar ya anulado
	"""
	var obj_type = stack_obj.get("type", -1)
	var step = stack_obj.get("step", -1)

	# Solo cartas (CARD_PLAYED y RESPONSE_CARD)
	if obj_type not in [StackObjectType.CARD_PLAYED, StackObjectType.RESPONSE_CARD]:
		return false

	# Debe estar activo en la pila
	if step not in [4, 5]:  # ON_STACK o STEP_D
		return false

	# No debe estar ya procesado
	if stack_obj.get("was_annulled", false):
		return false

	return true


func _can_be_cancelled(stack_obj: Dictionary) -> bool:
	"""Verifica si un objeto puede ser cancelado (Sección 8)

	Reglas:
	- Principalmente habilidades activadas/disparadas
	- Debe estar en la pila esperando
	- No debe estar ya cancelado
	"""
	var obj_type = stack_obj.get("type", -1)
	var step = stack_obj.get("step", -1)

	# Principalmente habilidades
	if obj_type not in [StackObjectType.TRIGGERED_ABILITY, StackObjectType.ACTIVATED_ABILITY]:
		return false

	# Debe estar activo en la pila
	if step not in [4, 5]:  # ON_STACK o STEP_D
		return false

	# No debe estar ya procesado
	if stack_obj.get("was_cancelled", false):
		return false

	return true


func _show_card_preview(stack_obj: Dictionary) -> void:
	"""Muestra ventana de preview de la carta completa"""
	emit_signal("card_preview_requested", stack_obj)

	# Crear ventana de preview si no existe
	if _card_preview_window == null:
		_card_preview_window = Window.new()
		_card_preview_window.name = "CardPreviewWindow"
		_card_preview_window.title = "Vista de Carta"
		_card_preview_window.size = Vector2i(350, 500)
		_card_preview_window.unresizable = false
		_card_preview_window.close_requested.connect(_close_card_preview)
		add_child(_card_preview_window)

		# Contenido de la ventana
		var preview_content = _create_card_preview_content()
		_card_preview_window.add_child(preview_content)

	# Actualizar contenido
	_update_card_preview_content(stack_obj)

	# Mostrar ventana
	_card_preview_window.popup_centered()


func _create_card_preview_content() -> Control:
	"""Crea el contenido de la ventana de preview"""
	var panel = PanelContainer.new()
	panel.name = "PreviewPanel"
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 15)
	margin.add_theme_constant_override("margin_right", 15)
	margin.add_theme_constant_override("margin_top", 15)
	margin.add_theme_constant_override("margin_bottom", 15)
	panel.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.name = "ContentVBox"
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	# Nombre de carta
	var name_label = Label.new()
	name_label.name = "CardName"
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(name_label)

	# Tipo
	var type_label = Label.new()
	type_label.name = "CardType"
	type_label.add_theme_font_size_override("font_size", 12)
	type_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	type_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(type_label)

	# Separador
	var sep = HSeparator.new()
	vbox.add_child(sep)

	# Coste y Fuerza
	var stats_hbox = HBoxContainer.new()
	stats_hbox.name = "StatsBox"
	stats_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(stats_hbox)

	var cost_label = Label.new()
	cost_label.name = "CostLabel"
	cost_label.add_theme_font_size_override("font_size", 14)
	stats_hbox.add_child(cost_label)

	var spacer = Control.new()
	spacer.custom_minimum_size.x = 30
	stats_hbox.add_child(spacer)

	var strength_label = Label.new()
	strength_label.name = "StrengthLabel"
	strength_label.add_theme_font_size_override("font_size", 14)
	stats_hbox.add_child(strength_label)

	# Habilidad
	var ability_label = RichTextLabel.new()
	ability_label.name = "AbilityText"
	ability_label.bbcode_enabled = true
	ability_label.fit_content = true
	ability_label.custom_minimum_size.y = 150
	vbox.add_child(ability_label)

	# Info de pila
	var sep2 = HSeparator.new()
	vbox.add_child(sep2)

	var stack_info = Label.new()
	stack_info.name = "StackInfo"
	stack_info.add_theme_font_size_override("font_size", 11)
	stack_info.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))
	stack_info.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(stack_info)

	# Botón cerrar
	var close_btn = Button.new()
	close_btn.name = "CloseButton"
	close_btn.text = "Cerrar"
	close_btn.pressed.connect(_close_card_preview)
	vbox.add_child(close_btn)

	return panel


func _update_card_preview_content(stack_obj: Dictionary) -> void:
	"""Actualiza el contenido del preview con los datos del objeto"""
	if _card_preview_window == null:
		return

	var card_data = stack_obj.get("card_data", {})
	var content = _card_preview_window.get_node_or_null("PreviewPanel/MarginContainer/ContentVBox")
	if content == null:
		return

	# Nombre
	var name_label = content.get_node_or_null("CardName")
	if name_label:
		name_label.text = stack_obj.get("name", "???")

	# Tipo
	var type_label = content.get_node_or_null("CardType")
	if type_label:
		type_label.text = stack_obj.get("type_name", "Desconocido")

	# Coste
	var cost_label = content.get_node_or_null("StatsBox/CostLabel")
	if cost_label:
		var cost = card_data.get("coste", 0)
		cost_label.text = "💰 Coste: %d" % cost

	# Fuerza
	var strength_label = content.get_node_or_null("StatsBox/StrengthLabel")
	if strength_label:
		var strength = card_data.get("fuerza", 0)
		if card_data.get("tipo", -1) == Constants.CardType.ALIADO:
			strength_label.text = "⚔️ Fuerza: %d" % strength
		else:
			strength_label.text = ""

	# Habilidad
	var ability_text = content.get_node_or_null("AbilityText")
	if ability_text:
		var ability = card_data.get("habilidad", card_data.get("ability", "Sin habilidad"))
		ability_text.text = ability

	# Info de pila
	var stack_info = content.get_node_or_null("StackInfo")
	if stack_info:
		var info_parts: Array = []
		info_parts.append("ID en pila: #%d" % stack_obj.get("id", 0))
		info_parts.append("Estado: %s" % stack_obj.get("step_name", "???"))

		var targets = stack_obj.get("targets", [])
		if not targets.is_empty():
			info_parts.append("Objetivos: %d" % targets.size())

		if _can_be_annulled(stack_obj):
			info_parts.append("✓ Puede ser ANULADO")
		if _can_be_cancelled(stack_obj):
			info_parts.append("✓ Puede ser CANCELADO")

		stack_info.text = "\n".join(info_parts)


func _close_card_preview() -> void:
	"""Cierra la ventana de preview"""
	if _card_preview_window:
		_card_preview_window.hide()


func _check_valid_target(stack_obj: Dictionary) -> void:
	"""Verifica y muestra si el objeto es un objetivo válido"""
	var is_valid_annul = _can_be_annulled(stack_obj)
	var is_valid_cancel = _can_be_cancelled(stack_obj)

	var message = "%s:\n" % stack_obj.get("name", "???")

	if is_valid_annul:
		message += "✓ VÁLIDO para Anular\n"
	else:
		message += "✗ NO puede ser Anulado\n"

	if is_valid_cancel:
		message += "✓ VÁLIDO para Cancelar"
	else:
		message += "✗ NO puede ser Cancelado"

	# Mostrar feedback visual
	_show_validation_popup(message, stack_obj.get("id", -1))

	emit_signal("target_validation_requested", stack_obj.get("id", -1), {})


func _show_validation_popup(message: String, stack_id: int) -> void:
	"""Muestra popup temporal con resultado de validación"""
	var popup = AcceptDialog.new()
	popup.dialog_text = message
	popup.title = "Validación de Objetivo"
	popup.confirmed.connect(popup.queue_free)
	popup.canceled.connect(popup.queue_free)
	add_child(popup)
	popup.popup_centered()


func _show_target_selection_feedback(stack_id: int, action_type: String) -> void:
	"""Muestra feedback visual cuando se selecciona un objetivo"""
	if not _stack_items.has(stack_id):
		return

	var item = _stack_items[stack_id]
	if not is_instance_valid(item):
		return

	# Flash según tipo de acción
	var flash_color = Color.RED if action_type == "annul" else Color.ORANGE
	_flash_item(item, flash_color)

	# Añadir indicador visual temporal
	var indicator = item.find_child("WaitIndicator", true, false)
	if indicator:
		indicator.visible = true
		if action_type == "annul":
			indicator.text = "⛔ OBJETIVO DE ANULACIÓN"
			indicator.add_theme_color_override("font_color", Color.RED)
		else:
			indicator.text = "🚫 OBJETIVO DE CANCELACIÓN"
			indicator.add_theme_color_override("font_color", Color.ORANGE)


func _highlight_selected_item(stack_id: int) -> void:
	"""Resalta el item seleccionado y quita resaltado de otros"""
	for id in _stack_items:
		var item = _stack_items[id]
		if is_instance_valid(item):
			var style = item.get_theme_stylebox("panel") as StyleBoxFlat
			if style:
				if id == stack_id:
					style.border_color = Color.CYAN
					style.border_width_left = 3
					style.border_width_right = 3
					style.border_width_top = 3
					style.border_width_bottom = 3
				else:
					style.border_color = Color(1, 1, 1, 0.3)
					style.border_width_left = 2
					style.border_width_right = 2
					style.border_width_top = 2
					style.border_width_bottom = 2


func _get_stack_object_by_id(stack_id: int) -> Dictionary:
	"""Obtiene el objeto de pila por ID"""
	if _action_pipeline and _action_pipeline.has_method("get_object_by_id"):
		return _action_pipeline.get_object_by_id(stack_id)

	# Fallback: buscar en metadata del item
	if _stack_items.has(stack_id):
		var item = _stack_items[stack_id]
		if is_instance_valid(item):
			return item.get_meta("stack_obj", {})

	return {}


func _on_item_mouse_entered(stack_id: int) -> void:
	"""Cuando el mouse entra en un item - hover effect"""
	emit_signal("stack_item_hovered", stack_id, true)

	if _stack_items.has(stack_id):
		var item = _stack_items[stack_id]
		if is_instance_valid(item):
			var tween = create_tween()
			tween.set_ease(Tween.EASE_OUT)
			tween.tween_property(item, "scale", Vector2(1.03, 1.03), 0.1)

			# Mostrar tooltip breve
			_show_hover_tooltip(item, stack_id)


func _on_item_mouse_exited(stack_id: int) -> void:
	"""Cuando el mouse sale de un item"""
	emit_signal("stack_item_hovered", stack_id, false)

	if _stack_items.has(stack_id):
		var item = _stack_items[stack_id]
		if is_instance_valid(item):
			var tween = create_tween()
			tween.tween_property(item, "scale", Vector2.ONE, 0.1)

			_hide_hover_tooltip()


var _hover_tooltip: Control = null

func _show_hover_tooltip(item: Control, stack_id: int) -> void:
	"""Muestra tooltip al hacer hover"""
	var stack_obj = _get_stack_object_by_id(stack_id)
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

		add_child(_hover_tooltip)

	# Actualizar contenido
	var label = _hover_tooltip.get_node_or_null("TooltipLabel")
	if label:
		var tip = "Click derecho: Opciones\n"
		if _can_be_annulled(stack_obj):
			tip += "• Puede ser anulado"
		elif _can_be_cancelled(stack_obj):
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
var _highlight_tweens: Dictionary = {}  # {stack_id: Tween}
var _is_target_selection_mode: bool = false


func highlight_target(stack_id: int, color: Color, is_valid: bool) -> void:
	"""Resalta un item como objetivo válido/inválido para selección"""
	if not _stack_items.has(stack_id):
		return

	var item = _stack_items[stack_id]
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
		var tween = create_tween()
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

	_is_target_selection_mode = true


func clear_all_highlights() -> void:
	"""Limpia todos los resaltados de selección de objetivo"""
	# Detener todos los tweens
	for stack_id in _highlight_tweens:
		var tween = _highlight_tweens[stack_id]
		if tween and tween.is_valid():
			tween.kill()
	_highlight_tweens.clear()

	# Restaurar estilos de todos los items
	for stack_id in _stack_items:
		var item = _stack_items[stack_id]
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

	_is_target_selection_mode = false


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
		indicator.text = "🎯"
		indicator.add_theme_color_override("font_color", Color.GREEN)
	else:
		indicator.text = "⛔"
		indicator.add_theme_color_override("font_color", Color.RED)


func _hide_target_indicator(item: Control) -> void:
	"""Oculta el indicador de objetivo"""
	var indicator = item.find_child("TargetIndicator", true, false)
	if indicator:
		indicator.visible = false


func get_all_item_ids() -> Array[int]:
	"""Retorna todos los IDs de items actualmente en el visualizador"""
	var ids: Array[int] = []
	for id in _stack_items.keys():
		ids.append(id)
	return ids


func is_in_target_selection_mode() -> bool:
	"""Retorna si está en modo de selección de objetivo"""
	return _is_target_selection_mode


# =============================================================================
# API PÚBLICA
# =============================================================================
func toggle_visibility() -> void:
	"""Alterna visibilidad del visualizador"""
	visible = not visible
	_is_expanded = visible
	emit_signal("visualizer_toggled", visible)


func refresh() -> void:
	"""Refresca la visualización desde el pipeline"""
	_clear_all_items()

	if not _action_pipeline:
		return

	var stack = _action_pipeline.get_stack()
	for obj in stack:
		_add_stack_item(obj)

	_update_empty_state()


func get_item_count() -> int:
	"""Retorna cantidad de items visualizados"""
	return _stack_items.size()
