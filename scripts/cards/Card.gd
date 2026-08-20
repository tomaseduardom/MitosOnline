extends Control
class_name Card
## Card - Representa una carta en el juego
## Maneja visualización, interacción y estados de la carta

# =============================================================================
# SEÑALES
# =============================================================================
signal card_clicked(card: Card)
signal card_double_clicked(card: Card)
signal card_right_clicked(card: Card)
signal card_hovered(card: Card)
signal card_unhovered(card: Card)
signal card_dragged(card: Card, position: Vector2)
signal card_dropped(card: Card, position: Vector2)
signal image_ready  # Emitida cuando la imagen frontal está lista (o confirmado sin imagen)

# Triggers (DAR 7.2, 7.3, 7.4)
signal trigger_activated(card: Card, trigger_type: String, event_data: Dictionary)

# =============================================================================
# EXPORTS
# =============================================================================
@export var card_id: String = ""
@export var card_scale_normal: float = 1.0
@export var card_scale_hover: float = 1.08
@export var card_scale_selected: float = 1.05
@export var hover_lift: float = 20.0
@export var animation_speed: float = 0.15
@export var flip_duration: float = 0.25

## Estado de visibilidad de la carta (true = muestra reverso)
@export var esta_oculta: bool = false:
	set(value):
		var was_hidden = esta_oculta
		esta_oculta = value
		if _is_ready:
			actualizar_aspecto()
			# Si pasó de oculta a visible, cargar imagen
			if was_hidden and not esta_oculta:
				_load_card_image()

# Alias para compatibilidad
var face_down: bool:
	get: return esta_oculta
	set(value): esta_oculta = value

# =============================================================================
# REFERENCIAS A NODOS (se asignan en _ready)
# =============================================================================
var card_base: Panel
var card_art: TextureRect
var hover_effect: Panel
var selection_effect: Panel
var anim_player: AnimationPlayer
var activatable_glow: Panel = null  # Indicador de "tiene una habilidad activada disponible ahora"
var _activatable_tween: Tween = null
var is_activatable: bool = false

# Placeholder (cuando no hay imagen)
var placeholder: VBoxContainer
var placeholder_icon: Label
var placeholder_name: Label
var placeholder_cost: Label

var _is_ready: bool = false

# =============================================================================
# DATOS DE LA CARTA
# =============================================================================
var card_data: Dictionary = {}
var _card_name: String = ""
var _card_cost: int = 0
var _card_strength: int = 0
var _card_ability: String = ""

var card_name: String:
	get:
		return _card_name
	set(value):
		_card_name = value

var card_cost: int:
	get:
		return _card_cost
	set(value):
		_card_cost = value

var card_strength: int:
	get:
		return _card_strength
	set(value):
		_card_strength = value

var card_ability: String:
	get:
		return _card_ability
	set(value):
		_card_ability = value
		# Parsear triggers cuando se asigna la habilidad
		if _is_ready:
			parse_triggers_from_ability()

var card_type: int = Constants.CardType.ALIADO
var card_raza: String = ""
var card_keywords: Array = []

# =============================================================================
# ESTADO DE LA CARTA
# =============================================================================
enum CardState {
	IN_DECK,
	IN_HAND,
	IN_PLAY,
	IN_GRAVEYARD,
	IN_EXILE,
	BEING_PLAYED,
	DRAGGING
}

var current_state: int = CardState.IN_HAND
var current_zone: int = Constants.Zone.MANO
var is_hovered: bool = false
var is_selected: bool = false
var is_dragging: bool = false
var is_face_up: bool = true
var can_interact: bool = true
## Arrastrar quedó desactivado a pedido del usuario (2026-08-17): era la
## fuente de varios bugs de posicionamiento (top_level sin preservar la
## posición visual, contenedores reordenando de forma diferida, etc.).
## Jugar cartas de la mano ya funciona por doble clic (_on_card_double_
## clicked); declarar un atacante ahora funciona con un solo clic sobre el
## Aliado en el campo (ver CardInteractionModule._on_card_clicked).
var drag_enabled: bool = false
var _image_ready: bool = false  # true cuando la imagen frontal está disponible

var drag_offset: Vector2 = Vector2.ZERO
var original_position: Vector2 = Vector2.ZERO
var original_z_index: int = 0

const DRAG_THRESHOLD: float = 8.0
var _drag_start_pos: Vector2 = Vector2.ZERO
var _drag_pending: bool = false  # esperando confirmar si es drag o click

var target_position: Vector2 = Vector2.ZERO
var target_rotation: float = 0.0
var target_scale: Vector2 = Vector2.ONE

# Escala base para animaciones de hover (permite que oros a 0.5 tengan hover proporcional)
var base_scale: Vector2 = Vector2.ONE

var controller_id: int = 0
var owner_id: int = 0

## Marca si la carta fue exhumada del cementerio (DAR - Exhumar)
## Las cartas exhumadas van al destierro cuando dejan el campo, no al cementerio
var is_exhumed: bool = false

