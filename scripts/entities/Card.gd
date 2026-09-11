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
				_image_loader._load_card_image()

# Alias para compatibilidad
var face_down: bool:
	get: return esta_oculta
	set(value): esta_oculta = value

var _is_ready: bool = false

# =============================================================================
# REFERENCIAS A NODOS (se asignan en _ready)
# =============================================================================
var card_base: Panel
var card_art: TextureRect
var hover_effect: Panel
var selection_effect: Panel
var anim_player: AnimationPlayer

var placeholder: VBoxContainer
var placeholder_icon: Label
var placeholder_name: Label
var placeholder_cost: Label

## Módulos extraídos (Fase 4 de reestructuración; CardTriggerRuntime/
## CardBadges agregados 2026-09-06, "módulos gordos")
var _interaction: CardInteraction
var _animations: CardAnimations
var _trigger_runtime: CardTriggerRuntime
var _badges: CardBadges
var _image_loader: CardImageLoader

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

## 'Hace doble daño de combate al Destierro' (2026-09-04, a pedido del
## usuario — p.ej. atenea en wonderland, manuel rodriguez): el daño de
## combate que ESTA carta hace al Castillo se dobla y las cartas Botadas
## por él van al Destierro en vez del Cementerio — ver BattleManager.
## _accumulate_castle_damage(), consultado durante ASIGNACION_DANIO.
var doubles_damage_to_exile: bool = false

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
	"""Gira la carta 180° desde su centro si es del oponente en juego (Mano, Oro, Aliado, Arma, Tótem),
	o si está silenciada o convertida."""
	var parent_name: String = get_parent().name if get_parent() else ""
	var parent_parent_name: String = get_parent().get_parent().name if (get_parent() and get_parent().get_parent()) else ""
	var is_in_opp_container: bool = parent_name.begins_with("Opponent") or parent_parent_name == "OpponentArea"
	var is_opp: bool = (owner_id == 1 or controller_id == 1 or is_in_opp_container)
	var is_opp_in_play: bool = is_opp and (
		is_in_opp_container
		or current_zone in [
			Constants.Zone.MANO,
			Constants.Zone.RESERVA_ORO,
			Constants.Zone.ORO_PAGADO,
			Constants.Zone.LINEA_DEFENSA,
			Constants.Zone.LINEA_ATAQUE,
			Constants.Zone.LINEA_APOYO
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

	var target_rot: float = 180.0 if should_rotate else 0.0
	var card_size: Vector2 = size if (size.x > 0 and size.y > 0) else (custom_minimum_size if (custom_minimum_size.x > 0 and custom_minimum_size.y > 0) else Vector2(150, 210))
	var center_piv: Vector2 = card_size / 2.0
	pivot_offset = center_piv
	rotation_degrees = 0.0

	# Aplicar sobre CardBase (nodo visual interno) de manera exclusiva para evitar suma de matrices (180° + 180° = 360°)
	if card_base:
		card_base.pivot_offset = center_piv
		card_base.rotation_degrees = target_rot


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
# SISTEMA DE TRIGGERS (declaraciones — implementación en CardTriggerRuntime.gd)
# =============================================================================
## Tipos de trigger soportados y sus palabras clave. Queda acá (no en
## CardTriggerRuntime.gd) porque TriggerResolution.gd lo lee de forma
## ESTÁTICA vía la clase (Card.TRIGGER_KEYWORDS[...]), no sobre una
## instancia — moverlo rompería ese acceso.
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
	# "cuando el portador ataque" (2026-09-06, bug real reportado por el
	# usuario — p.ej. Garfio Pirata: 'Cuando el portador ataque, si es de
	# coste 1 o más, genera un Oro o Roba una carta') — NINGUNA de las
	# frases de abajo matchea 'el portador' insertado entre 'cuando' y
	# 'ataque', así que _isolate_all_trigger_clauses() no cortaba ahí el
	# bloque del ETB y esta oración se ejecutaba AL EQUIPARSE en vez de al
	# atacar (mismo síntoma que el bug ya documentado de 2026-08-30, pero
	# esta frase puntual seguía sin cubrir).
	"on_attack": ["cuando ataque", "al atacar", "cuando entra en juego o ataque", "cuando el portador ataque"],
	"on_block": ["cuando bloquee", "al bloquear"],
	"on_damage_dealt": ["cuando haga daño de combate", "cuando haga daño", "si hizo daño"],
	"on_damage_received": ["cuando fueras a recibir daño"],
	"on_turn_start": ["al comienzo del turno", "al inicio del turno", "al comienzo de tu turno"],
	# "en tu fase final" agregado (2026-08-30, p.ej. Espada de O'Higgins) —
	# antes SOLO estaban las frases genéricas de "al final del turno", que
	# ninguna carta real usa; "en tu Fase Final" es la frase real del DAR
	# para este disparador y no matcheaba nada.
	"on_turn_end": ["al final del turno", "al terminar el turno", "en tu fase final"],
	# "en la Fase Final oponente" (2026-09-04, p.ej. Biblioteca de
	# Caballería) — distinto de "en tu Fase Final" de arriba: dispara en la
	# Fase Final del RIVAL, no la propia. Ver TriggerSystem.
	# resolve_turn_end_triggers() para el disparo real (escanea el campo
	# del jugador contrario cuando termina el turno de ESE jugador).
	"on_opponent_turn_end": ["en la fase final oponente", "en la fase final de tu oponente"],
	# "Al comienzo del Ataque" (2026-09-04, a pedido del usuario — p.ej.
	# almirante akari) — fase Ataque, distinta de "al comienzo del turno"
	# (on_turn_start, ligado a Agrupación).
	"on_ataque_start": ["al comienzo del ataque"],
	# "en tu Agrupación" (2026-08-30, p.ej. Espada del Juicio: "Cuando entra
	# en juego y en tu Agrupación, Destierra..."). Sin/con tilde por las
	# dudas — la API a veces trae mojibake en palabras acentuadas.
	"on_agrupacion": ["en tu agrupación", "en tu agrupacion"],
	# "Al comienzo de tu/la Vigilia" (2026-09-03, corregido a pedido del
	# usuario — NO "en tu vigilia" sola: Vigilia es la ventana NORMAL de
	# las habilidades activadas ("una vez por turno, puedes X"), así que
	# "En tu Vigilia, X" sin más es casi siempre esa ventana, no un
	# disparador. Solo "Al comienzo de tu/la Vigilia" es inequívocamente
	# un disparador real (p.ej. Colmillo de Vampiro: "Al comienzo de la
	# Vigilia, puedes Barajar..." — el "puedes" ahí es sobre el EFECTO
	# ofrecido en ese momento, no sobre cuándo activarlo). Con solo
	# "en tu vigilia" como frase, la PRIMERA habilidad de Espada de
	# O'Higgins ("En tu Vigilia, una vez por turno, puedes Barajar...")
	# se habría tratado como disparador automático por error, saltándose
	# el "puedes"/cupo de una vez por turno. "en tu vigilia o fase final"
	# se agrega aparte, acotado a esa combinación exacta (p.ej. Mariano
	# Osorio) — Fase Final SÍ es siempre disparador (no es ventana de
	# activadas), así que emparejada con Vigilia en la misma oración
	# arrastra a Vigilia también, sin el riesgo de falso positivo de
	# "en tu vigilia" sola.
	"on_vigilia": ["al comienzo de tu vigilia", "al comienzo de la vigilia", "en tu vigilia o fase final"],
	"on_ally_enters": ["cuando otro aliado entre", "cuando un aliado entre"],
	"on_ally_dies": ["cuando otro aliado muera", "cuando un aliado sea destruido"],
	"on_oro_placed": ["cuando pongas un oro", "al poner un oro"],
	"on_card_played": ["cuando juegues", "al jugar"],
}

## Recorte del área de CLICK (no del área visual — ver _has_point() más
## abajo), en X local, cuando esta carta está tapada por la derecha por
## otra carta superpuesta de la MISMA fila (2026-09-03, bug reportado:
## en la Reserva de Oro, con muchas cartas la separación del HBoxContainer
## se vuelve negativa (GoldManager._update_container_gold_spacing(), hasta
## -125px) para que quepan todas, así que cartas consecutivas se superponen
## bastante — cada Card sigue siendo un Control de 150×210 completo aunque
## visualmente la carta siguiente (añadida después, dibujada encima) tape
## buena parte de su derecha. Sin este recorte, esa porción tapada seguía
## siendo clicable en la carta de ABAJO — un click ahí (que visualmente
## apunta a la carta de ARRIBA) se lo comía la de abajo en silencio, y
## viceversa en las esquinas/bordes donde la superposición es parcial.
## -1.0 = sin recorte (comportamiento normal, rect completo).
var _click_clip_right: float = -1.0


func set_click_clip_right(local_x: float) -> void:
	"""Limita el área de click a 'local_x' px desde el borde izquierdo de
	esta carta (coordenadas locales, antes de escala/rotación) — pasar -1.0
	para quitar el recorte. Deliberadamente NO toca `size`/`custom_minimum_
	size`: el arte (CardBase/CardArt) sigue anclado al rect completo, solo
	cambia qué porción responde a gui_input."""
	_click_clip_right = local_x


func _has_point(point: Vector2) -> bool:
	"""Override del hit-test nativo de Control (Godot llama esto ANTES de
	despachar gui_input) — si el punto cae en la porción recortada,
	devuelve false y Godot sigue buscando detrás de esta carta en vez de
	consumir el click acá, dejando que la carta realmente visible en ese
	punto (la que se dibujó encima) lo reciba."""
	# En el campo de juego o zonas de mesa, las cartas NUNCA deben recortarse:
	if current_zone in [Constants.Zone.LINEA_DEFENSA, Constants.Zone.LINEA_ATAQUE, Constants.Zone.LINEA_APOYO]:
		return Rect2(Vector2.ZERO, size).has_point(point)
	if _click_clip_right >= 0.0 and point.x > _click_clip_right:
		return false
	return Rect2(Vector2.ZERO, size).has_point(point)


# =============================================================================
# INICIALIZACIÓN
# =============================================================================
func _ready() -> void:
	# Inicializar módulos extraídos
	_interaction = CardInteraction.new()
	_interaction.setup(self)
	_animations = CardAnimations.new()
	_animations.setup(self)
	_trigger_runtime = CardTriggerRuntime.new()
	_trigger_runtime.setup(self)
	_badges = CardBadges.new()
	_badges.setup(self)
	_image_loader = CardImageLoader.new()
	_image_loader.setup(self)

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

	_badges._create_activatable_glow()
	_badges._create_strength_badge()
	_badges._create_cost_badge()
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
		_image_loader._apply_pending_data()  # ya llama _load_card_image() internamente


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
	_image_loader._disconnect_image_signal()
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
	# Invalidar el cache SIEMPRE que una carta sale de juego de verdad, no
	# solo cuando ELLA MISMA era fuente de un modificador (2026-09-02, bug
	# reportado por el usuario: Manuel Bulnes — 'Gana 1 de Fuerza por cada
	# Arma que controles', un valor DINÁMICO recalculado con un Callable —
	# seguía mostrando el bono aunque ya no quedara ningún Arma en juego).
	# remove_modifiers_from_source() de arriba solo invalida el cache si
	# ESTA carta tenía modificadores propios registrados; un Arma sin
	# habilidad propia (sin 'El portador gana...') no tiene ninguno, así
	# que destruirla nunca disparaba la invalidación — el valor de Manuel
	# Bulnes quedaba pegado al último cálculo, sin importar cuántas Armas
	# quedaran de verdad en el tablero.
	if is_queued_for_deletion() and ContinuousEffectManager.has_method("_invalidate_cache"):
		ContinuousEffectManager._invalidate_cache()
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
## Wrappers públicos (implementación en CardBadges.gd) — muchos managers
## llaman refresh_strength_badge()/refresh_cost_badge()/set_activatable()
## directo sobre la carta cada vez que un modificador continuo puede haber
## cambiado el valor mostrado.
func refresh_strength_badge(source_override: Node = null) -> void:
	_badges.refresh_strength_badge(source_override)


func refresh_cost_badge(source_override: Node = null) -> void:
	_badges.refresh_cost_badge(source_override)


func set_activatable(value: bool) -> void:
	_badges.set_activatable(value)


# ANIMACIONES (implementación en CardAnimations.gd)
func move_to(target_pos: Vector2, duration: float = 0.3) -> void:
	_animations.move_to(target_pos, duration)


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
	if zone != Constants.Zone.MANO:
		set_click_clip_right(-1.0)

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
## Wrappers públicos (implementación en CardTriggerRuntime.gd) — TriggerSystem/
## ActionModule/ConvertAndMiscResolver llaman varios de estos directo sobre
## la carta.
func _connect_trigger_listeners() -> void:
	_trigger_runtime._connect_trigger_listeners()


func parse_triggers_from_ability() -> void:
	_trigger_runtime.parse_triggers_from_ability()


func is_in_play() -> bool:
	return _trigger_runtime.is_in_play()


func has_trigger(trigger_type: String) -> bool:
	return _trigger_runtime.has_trigger(trigger_type)


func _check_and_activate_trigger(trigger_type: String, event_data: Dictionary) -> void:
	_trigger_runtime._check_and_activate_trigger(trigger_type, event_data)


func _trigger_conditions_met(trigger_type: String, event_data: Dictionary) -> bool:
	return _trigger_runtime._trigger_conditions_met(trigger_type, event_data)


func register_effect_handler(trigger_type: String, handler: Callable) -> void:
	_trigger_runtime.register_effect_handler(trigger_type, handler)


func _on_trigger_event(trigger_type: String, event_data: Dictionary) -> Dictionary:
	return await _trigger_runtime._on_trigger_event(trigger_type, event_data)


func on_entered_play() -> void:
	_trigger_runtime.on_entered_play()


func on_left_play() -> void:
	_trigger_runtime.on_left_play()
