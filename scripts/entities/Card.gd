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
@export var card_scale_hover: float = 1.015
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

## Badge de Fuerza efectiva (2026-08-22) — el número impreso en el arte de
## la carta es una imagen estática, no se puede editar; este Label se
## superpone en la esquina para mostrar la Fuerza REAL (base + Armas/buffs),
## p.ej. un Aliado de Fuerza 4 portando un Arma que da +2 debe mostrar "6".
var strength_badge: Control = null
## Badge de Coste efectivo (2026-08-30, mismo motivo que strength_badge:
## el coste impreso es parte del arte, no se puede editar) — se superpone
## en la esquina opuesta cuando un descuento/recargo lo cambia, p.ej.
## Miguel (-1) o Tesoro de los Césares (+1 el turno siguiente).
var cost_badge: Control = null

var placeholder: VBoxContainer
var placeholder_icon: Label
var placeholder_name: Label
var placeholder_cost: Label

var _is_ready: bool = false

## Módulos extraídos (Fase 4 de reestructuración)
var _interaction: CardInteraction
var _animations: CardAnimations

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
# ARMAS (DAR — un Arma solo puede jugarse portada por un Aliado, no suelta)
# =============================================================================
## Solo poblado en un Aliado: las Armas que porta (nodos Card, hijos directos
## de este nodo — así lo siguen automáticamente al reparentarse/destruirse).
var equipped_weapons: Array = []
## Solo poblado en un Arma: el Aliado que la porta.
var wielder: Node = null

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

## Quién CONTROLA la carta ahora mismo (de qué lado del tablero pelea, quién
## puede atacar/activar sus habilidades) — por defecto sigue a owner_id
## (ver su setter abajo), y solo diverge cuando un efecto te deja jugar o
## controlar una carta ajena sin volverte su dueño (2026-08-29, DAR: jugar
## una carta del rival te vuelve controlador, no dueño — p.ej. Miguel,
## "juega una carta de tu mano o de un Cementerio", donde SÍ puede ser el
## Cementerio rival). Antes este campo existía pero nada lo mantenía
## sincronizado con owner_id — toda carta normal (nunca tocada por un
## efecto así) quedaba en controller_id=0 sin importar su dueño real.
var controller_id: int = 0
var _owner_id: int = 0
var owner_id: int:
	get: return _owner_id
	set(value):
		_owner_id = value
		controller_id = value

## Marca si la carta fue exhumada del cementerio (DAR - Exhumar)
## Las cartas exhumadas van al destierro cuando dejan el campo, no al cementerio
var is_exhumed: bool = false

## Convertida en una carta (del mismo tipo u otro) SIN habilidad (2026-08-26,
## p.ej. Signo Amarillo convirtiéndose en un Oro sin habilidad). Distinto de
## "perder la habilidad" (silenciada, ver KeywordManager.is_silenced()): son
## dos efectos separados con su propio texto de protección ("no puede ser
## convertida" vs "no puede perder su habilidad"), pero el resultado visible
## es el mismo — pierde su caja de texto, conserva coste y Fuerza, y gira
## 180° (_refresh_disabled_rotation()).
var is_converted: bool = false:
	set(value):
		is_converted = value
		_refresh_disabled_rotation()

## Datos originales de esta carta cuando su propio efecto la transformó
## reversiblemente en OTRO tipo/zona de verdad (2026-08-29, p.ej.
## Jormundgander: Aliado que se convierte en Oro al hacer daño y vuelve a
## ser Aliado si se lo paga) — {} = no aplica. Distinto de is_converted
## (que es "perdió su habilidad" sin cambiar tipo/zona, DAR otro efecto):
## acá card_type y la zona cambian de verdad. GoldManager._mover_oro_a_
## pagado() lo revisa al pagar este Oro para saber si debe revertirlo en
## vez de moverlo a Oro Pagado normalmente.
var revert_to_data: Dictionary = {}