## Enfermedad de invocación (DAR 3.1): true mientras la carta no haya pasado
## por una Agrupación del dueño — solo con Furia puede atacar en ese estado.
## Antes solo se guardaba como metadato (set_meta), pero TurnManager.can_attack()
## la lee con card.get(...), que NO ve metadatos — la verificación de Furia
## quedaba siempre inerte. Ahora es una propiedad real de la carta.
var entered_this_turn: bool = true

# =============================================================================
# SISTEMA DE TRIGGERS (DAR 7.2, 7.3, 7.4)
# =============================================================================
## Triggers parseados del texto de habilidad
var triggers: Array[Dictionary] = []

## Tipos de trigger soportados y sus palabras clave
const TRIGGER_KEYWORDS: Dictionary = {
	"on_draw": ["cuando robes", "al robar", "cada vez que robes"],
	"on_card_drawn": ["cuando robes una carta", "al robar una carta"],
	"on_enter_play": ["cuando entre al juego", "al entrar al juego", "cuando entra al juego", "cuando entre en juego", "al entrar en juego", "cuando entra en juego"],
	"on_leave_play": ["cuando deje el juego", "al dejar el juego", "cuando abandona el juego", "cuando salga del juego", "al salir del juego"],
	"on_destroyed": ["cuando sea destruido", "cuando muera", "al ser destruido", "al morir"],
	"on_discard": ["cuando descartes", "al descartar"],
	"on_attack": ["cuando ataque", "al atacar"],
	"on_block": ["cuando bloquee", "al bloquear"],
	"on_damage_dealt": ["cuando inflija daño", "al infligir daño", "si hizo daño", "cuando haga daño", "si inflige daño"],
	"on_damage_received": ["cuando reciba daño", "al recibir daño"],
	"on_turn_start": ["al comienzo del turno", "al inicio del turno"],
	"on_turn_end": ["al final del turno", "al terminar el turno"],
	"on_ally_enters": ["cuando otro aliado entre", "cuando un aliado entre"],
	"on_ally_dies": ["cuando otro aliado muera", "cuando un aliado sea destruido"],
	"on_oro_placed": ["cuando pongas un oro", "al poner un oro"],
	"on_card_played": ["cuando juegues", "al jugar"],
}

## Flag para evitar conectar signals múltiples veces
var _triggers_connected: bool = false

# =============================================================================
# INICIALIZACIÓN
# =============================================================================
func _ready() -> void:
	# Agregar al grupo de cartas para detección de drag
	add_to_group("cards")

	# Obtener referencias a nodos
	card_base = get_node_or_null("CardBase")
	if card_base:
		card_art = card_base.get_node_or_null("CardArt")
		placeholder = card_base.get_node_or_null("Placeholder")
		if placeholder:
			placeholder_icon = placeholder.get_node_or_null("TypeIcon")
			placeholder_name = placeholder.get_node_or_null("CardName")
			placeholder_cost = placeholder.get_node_or_null("CostLabel")

	hover_effect = get_node_or_null("HoverEffect")
	selection_effect = get_node_or_null("SelectionEffect")
	anim_player = get_node_or_null("AnimationPlayer")

	_create_activatable_glow()

	_is_ready = true

	# Configurar mouse
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	gui_input.connect(_on_gui_input)

	# Escuchar cambios de dorso
	var game_settings = get_node_or_null("/root/GameSettings")
	if game_settings:
		game_settings.card_back_changed.connect(_on_card_back_changed)

	# Conectar listeners de triggers y parsear si ya tiene habilidad
	_connect_trigger_listeners()
	if not _card_ability.is_empty():
		parse_triggers_from_ability()

	# Aplicar estilos
	_setup_styles()

	# Ocultar efectos
	if hover_effect:
		hover_effect.visible = false
	if selection_effect:
		selection_effect.visible = false

	# Aplicar aspecto según estado
	actualizar_aspecto()

	# === VALIDACIÓN DE TEXTURA (safety net contra bloques negros) ===
	if not card_art:
		printerr("[Card] NEGRO — card_art es null (nodo no encontrado). id='%s' path='%s'" % [card_id, card_image_path])
	elif not card_art.texture:
		printerr("[Card] NEGRO — card_art sin textura tras actualizar_aspecto. id='%s' path='%s' oculta=%s" % [card_id, card_image_path, str(esta_oculta)])
		# Forzar dorso para evitar el bloque negro
		var _gs = get_node_or_null("/root/GameSettings")
		if _gs:
			var _back = _gs.get_card_back_texture(owner_id)
			if _back:
				card_art.texture = _back
				card_art.visible = true
				if placeholder:
					placeholder.visible = false


func _apply_pending_data() -> void:
	"""Aplica los datos que se asignaron antes de _ready"""
	_update_placeholder()
	# Siempre mostrar dorso como estado inicial (nunca el bloque negro)
	_show_loading_dorso()

	if not card_image_path.is_empty() and card_image_path != "/dorso_default.webp":
		# Hay imagen CDN: cargarla de forma asíncrona
		_load_card_image()
	else:
		# Sin imagen CDN: el dorso ES el aspecto final → señalizar listo
		if not _image_ready:
			_image_ready = true
			image_ready.emit()


