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
signal card_preview_requested(stack_obj: Dictionary)
signal target_validation_requested(stack_id: int, response_card: Dictionary)
signal annul_target_selected(stack_id: int)
signal cancel_target_selected(stack_id: int)

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

## Módulos extraídos (Fase 4 de reestructuración)
var _animations: StackItemAnimations
var _context_menu: StackContextMenu
var _target_highlight: StackTargetHighlight

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
	# Inicializar módulos extraídos
	_animations = StackItemAnimations.new()
	_animations.setup(self)
	_context_menu = StackContextMenu.new()
	_context_menu.setup(self)
	_target_highlight = StackTargetHighlight.new()
	_target_highlight.setup(self)

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
	_action_pipeline = ActionPipeline

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
		await _animations.animate_item_out(_stack_items[stack_id])


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
		await _animations.animate_item_annulled(item)


func _on_object_cancelled(stack_obj: Dictionary) -> void:
	"""Cuando un objeto es cancelado"""
	var stack_id = stack_obj.get("id", -1)
	if _stack_items.has(stack_id):
		var item = _stack_items[stack_id]
		_update_item_state(item, stack_obj, "cancelled")
		# Usar animación de anulación (similar visual)
		await _animations.animate_item_annulled(item)


func _on_object_fizzled(stack_obj: Dictionary) -> void:
	"""Cuando un objeto hace fizzle"""
	var stack_id = stack_obj.get("id", -1)
	if _stack_items.has(stack_id):
		var item = _stack_items[stack_id]
		_update_item_state(item, stack_obj, "fizzled")
		# Usar animación de desintegración
		await _animations.animate_item_fizzled(item)


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
	_animations.animate_item_in(item)

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
	item.gui_input.connect(_context_menu.on_item_gui_input.bind(stack_obj.get("id", -1)))
	item.mouse_entered.connect(_target_highlight.on_item_mouse_entered.bind(stack_obj.get("id", -1)))
	item.mouse_exited.connect(_target_highlight.on_item_mouse_exited.bind(stack_obj.get("id", -1)))

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
# ESTADO DE PILA VACÍA
# =============================================================================
func _update_empty_state() -> void:
	"""Actualiza visibilidad del mensaje de pila vacía"""
	if empty_label:
		empty_label.visible = _stack_items.is_empty()


# =============================================================================
# INTERACCIÓN - Click derecho para ver carta y validar objetivo (Sección 8)
# Implementación en StackContextMenu.gd. _can_be_annulled/_can_be_cancelled
# y los helpers de abajo quedan acá porque los usan tanto el menú contextual
# como el tooltip de hover (StackTargetHighlight.gd).
# =============================================================================
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

	# Protección explícita en el propio texto de la carta (2026-08-29, p.ej.
	# Miguel: "Cuando entra en juego... Esta habilidad no puede ser
	# cancelada.") — antes esta función solo miraba estado estructural de
	# la pila, nunca el texto de la carta, así que esta protección nunca se
	# aplicaba de verdad.
	var ability_text: String = str(stack_obj.get("card_data", {}).get("habilidad", "")).to_lower()
	if "no puede ser cancelad" in ability_text:
		return false

	return true


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


# =============================================================================
# API PÚBLICA
# =============================================================================
func highlight_target(stack_id: int, color: Color, is_valid: bool) -> void:
	"""Wrapper público — llamado externamente por TargetSelector."""
	_target_highlight.highlight_target(stack_id, color, is_valid)


func clear_all_highlights() -> void:
	"""Wrapper público — llamado externamente por TargetSelector."""
	_target_highlight.clear_all_highlights()


func get_all_item_ids() -> Array[int]:
	"""Retorna todos los IDs de items actualmente en el visualizador"""
	var ids: Array[int] = []
	for id in _stack_items.keys():
		ids.append(id)
	return ids


func is_in_target_selection_mode() -> bool:
	"""Retorna si está en modo de selección de objetivo"""
	return _target_highlight.is_target_selection_mode


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