func _refresh_disabled_rotation() -> void:
	"""Gira la carta 180° desde su centro si es del oponente en juego (Oro, Aliado, Arma, Tótem),
	o si está silenciada o convertida."""
	var is_opp: bool = (owner_id == 1 or controller_id == 1)
	var parent_name: String = get_parent().name if get_parent() else ""
	var is_opp_in_play: bool = is_opp and (
		current_zone in [
			Constants.Zone.RESERVA_ORO,
			Constants.Zone.ORO_PAGADO,
			Constants.Zone.LINEA_DEFENSA,
			Constants.Zone.LINEA_ATAQUE,
			Constants.Zone.LINEA_APOYO
		]
		or parent_name in [
			"OpponentField",
			"OpponentReservaOro",
			"OpponentOroPagado",
			"OpponentLineaAtaque",
			"OpponentLineaApoyo"
		]
	)

	var should_rotate: bool = is_opp_in_play or is_converted
	if not should_rotate and KeywordManager and KeywordManager.has_method("is_silenced"):
		should_rotate = KeywordManager.is_silenced(self)

	# Un Aliado sin habilidad (silenciado/convertido) propio que porta un Arma CON
	# habilidad cuenta como si tuviera habilidad (DAR): no gira.
	if should_rotate and not is_opp_in_play:
		for weapon in equipped_weapons:
			if is_instance_valid(weapon) and not str(weapon.get("card_ability")).strip_edges().is_empty():
				should_rotate = false
				break

	var target_rot: float = 180.0 if should_rotate else target_rotation
	var card_size: Vector2 = size if (size.x > 0 and size.y > 0) else (custom_minimum_size if (custom_minimum_size.x > 0 and custom_minimum_size.y > 0) else Vector2(150, 210))
	pivot_offset = card_size / 2.0
	rotation_degrees = target_rot