func _show_loading_dorso() -> void:
	"""Muestra el dorso de la carta mientras se descarga el arte frontal."""
	_show_placeholder(false)
	if card_art:
		var game_settings = get_node_or_null("/root/GameSettings")
		if game_settings:
			var back_tex = game_settings.get_card_back_texture(owner_id)
			if back_tex:
				card_art.texture = back_tex
				card_art.visible = true
				return
	# Fallback: placeholder si no hay dorso configurado
	_show_placeholder(true)


func _update_placeholder() -> void:
	"""Actualiza el contenido del placeholder"""
	if not placeholder:
		return

	# Icono según tipo de carta
	if placeholder_icon:
		match card_type:
			Constants.CardType.ORO:
				placeholder_icon.text = "💰"
				placeholder_icon.add_theme_color_override("font_color", Color(1, 0.85, 0.3))
			Constants.CardType.ALIADO:
				placeholder_icon.text = "⚔"
				placeholder_icon.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
			Constants.CardType.ARMA:
				placeholder_icon.text = "🗡"
				placeholder_icon.add_theme_color_override("font_color", Color(0.8, 0.5, 0.3))
			Constants.CardType.TALISMAN:
				placeholder_icon.text = "✨"
				placeholder_icon.add_theme_color_override("font_color", Color(0.6, 0.4, 0.8))
			Constants.CardType.TOTEM:
				placeholder_icon.text = "🏛"
				placeholder_icon.add_theme_color_override("font_color", Color(0.4, 0.7, 0.5))

	# Nombre de la carta
	if placeholder_name:
		placeholder_name.text = _card_name if not _card_name.is_empty() else "???"

	# Coste (solo si no es Oro)
	if placeholder_cost:
		if card_type == Constants.CardType.ORO:
			placeholder_cost.text = "ORO"
		else:
			placeholder_cost.text = "Coste: %d" % _card_cost


func _show_placeholder(show: bool) -> void:
	"""Muestra u oculta el placeholder"""
	if placeholder:
		placeholder.visible = show


func _setup_styles() -> void:
	"""Configura los estilos visuales de la carta"""
	if not card_base:
		return

	# Estilo del panel base (transparente, la imagen lo cubre todo)
	var base_style = StyleBoxFlat.new()
	base_style.bg_color = Color(0.1, 0.1, 0.1, 1)
	base_style.corner_radius_top_left = 8
	base_style.corner_radius_top_right = 8
	base_style.corner_radius_bottom_left = 8
	base_style.corner_radius_bottom_right = 8
	card_base.add_theme_stylebox_override("panel", base_style)

	# Estilo del hover
	if hover_effect:
		var hover_style = StyleBoxFlat.new()
		hover_style.bg_color = Color(1, 1, 1, 0.15)
		hover_style.corner_radius_top_left = 8
		hover_style.corner_radius_top_right = 8
		hover_style.corner_radius_bottom_left = 8
		hover_style.corner_radius_bottom_right = 8
		hover_effect.add_theme_stylebox_override("panel", hover_style)

	# Estilo de selección
	if selection_effect:
		var select_style = StyleBoxFlat.new()
		select_style.bg_color = Color(0.2, 0.6, 1, 0.2)
		select_style.border_color = Color(0.4, 0.8, 1)
		select_style.border_width_left = 3
		select_style.border_width_top = 3
		select_style.border_width_right = 3
		select_style.border_width_bottom = 3
		select_style.corner_radius_top_left = 10
		select_style.corner_radius_top_right = 10
		select_style.corner_radius_bottom_left = 10
		select_style.corner_radius_bottom_right = 10
		selection_effect.add_theme_stylebox_override("panel", select_style)


# =============================================================================
# CARGAR DATOS
# =============================================================================
var card_image_path: String = ""

func load_from_data(data: Dictionary, is_hidden: bool = false) -> void:
	"""Carga los datos de la carta desde un diccionario

	Args:
		data: Diccionario con datos de la carta
		is_hidden: Si true, la carta empieza oculta (no carga imagen)
	"""
	card_data = data
	card_id = str(data.get("id", ""))
	_card_name = data.get("nombre", "Sin nombre")
	_card_cost = data.get("coste", 0)
	_card_strength = data.get("fuerza", 0)
	card_type = data.get("tipo", Constants.CardType.ALIADO)
	_card_ability = data.get("habilidad", "")
	card_raza = data.get("raza", "")
	card_keywords = data.get("keywords", [])
	card_image_path = data.get("imagen", "")

	# Configurar estado oculto ANTES de actualizar aspecto
	if is_hidden:
		esta_oculta = true

	# Si ya está ready, aplicar aspecto inmediatamente
	if _is_ready:
		actualizar_aspecto()


func actualizar_aspecto() -> void:
	"""Actualiza la textura de la carta según esta_oculta"""
	# Asegurar que la carta es visible
	visible = true
	modulate.a = 1.0

	if esta_oculta:
		# Mostrar reverso (dorso de la carta) usando GameSettings según el dueño
		if card_art:
			var game_settings = get_node_or_null("/root/GameSettings")
			if game_settings:
				# Usar el dorso del dueño de la carta
				var back_texture = game_settings.get_card_back_texture(owner_id)
				if back_texture:
					card_art.texture = back_texture
			card_art.visible = true
			card_art.modulate.a = 1.0
		if placeholder:
			placeholder.visible = false
		# Panel con fondo oscuro para que se vea el borde
		if card_base:
			var style = StyleBoxFlat.new()
			style.bg_color = Color(0.15, 0.12, 0.1, 1.0)
			style.corner_radius_top_left = 8
			style.corner_radius_top_right = 8
			style.corner_radius_bottom_left = 8
			style.corner_radius_bottom_right = 8
			card_base.add_theme_stylebox_override("panel", style)
		# El dorso ES el aspecto final: desbloquear HandManager para que anime
		if not _image_ready:
			_image_ready = true
			image_ready.emit()
	else:
		# Mostrar frente
		_setup_styles()
		_apply_pending_data()  # ya llama _load_card_image() internamente


func voltear() -> void:
	"""Voltea la carta con animación de flip"""
	var tween = create_tween()
	tween.tween_property(self, "scale:x", 0.0, flip_duration / 2.0)
	tween.tween_callback(func():
		esta_oculta = !esta_oculta
	)
	tween.tween_property(self, "scale:x", scale.y, flip_duration / 2.0)


func _show_card_back() -> void:
	"""Muestra el dorso de la carta (compatibilidad)"""
	esta_oculta = true


func _on_card_back_changed(_back_id: String) -> void:
	"""Actualiza el dorso cuando cambia en GameSettings"""
	if esta_oculta and card_art:
		var game_settings = get_node_or_null("/root/GameSettings")
		if game_settings:
			# Usar el dorso según el dueño de la carta
			var back_texture = game_settings.get_card_back_texture(owner_id)
			if back_texture:
				card_art.texture = back_texture


func load_from_id(id: String) -> void:
	"""Carga la carta desde su ID usando CardDatabase"""
	var data = CardDatabase.get_card(id)
	if not data.is_empty():
		load_from_data(data)


# =============================================================================
# CARGA DE IMAGEN
# =============================================================================
var _image_signal_connected: bool = false

func _load_card_image() -> void:
	"""Carga la imagen de la carta desde CardDatabase"""
	# No cargar imagen si la carta está oculta (ahorra recursos)
	if esta_oculta:
		return

	# Sin imagen o imagen de dorso por defecto → el dorso ya está mostrado, nada que hacer
	if card_id.is_empty() or card_image_path.is_empty() or card_image_path == "/dorso_default.webp":
		return

	print("[Card] Cargando imagen — id:%s path:%s" % [card_id, card_image_path])

	# Verificar si ya está en cache
	var texture = CardDatabase.get_card_image(card_id)
	if texture:
		_set_card_texture(texture)
	else:
		# Conectar señal para cuando se descargue
		if not _image_signal_connected:
			CardDatabase.card_image_loaded.connect(_on_card_image_loaded)
			_image_signal_connected = true


func _on_card_image_loaded(loaded_card_id: String, texture: Texture2D) -> void:
	"""Callback cuando se carga una imagen (texture puede ser null si CDN falló)"""
	if loaded_card_id == card_id:
		if texture:
			_set_card_texture(texture)
		else:
			# CDN falló: mantener dorso visible y señalizar listo igual
			if not _image_ready:
				_image_ready = true
				image_ready.emit()
		_disconnect_image_signal()


func _set_card_texture(texture: Texture2D) -> void:
	"""Aplica la textura frontal de la carta y señaliza que está lista."""
	if card_art and texture and not esta_oculta:
		card_art.texture = texture
		card_art.visible = true
		_show_placeholder(false)
	if not _image_ready:
		_image_ready = true
		image_ready.emit()


func _disconnect_image_signal() -> void:
	"""Desconecta la señal de carga de imagen"""
	if _image_signal_connected and CardDatabase.card_image_loaded.is_connected(_on_card_image_loaded):
		CardDatabase.card_image_loaded.disconnect(_on_card_image_loaded)
		_image_signal_connected = false


func _exit_tree() -> void:
	"""Limpieza cuando la carta se elimina"""
	_disconnect_image_signal()


# =============================================================================
# INTERACCIÓN
# =============================================================================
func _on_mouse_entered() -> void:
	if not can_interact or is_dragging:
		return

	is_hovered = true
	if hover_effect:
		hover_effect.visible = true

	# Guardar z_index original y ponerlo encima de las demás
	original_z_index = z_index
	z_index = 100

	emit_signal("card_hovered", self)

	# Animación de hover (proporcional a base_scale)
	var tween = create_tween()
	tween.tween_property(self, "scale", base_scale * card_scale_hover, animation_speed)