func _apply_frozen_weapon_transform(_t: float, weapon: Node, frozen_pos: Vector2, frozen_rot: float, base_self_rot: float) -> void:
	"""Callback de tween_method() para congelar la posición/rotación visual
	de un Arma equipada mientras su portador gira (Convertir/Silenciar) —
	extraído a método con nombre en vez de lambda inline (2026-08-30:
	un lambda multilínea como argumento directo de tween_method(), anidado
	dentro de if/for, le rompía el parser a GDScript — 'Expected indented
	block after else' en un bloque totalmente ajeno del archivo)."""
	if not is_instance_valid(weapon):
		return
	weapon.global_position = frozen_pos
	weapon.rotation_degrees = frozen_rot - (rotation_degrees - base_self_rot)


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
	# (2026-08-28, misma corrección de terminología que CardFactory.TRIGGER_PATTERNS)
	"on_enter_play": ["cuando entre al juego", "al entrar al juego", "cuando entra al juego", "cuando entre en juego", "al entrar en juego", "cuando entra en juego", "cuando entra o salga del juego", "cuando entra en juego o ataque"],
	"on_leave_play": ["al salir del juego", "cuando salga del juego", "cuando sale del juego", "cuando entra o salga del juego"],
	"on_destroyed": ["cuando sea destruido", "al ser destruido"],
	"on_discard": ["cuando descartes", "al descartar"],
	# "cuando entra en juego o ataque" (2026-08-29, p.ej. Sherlock Holmes) es
	# UNA sola cláusula con dos disparadores — "cuando ataque" no aparece
	# como substring literal ahí ("cuando entra en juego O ataque"), así que
	# necesita su propia frase para que has_trigger("on_attack") la detecte.
	"on_attack": ["cuando ataque", "al atacar", "cuando entra en juego o ataque"],
	"on_block": ["cuando bloquee", "al bloquear"],
	"on_damage_dealt": ["cuando haga daño de combate", "cuando haga daño", "si hizo daño"],
	"on_damage_received": ["cuando fueras a recibir daño"],
	"on_turn_start": ["al comienzo del turno", "al inicio del turno"],
	# "en tu fase final" agregado (2026-08-30, p.ej. Espada de O'Higgins) —
	# antes SOLO estaban las frases genéricas de "al final del turno", que
	# ninguna carta real usa; "en tu Fase Final" es la frase real del DAR
	# para este disparador y no matcheaba nada.
	"on_turn_end": ["al final del turno", "al terminar el turno", "en tu fase final"],
	# "en tu Agrupación" (2026-08-30, p.ej. Espada del Juicio: "Cuando entra
	# en juego y en tu Agrupación, Destierra..."). Sin/con tilde por las
	# dudas — la API a veces trae mojibake en palabras acentuadas.
	"on_agrupacion": ["en tu agrupación", "en tu agrupacion"],
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
	# Inicializar módulos extraídos
	_interaction = CardInteraction.new()
	_interaction.setup(self)
	_animations = CardAnimations.new()
	_animations.setup(self)

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
	_create_strength_badge()
	_create_cost_badge()
	if not ContinuousEffectManager.card_visual_update_required.is_connected(_on_strength_visual_update_required):
		ContinuousEffectManager.card_visual_update_required.connect(_on_strength_visual_update_required)

	_is_ready = true

	# Configurar mouse
	# NO conectar mouse_entered/mouse_exited nativos (2026-08-28, arregla el
	# salto infinito reportado por el usuario): el rect que Godot usa para
	# esas señales no tiene en cuenta 'scale', así que quedaban desfasadas
	# cerca de un borde apenas el hover escalaba la carta y competían con
	# CardInteraction.process() (que sí calcula bien la posición con
	# get_local_mouse_position()) — las dos fuentes de hover se peleaban y
	# producían el loop entra/sale. process() es ahora la única fuente de
	# verdad para is_hovered.
	gui_input.connect(_interaction.on_gui_input)

	# Escuchar cambios de dorso
	GameSettings.card_back_changed.connect(_on_card_back_changed)

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
	refresh_strength_badge()
	_refresh_disabled_rotation()

	# === VALIDACIÓN DE TEXTURA (safety net contra bloques negros) ===
	if not card_art:
		printerr("[Card] NEGRO — card_art es null (nodo no encontrado). id='%s' path='%s'" % [card_id, card_image_path])
	elif not card_art.texture:
		printerr("[Card] NEGRO — card_art sin textura tras actualizar_aspecto. id='%s' path='%s' oculta=%s" % [card_id, card_image_path, str(esta_oculta)])
		# Forzar dorso para evitar el bloque negro
		var _back = GameSettings.get_card_back_texture(owner_id)
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
		var back_tex = GameSettings.get_card_back_texture(owner_id)
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
		refresh_strength_badge()
		refresh_cost_badge()

	# Una copia recién creada de un nombre ya bloqueado por
	# KeywordManager.lock_ability_by_name() (2026-08-29, p.ej. Alicia en
	# Wonderland) debe nacer ya girada 180° — sin esto, una carta robada
	# DESPUÉS de que el nombre quedó bloqueado no mostraba el indicador
	# hasta que algo más disparara _refresh_disabled_rotation().
	_refresh_disabled_rotation()


func actualizar_aspecto() -> void:
	"""Actualiza la textura de la carta según esta_oculta"""
	# Asegurar que la carta es visible
	visible = true
	modulate.a = 1.0

	if esta_oculta:
		# Mostrar reverso (dorso de la carta) usando GameSettings según el dueño
		if card_art:
			# Usar el dorso del dueño de la carta
			var back_texture = GameSettings.get_card_back_texture(owner_id)
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
		# Usar el dorso según el dueño de la carta
		var back_texture = GameSettings.get_card_back_texture(owner_id)
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
			# CDN falló: mostrar placeholder legible (nombre/coste) en vez del
			# dorso, porque el dorso no deja identificar qué carta es la que
			# no cargó — solo aplica si la carta está boca arriba.
			if not esta_oculta:
				_update_placeholder()
				_show_placeholder(true)
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


func _on_strength_visual_update_required(card: Node, stat: String, _base_value: int, _modified_value: int) -> void:
	"""Refresca el badge correspondiente cuando ContinuousEffectManager
	avisa que un modificador cambió el valor calculado de ESTA carta —
	conectado en _ready() (2026-08-30: la función existía referenciada acá
	en _exit_tree() para desconectarse, pero nunca estuvo declarada ni
	conectada — 'Identifier not declared', corrupción histórica ajena a
	esta sesión)."""
	if card != self:
		return
	match stat:
		"strength":
			refresh_strength_badge()
		"cost":
			refresh_cost_badge()