func _on_mouse_exited() -> void:
	if is_dragging:
		return

	# Si no puede interactuar, no hacer nada (evita resetear escala en inspección)
	if not can_interact:
		return

	is_hovered = false
	if hover_effect:
		hover_effect.visible = false

	# Restaurar z_index original
	z_index = original_z_index

	emit_signal("card_unhovered", self)

	# Volver a escala normal (proporcional a base_scale)
	var tween = create_tween()
	var target_scale_val = base_scale * (card_scale_selected if is_selected else card_scale_normal)
	tween.tween_property(self, "scale", target_scale_val, animation_speed)


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		# Right-click siempre funciona para inspección
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			emit_signal("card_right_clicked", self)
			return

		# Otras interacciones requieren can_interact
		if not can_interact:
			return

		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if event.double_click:
					emit_signal("card_double_clicked", self)
				else:
					# NO llamar _start_drag() inmediatamente — esperar movimiento
					_drag_pending = true
					_drag_start_pos = event.position
					emit_signal("card_clicked", self)
			else:
				if _drag_pending:
					# El usuario soltó sin arrastrar — solo fue un click
					_drag_pending = false
				elif is_dragging:
					_end_drag()

	elif event is InputEventMouseMotion:
		if not can_interact:
			return
		if _drag_pending:
			var distance = event.position.distance_to(_drag_start_pos)
			if distance >= DRAG_THRESHOLD:
				_drag_pending = false
				_start_drag(_drag_start_pos)
		elif is_dragging:
			_update_drag(event.position)


func _can_declare_attack_drag() -> bool:
	"""Verifica si un Aliado en el campo puede arrastrarse para declarar
	ataque. Cubre dos casos DAR: ataque anticipado con Furia durante
	Vigilia, o declaración normal durante el propio paso de Ataque.

	Antes solo permitía el caso de Furia en Vigilia — como declarar el
	primer atacante ya cambia la fase a Ataque (GameManager.proceed_to_
	battle()), CUALQUIER intento de arrastrar un segundo Aliado (con o sin
	Furia) quedaba bloqueado acá mismo, antes de llegar siquiera a
	DropZone/GameManager.declare_attacker() — de ahí que nunca se pudiera
	atacar con más de un Aliado. La validación completa (enfermedad de
	invocación, etc.) la sigue haciendo TurnManager.can_attack() más
	adelante; acá solo se decide si tiene sentido iniciar el arrastre."""
	if card_type != Constants.CardType.ALIADO:
		return false
	if current_zone != Constants.Zone.LINEA_DEFENSA:
		return false
	var gm = get_node_or_null("/root/GameManager")
	if not gm:
		return false
	if gm.current_phase == Constants.Phase.ATAQUE:
		return true
	if gm.current_phase == Constants.Phase.VIGILIA:
		return has_keyword(Constants.Keyword.FURIA)
	return false


func _start_drag(mouse_pos: Vector2) -> void:
	"""Inicia el arrastre de la carta"""
	if not drag_enabled:
		return
	if current_state != CardState.IN_HAND:
		if not _can_declare_attack_drag():
			return

	is_dragging = true
	current_state = CardState.DRAGGING
	drag_offset = mouse_pos
	original_position = global_position  # Guardar posición global antes de top_level
	original_z_index = z_index
	z_index = 100
	# Desacoplar del Container para que global_position no sea sobreescrita por el layout
	top_level = true
	# Godot NO preserva la posición visual al activar top_level: 'position'
	# pasaba a interpretarse como absoluta de pantalla sin ningún ajuste, así
	# que la carta saltaba de inmediato a donde sea que ese valor apuntara
	# (por eso 'se iba a la esquina inferior derecha' apenas se la tomaba).
	# Hay que reaplicar la posición global recién guardada para que el
	# arrastre empiece exactamente donde la carta ya estaba.
	global_position = original_position

	var tween = create_tween()
	tween.tween_property(self, "scale", Vector2.ONE * card_scale_selected, animation_speed)


func _update_drag(mouse_pos: Vector2) -> void:
	"""Actualiza la posición durante el arrastre"""
	if not is_dragging:
		return

	global_position = get_global_mouse_position() - drag_offset
	emit_signal("card_dragged", self, global_position)


func _end_drag() -> void:
	"""Finaliza el arrastre"""
	if not is_dragging:
		return

	is_dragging = false
	emit_signal("card_dropped", self, global_position)

	# Verificar si hay zona de drop válida debajo
	var drop_zone = _get_drop_zone_under_mouse()
	if drop_zone and drop_zone.has_method("on_card_dropped"):
		# La zona de drop maneja la carta
		drop_zone.on_card_dropped(self)
	else:
		# Regresar a la posición original con animación
		return_to_hand()


func return_to_hand() -> void:
	"""Regresa la carta a su posición original (mano o campo) con animación"""
	if current_zone in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO]:
		# Carta del campo: reintegrar al Container (top_level=false) y dejar que gestione posición
		current_state = CardState.IN_PLAY
		top_level = false
		# Mientras se arrastraba (top_level=true), la posición LOCAL quedó con
		# el último valor usado para alcanzar la posición global del mouse.
		# Al volver a top_level=false esa posición local pasa a sumarse a la
		# del contenedor padre — el HBoxContainer recién la corrige en su
		# próximo reordenamiento (diferido), así que por uno o dos fotogramas
		# la carta se dibuja en un lugar completamente incorrecto antes de
		# 'aparecer' en su sitio. Forzar el reordenamiento ahora evita ese
		# fotograma con posición basura (causa real de que pareciera
		# desaparecer justo al soltar la carta en la Línea de Ataque).
		position = Vector2.ZERO
		var parent_container = get_parent()
		if parent_container:
			parent_container.queue_sort()
		var tween = create_tween()
		tween.set_parallel(true)
		tween.tween_property(self, "rotation_degrees", target_rotation, 0.2).set_ease(Tween.EASE_OUT)
		tween.tween_property(self, "scale", base_scale, 0.2).set_ease(Tween.EASE_OUT)
		await tween.finished
	else:
		# Carta de la mano: animar de vuelta a la posición guardada
		current_state = CardState.IN_HAND
		top_level = false
		var tween = create_tween()
		tween.set_parallel(true)
		tween.tween_property(self, "global_position", original_position, 0.25).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
		tween.tween_property(self, "rotation_degrees", target_rotation, 0.25).set_ease(Tween.EASE_OUT)
		tween.tween_property(self, "scale", base_scale, 0.25).set_ease(Tween.EASE_OUT)
		await tween.finished

	z_index = original_z_index


func _get_drop_zone_under_mouse() -> Node:
	"""Detecta la zona de drop más específica bajo el mouse.

	La zona de batalla (LINEA_ATAQUE, ~700x96) está geométricamente contenida
	dentro de la zona de campo (LINEA_DEFENSA, ~800x240) — ver
	SceneSetupModule._setup_drop_zones(). Antes se devolvía la primera zona
	del grupo "drop_zones" que contuviera el mouse, y como field_drop se
	registra antes que battle_drop, soltar una carta cerca del centro del
	tablero (para declarar un atacante) siempre caía en field_drop → volvía
	a pagarse el coste como si se jugara de nuevo. Ahora gana la zona de
	área más chica entre todas las que contienen el punto (la más
	específica), sin depender del orden de registro."""
	var mouse_pos = get_global_mouse_position()
	var best_zone: Node = null
	var best_area := INF

	for zone in get_tree().get_nodes_in_group("drop_zones"):
		if zone is Control:
			var rect: Rect2 = zone.get_global_rect()
			if rect.has_point(mouse_pos):
				var area: float = rect.size.x * rect.size.y
				if area < best_area:
					best_area = area
					best_zone = zone

	return best_zone


# =============================================================================
# SELECCIÓN
# =============================================================================
func select() -> void:
	"""Selecciona la carta"""
	is_selected = true
	if selection_effect:
		selection_effect.visible = true

	var tween = create_tween()
	tween.tween_property(self, "scale", Vector2.ONE * card_scale_selected, animation_speed)


func deselect() -> void:
	"""Deselecciona la carta"""
	is_selected = false
	if selection_effect:
		selection_effect.visible = false

	var tween = create_tween()
	tween.tween_property(self, "scale", Vector2.ONE * card_scale_normal, animation_speed)


func toggle_selection() -> void:
	"""Alterna el estado de selección"""
	if is_selected:
		deselect()
	else:
		select()


# =============================================================================
# INDICADOR DE HABILIDAD ACTIVABLE
# Distinto de "disparar" (trigger, automático) — esto es una habilidad que
# el jugador PUEDE elegir usar ahora mismo. Brillo celeste pulsante,
# independiente del brillo amarillo de CardInspectionLayo (ese indica
# "resolviéndose en la pila", no "disponible para activar").
# =============================================================================
func _create_activatable_glow() -> void:
	"""Crea el panel de brillo celeste, oculto por defecto. Se construye por
	código (no en el .tscn) para no tocar la escena de Card, igual que
	hover_effect/selection_effect en espíritu pero como nodo nuevo."""
	activatable_glow = Panel.new()
	activatable_glow.name = "ActivatableGlow"
	activatable_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	activatable_glow.set_anchors_preset(Control.PRESET_FULL_RECT)
	activatable_glow.visible = false

	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.3, 0.75, 1.0, 0.0)
	style.border_color = Color(0.45, 0.85, 1.0, 1.0)
	style.set_border_width_all(3)
	style.set_corner_radius_all(10)
	style.shadow_color = Color(0.45, 0.85, 1.0, 0.55)
	style.shadow_size = 10
	activatable_glow.add_theme_stylebox_override("panel", style)

	add_child(activatable_glow)
	move_child(activatable_glow, 0)  # detrás del arte de la carta