func _exit_tree() -> void:
	"""Limpieza cuando la carta se elimina"""
	_disconnect_image_signal()
	if ContinuousEffectManager.card_visual_update_required.is_connected(_on_strength_visual_update_required):
		ContinuousEffectManager.card_visual_update_required.disconnect(_on_strength_visual_update_required)
	# Si esta carta era FUENTE de algún modificador continuo (p.ej. un Arma
	# dándole Fuerza a su portador), se limpia cuando REALMENTE sale de
	# juego — is_queued_for_deletion() es la guarda clave (2026-08-22):
	# _exit_tree() también se dispara en un reparenting normal y temporal
	# (remove_child + add_child), como cuando un Aliado ataca y se mueve a
	# Línea de Ataque — el Arma equipada es su HIJA, así que también salía
	# y volvía a entrar al árbol, y sin esta guarda el bono de Fuerza se
	# borraba justo al declarar el ataque (el combate usaba la Fuerza base,
	# aunque la carta siguiera mostrando el badge ya calculado en verde).
	if is_queued_for_deletion() and ContinuousEffectManager.has_method("remove_modifiers_from_source"):
		ContinuousEffectManager.remove_modifiers_from_source(self)
	# Misma idea para modificadores de COSTE registrados por esta carta
	# mientras estuvo en juego (p.ej. el impuesto de Bernardo O'Higgins a
	# Talismanes/Tótems, 2026-08-26) — PaymentManager.cost_modifiers no se
	# limpiaba solo al salir de juego, solo al empezar un turno nuevo.
	if is_queued_for_deletion() and PaymentManager.has_method("remover_modificador_coste"):
		PaymentManager.remover_modificador_coste(self)


# =============================================================================
# INTERACCIÓN (implementación en CardInteraction.gd)
# =============================================================================
func _process(delta: float) -> void:
	_interaction.process(delta)


func _can_declare_attack_drag() -> bool:
	"""Wrapper público — llamado externamente por CardInteractionModule."""
	return _interaction.can_declare_attack_drag()


func return_to_hand() -> void:
	"""Wrapper público — llamado externamente por DropZone, GoldManager, CardInteractionModule."""
	await _interaction.return_to_hand()


# =============================================================================
# SELECCIÓN
# =============================================================================
func select() -> void:
	"""Selecciona la carta — solo el borde, sin escala (2026-08-28, a pedido
	del usuario: hacía un 'pop' a Vector2.ONE * card_scale_selected que
	ignoraba base_scale — se veía mal en cartas en juego, sobre todo en
	Tótems (base_scale 0.8) que saltaban a tamaño completo."""
	is_selected = true
	if selection_effect:
		selection_effect.visible = true


func deselect() -> void:
	"""Deselecciona la carta"""
	is_selected = false
	if selection_effect:
		selection_effect.visible = false


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


func _create_strength_badge() -> void:
	"""Crea el badge de Fuerza efectiva en la esquina superior izquierda (solo el número brillante, sin caja)."""
	var lbl = Label.new()
	lbl.name = "StrengthBadge"
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_override("font", preload("res://assets/fonts/Cinzel-Bold.ttf"))
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	lbl.add_theme_constant_override("shadow_offset_x", 2)
	lbl.add_theme_constant_override("shadow_offset_y", 2)
	lbl.add_theme_constant_override("shadow_outline_size", 4)
	lbl.position = Vector2(6, 2)
	lbl.size = Vector2(28, 28)
	lbl.pivot_offset = Vector2(14, 14)
	lbl.visible = false

	strength_badge = lbl
	add_child(strength_badge)
	move_child(strength_badge, get_child_count() - 1)