func set_activatable(active: bool) -> void:
	"""Muestra u oculta el brillo celeste de 'tiene una habilidad activable
	disponible ahora'. Llamado desde un escaneo externo (ver
	CardInspectionLayer.refresh_activatable_glows()), no desde la propia
	carta — ella no sabe si puede pagarse ni si ya se usó este turno."""
	if active == is_activatable:
		return
	is_activatable = active

	if not activatable_glow:
		return

	if _activatable_tween and _activatable_tween.is_valid():
		_activatable_tween.kill()

	if active:
		activatable_glow.visible = true
		activatable_glow.modulate.a = 1.0
		_activatable_tween = create_tween().set_loops()
		_activatable_tween.tween_property(activatable_glow, "modulate:a", 0.35, 0.6).set_ease(Tween.EASE_IN_OUT)
		_activatable_tween.tween_property(activatable_glow, "modulate:a", 1.0, 0.6).set_ease(Tween.EASE_IN_OUT)
	else:
		activatable_glow.visible = false


# =============================================================================
# ANIMACIONES
# =============================================================================
func move_to(target_pos: Vector2, duration: float = 0.3) -> void:
	"""Mueve la carta a una posición con animación"""
	var tween = create_tween()
	tween.tween_property(self, "position", target_pos, duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)


func flip_card(face_up: bool, duration: float = 0.2) -> void:
	"""Voltea la carta"""
	is_face_up = face_up

	var tween = create_tween()
	tween.tween_property(self, "scale:x", 0, duration / 2)
	tween.tween_callback(func():
		if card_base:
			card_base.visible = face_up
	)
	tween.tween_property(self, "scale:x", card_scale_normal, duration / 2)


func play_destroy_animation() -> void:
	"""Animación cuando la carta es destruida"""
	var tween = create_tween()
	tween.tween_property(self, "modulate:a", 0, 0.3)
	tween.parallel().tween_property(self, "scale", Vector2.ONE * 0.5, 0.3)
	tween.tween_callback(queue_free)


func play_enter_animation() -> void:
	"""Animación cuando la carta entra en juego"""
	scale = Vector2.ZERO
	modulate.a = 0

	var tween = create_tween()
	tween.tween_property(self, "scale", Vector2.ONE, 0.3).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tween.parallel().tween_property(self, "modulate:a", 1, 0.2)


# =============================================================================
# UTILIDADES
# =============================================================================
func get_strength() -> int:
	"""Retorna la fuerza actual (para combate)"""
	return _card_strength


func has_keyword(keyword: int) -> bool:
	"""Verifica si la carta tiene una keyword"""
	return keyword in card_keywords


func can_attack() -> bool:
	"""Verifica si la carta puede atacar"""
	if card_type != Constants.CardType.ALIADO:
		return false
	if current_zone != Constants.Zone.LINEA_DEFENSA:
		return false
	return true


func can_block() -> bool:
	"""Verifica si la carta puede bloquear"""
	if card_type != Constants.CardType.ALIADO:
		return false
	if current_zone != Constants.Zone.LINEA_DEFENSA:
		return false
	return true


func set_zone(zone: int) -> void:
	"""Cambia la zona de la carta"""
	current_zone = zone

	match zone:
		Constants.Zone.MANO:
			current_state = CardState.IN_HAND
		Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO:
			current_state = CardState.IN_PLAY
		Constants.Zone.CEMENTERIO:
			current_state = CardState.IN_GRAVEYARD
		Constants.Zone.DESTIERRO:
			current_state = CardState.IN_EXILE
		Constants.Zone.CASTILLO:
			current_state = CardState.IN_DECK


# =============================================================================
# SISTEMA DE TRIGGERS (DAR 7.2, 7.3, 7.4)
# =============================================================================
func _connect_trigger_listeners() -> void:
	"""Inicializa el sistema de triggers de la carta
	Nota: TriggerSystem maneja la recolección global de eventos (DAR 7.4)
	La carta solo expone has_trigger() y _trigger_conditions_met()
	"""
	_triggers_connected = true


func parse_triggers_from_ability() -> void:
	"""Parsea el texto de habilidad para extraer triggers"""
	triggers.clear()

	if _card_ability.is_empty():
		return

	var ability_lower = _card_ability.to_lower()

	for trigger_type in TRIGGER_KEYWORDS:
		var keywords: Array = TRIGGER_KEYWORDS[trigger_type]
		for keyword in keywords:
			if ability_lower.contains(keyword):
				triggers.append({
					"type": trigger_type,
					"keyword": keyword,
					"ability_text": _card_ability
				})
				# Solo un trigger por tipo
				break


func is_in_play() -> bool:
	"""Verifica si la carta está en una zona de juego"""
	return current_zone in Constants.ZONES_IN_PLAY


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

	print("[Card] Trigger detectado: %s en %s" % [trigger_type, _card_name])

	# Registrar con TriggerSystem para gestión de cola (DAR 7.4)
	var trigger_system = get_node_or_null("/root/TriggerSystem")
	if trigger_system:
		trigger_system.register_trigger(self, trigger_type, event_data)

	# También emitir señal local para conexiones directas
	emit_signal("trigger_activated", self, trigger_type, event_data)