func _create_cost_badge() -> void:
	"""Crea el badge de Coste efectivo en la esquina superior derecha (solo el número brillante, sin caja)."""
	var lbl = Label.new()
	lbl.name = "CostBadge"
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_override("font", preload("res://assets/fonts/Cinzel-Bold.ttf"))
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	lbl.add_theme_constant_override("shadow_offset_x", 2)
	lbl.add_theme_constant_override("shadow_offset_y", 2)
	lbl.add_theme_constant_override("shadow_outline_size", 4)
	lbl.position = Vector2(custom_minimum_size.x - 32.0, 2)
	lbl.size = Vector2(28, 28)
	lbl.pivot_offset = Vector2(14, 14)
	lbl.visible = false

	cost_badge = lbl
	add_child(cost_badge)
	move_child(cost_badge, get_child_count() - 1)


func refresh_strength_badge(source_override: Node = null) -> void:
	"""Recalcula y muestra la Fuerza efectiva AHORA (no espera al próximo
	cambio de modificador) — llamar justo después de equipar/quitar un Arma
	o cualquier acción que pueda afectar la Fuerza de esta carta."""
	var effective := _card_strength
	if ContinuousEffectManager.has_method("get_modified_strength"):
		effective = ContinuousEffectManager.get_modified_strength(source_override if source_override else self)
	_apply_strength_badge_text(effective)


func _apply_strength_badge_text(value: int) -> void:
	if not strength_badge:
		return
	if card_type != Constants.CardType.ALIADO or esta_oculta:
		strength_badge.visible = false
		return
	if value == _card_strength:
		strength_badge.visible = false
		return

	var is_buff := value > _card_strength
	var lbl: Label = strength_badge as Label
	if not lbl:
		return

	var prev_text := lbl.text
	var new_text := str(value)
	lbl.text = new_text

	if is_buff:
		lbl.add_theme_color_override("font_color", Color(0.25, 1.0, 0.40, 1.0))
		lbl.add_theme_color_override("font_shadow_color", Color(0.02, 0.20, 0.05, 0.95))
	else:
		lbl.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35, 1.0))
		lbl.add_theme_color_override("font_shadow_color", Color(0.25, 0.02, 0.02, 0.95))

	if not strength_badge.visible or prev_text != new_text:
		strength_badge.visible = true
		strength_badge.scale = Vector2(1.35, 1.35)
		var tw = create_tween()
		tw.tween_property(strength_badge, "scale", Vector2.ONE, 0.20).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	else:
		strength_badge.visible = true


func refresh_cost_badge(source_override: Node = null) -> void:
	"""Recalcula y muestra el Coste efectivo AHORA (PaymentManager.
	calcular_coste_real, que ya suma cost_modifiers/oros_mas_modifiers/
	recargos por nombre) — llamar después de cualquier acción que pueda
	cambiarlo: aplicar/quitar un modificador de coste, o al empezar un
	turno nuevo (los recargos diferidos tipo Tesoro de los Césares recién
	arrancan/expiran ahí)."""
	var effective := _card_cost
	if PaymentManager.has_method("calcular_coste_real"):
		effective = PaymentManager.calcular_coste_real(source_override if source_override else self)
	_apply_cost_badge_text(effective)


func _apply_cost_badge_text(value: int) -> void:
	if not cost_badge:
		return
	if esta_oculta:
		cost_badge.visible = false
		return
	if value == _card_cost:
		cost_badge.visible = false
		return

	var is_discount := value < _card_cost
	var lbl: Label = cost_badge as Label
	if not lbl:
		return

	var prev_text := lbl.text
	var new_text := str(value)
	lbl.text = new_text

	if is_discount:
		lbl.add_theme_color_override("font_color", Color(0.25, 1.0, 0.40, 1.0))
		lbl.add_theme_color_override("font_shadow_color", Color(0.02, 0.20, 0.05, 0.95))
	else:
		lbl.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35, 1.0))
		lbl.add_theme_color_override("font_shadow_color", Color(0.25, 0.02, 0.02, 0.95))

	if not cost_badge.visible or prev_text != new_text:
		cost_badge.visible = true
		cost_badge.scale = Vector2(1.35, 1.35)
		var tw = create_tween()
		tw.tween_property(cost_badge, "scale", Vector2.ONE, 0.20).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	else:
		cost_badge.visible = true