func _trigger_conditions_met(trigger_type: String, event_data: Dictionary) -> bool:
	"""Verifica condiciones adicionales del trigger"""
	var ability_lower = _card_ability.to_lower()

	# Verificar si es "tu" o del "oponente"
	var event_player = event_data.get("player_id", -1)

	if ability_lower.contains("cuando tú") or ability_lower.contains("cuando robes"):
		# Solo se activa si es nuestro evento
		if event_player != controller_id:
			return false

	if ability_lower.contains("cuando tu oponente") or ability_lower.contains("cuando el oponente"):
		# Solo se activa si es evento del oponente
		if event_player == controller_id:
			return false

	# Verificar "otro aliado" (no esta carta)
	if trigger_type == "on_ally_enters" or trigger_type == "on_ally_dies":
		var event_card = event_data.get("card", null)
		if event_card == self:
			return false

	return true


# =============================================================================
# EJECUCIÓN DE EFECTOS CON CALLABLE (Godot 4.6)
# =============================================================================
## Handlers de efectos personalizados por tipo de trigger
var effect_handlers: Dictionary = {}


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

	# Si no hay handler específico, intentar resolver por tipo de trigger
	result = await _resolve_default_effect(trigger_type, event_data)

	return result


func _resolve_default_effect(trigger_type: String, event_data: Dictionary) -> Dictionary:
	"""Resuelve efectos por defecto basados en el texto de habilidad
	'En medida de lo posible': intenta ejecutar lo que pueda
	"""
	var result = {
		"success": true,
		"partial": false,
		"effects_applied": []
	}

	var ability_lower = _card_ability.to_lower()

	# Detectar y ejecutar efectos comunes del texto
	var effect_ctrl = get_node_or_null("/root/EffectController")
	var game_mgr = get_node_or_null("/root/GameManager")

	# Robar cartas
	if ability_lower.contains("roba") and ability_lower.contains("carta"):
		var amount = _extract_number_from_text(ability_lower, "roba", 1)
		if effect_ctrl:
			var draw_result = await effect_ctrl.draw_cards(controller_id, amount)
			result.effects_applied.append({
				"type": "draw",
				"requested": amount,
				"actual": draw_result.actual
			})
			if draw_result.actual < amount:
				result.partial = true

	# Descartar cartas
	if ability_lower.contains("descarta") and ability_lower.contains("carta"):
		# TODO: Implementar selección de cartas a descartar
		result.effects_applied.append({"type": "discard", "pending": true})

	# Infligir daño
	if ability_lower.contains("inflige") and ability_lower.contains("daño"):
		var damage = _extract_number_from_text(ability_lower, "inflige", 1)
		# TODO: Implementar sistema de daño
		result.effects_applied.append({"type": "damage", "amount": damage})

	# Destruir carta
	if ability_lower.contains("destruye"):
		# TODO: Implementar selección de objetivo
		result.effects_applied.append({"type": "destroy", "pending": true})

	# Generar oros virtuales
	if ability_lower.contains("genera") and ability_lower.contains("oro"):
		var amount = _extract_number_from_text(ability_lower, "genera", 1)
		if game_mgr and game_mgr.has_method("generar_oros_virtuales"):
			game_mgr.generar_oros_virtuales(amount)
			result.effects_applied.append({"type": "virtual_gold", "amount": amount})

	return result


func _extract_number_from_text(text: String, after_word: String, default: int) -> int:
	"""Extrae un número del texto después de una palabra clave"""
	var pos = text.find(after_word)
	if pos == -1:
		return default

	# Buscar número después de la palabra
	var remaining = text.substr(pos + after_word.length()).strip_edges()

	# Mapeo de palabras a números
	var word_numbers = {
		"una": 1, "un": 1, "1": 1,
		"dos": 2, "2": 2,
		"tres": 3, "3": 3,
		"cuatro": 4, "4": 4,
		"cinco": 5, "5": 5
	}

	for word in word_numbers:
		if remaining.begins_with(word):
			return word_numbers[word]

	return default


func on_entered_play() -> void:
	"""Llamado cuando la carta entra al juego
	Vincula la carta al TriggerSystem con Callable
	"""
	# Parsear triggers de la habilidad
	parse_triggers_from_ability()

	# Registrar con TriggerSystem
	var trigger_system = get_node_or_null("/root/TriggerSystem")
	if trigger_system:
		trigger_system.bind_card_to_triggers(self)

	print("[Card] %s entró al juego con %d triggers" % [_card_name, triggers.size()])


func on_left_play() -> void:
	"""Llamado cuando la carta deja el juego
	Limpia efectos continuos y handlers
	"""
	# Desregistrar efectos continuos
	var trigger_system = get_node_or_null("/root/TriggerSystem")
	if trigger_system:
		trigger_system.unregister_continuous_effect(self)

	effect_handlers.clear()
	print("[Card] %s dejó el juego" % _card_name)