func set_activatable(value: bool) -> void:
	"""Muestra u oculta el brillo celeste que indica 'tenés una habilidad
	activable disponible ahora mismo' (distinto del brillo amarillo de
	CardInspectionLayer, que indica 'resolviéndose en la pila') — llamado
	desde CardInspectionLayer.refresh_activatable_glows()."""
	if is_activatable == value:
		return
	is_activatable = value
	if not activatable_glow:
		return
	if _activatable_tween and _activatable_tween.is_valid():
		_activatable_tween.kill()
	if value:
		activatable_glow.visible = true
		activatable_glow.modulate.a = 0.3
		_activatable_tween = create_tween()
		_activatable_tween.set_loops()
		_activatable_tween.tween_property(activatable_glow, "modulate:a", 1.0, 0.6).set_ease(Tween.EASE_IN_OUT)
		_activatable_tween.tween_property(activatable_glow, "modulate:a", 0.3, 0.6).set_ease(Tween.EASE_IN_OUT)
	else:
		activatable_glow.visible = false


# ANIMACIONES (implementación en CardAnimations.gd)
func move_to(target_pos: Vector2, duration: float = 0.3) -> void:
	_animations.move_to(target_pos, duration)


func play_destroy_animation() -> void:
	_animations.play_destroy_animation()


func play_enter_animation() -> void:
	_animations.play_enter_animation()


# =============================================================================
# UTILIDADES
# =============================================================================
func get_strength() -> int:
	"""Retorna la fuerza actual (para combate)"""
	return _card_strength


func has_keyword(keyword: int) -> bool:
	"""Verifica si la carta tiene una keyword — incluye las que le transmiten
	sus Armas equipadas (2026-08-24, DAR): un Arma con Furia/Imbloqueable/
	etc. se la da a su portador mientras esté equipada. Se lee
	weapon.card_keywords directo (no weapon.has_keyword()) porque un Arma
	nunca porta otras Armas — no hace falta ni tiene sentido recursar.

	También consulta ContinuousEffectManager (2026-09-02, bug reportado por
	el usuario con Espíritu Kotaix: 'Tus Aliados ganan... Furia' registraba
	el modificador de keyword bien, pero esta función — la que de verdad
	usa la declaración de ataque, CardInteractionModule.gd — solo miraba
	card_keywords/equipped_weapons, sin ningún cruce con las keywords
	OTORGADAS por auras de otras cartas. Hay un tercer sistema paralelo
	(KeywordManager._temporary_keywords) que tampoco se cruza con ninguno
	de los otros dos — quedó fuera de este fix a propósito, alcance
	acotado al caso reportado."""
	if keyword in card_keywords:
		return true
	for weapon in equipped_weapons:
		if is_instance_valid(weapon) and keyword in weapon.card_keywords:
			return true
	if ContinuousEffectManager and ContinuousEffectManager.has_method("has_keyword") and ContinuousEffectManager.has_keyword(self, keyword):
		return true
	return false


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
	_refresh_disabled_rotation()


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
	# Nota (2026-08-27): los Talismanes NO se resuelven por acá — no
	# "disparan" nada (DAR Sección 7.4 es para habilidades disparadas de
	# permanentes). Su texto se resuelve directo al jugarlos, ver
	# TriggerSystem.resolve_talisman() / GoldManager._trigger_enter_play().


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
	TriggerSystem.register_trigger(self, trigger_type, event_data)

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

	# Sin handler específico registrado (2026-08-22): NO usar
	# _resolve_default_effect() acá — es un escaneo de palabras clave sobre
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
	TriggerSystem.bind_card_to_triggers(self)

	print("[Card] %s entró al juego con %d triggers" % [_card_name, triggers.size()])


func on_left_play() -> void:
	"""Llamado cuando la carta deja el juego
	Limpia efectos continuos y handlers
	"""
	# Desregistrar efectos continuos
	TriggerSystem.unregister_continuous_effect(self)

	effect_handlers.clear()
	print("[Card] %s dejó el juego" % _card_name)
