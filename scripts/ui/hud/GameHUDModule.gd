extends Node
class_name GameHUDModule
## GameHUDModule — Interfaz visual del HUD en juego: anuncio de fases y botón de acción/prioridad.

const FONT_MEDIEVAL := preload("res://assets/fonts/Cinzel-Bold.ttf")
const FONT_TITLE := preload("res://assets/fonts/Cinzel-Bold.ttf")

var _main: Node = null
var _paso_button: Button = null
var _paso_glow_tween: Tween = null
var _phase_announcer_label: Label = null
var _phase_announcer_tween: Tween = null


func setup(main: Node) -> void:
	_main = main
	_setup_phase_announcer()
	_setup_paso_button()


# =============================================================================
# ANUNCIADOR DE FASES
# =============================================================================
func _setup_phase_announcer() -> void:
	"""Crea el Label central para animar el cambio de fase."""
	_phase_announcer_label = Label.new()
	_phase_announcer_label.name = "PhaseAnnouncerLabel"
	_phase_announcer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_phase_announcer_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_phase_announcer_label.anchor_left = 0.5
	_phase_announcer_label.anchor_top = 0.5
	_phase_announcer_label.anchor_right = 0.5
	_phase_announcer_label.anchor_bottom = 0.5
	_phase_announcer_label.offset_left = -350
	_phase_announcer_label.offset_top = -45
	_phase_announcer_label.offset_right = 350
	_phase_announcer_label.offset_bottom = 45
	_phase_announcer_label.pivot_offset = Vector2(350, 45)
	_phase_announcer_label.add_theme_font_override("font", FONT_TITLE)
	_phase_announcer_label.add_theme_font_size_override("font_size", 38)
	_phase_announcer_label.add_theme_color_override("font_color", Color(1.0, 0.88, 0.45, 1.0))
	_phase_announcer_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.95))
	_phase_announcer_label.add_theme_constant_override("shadow_offset_x", 2)
	_phase_announcer_label.add_theme_constant_override("shadow_offset_y", 2)
	_phase_announcer_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_phase_announcer_label.modulate.a = 0.0
	_phase_announcer_label.z_index = 200
	_main.add_child(_phase_announcer_label)


func show_phase_announcement(phase_name: String) -> void:
	"""Anima el texto de la fase en el centro de la pantalla."""
	if not _phase_announcer_label:
		return
	if _phase_announcer_tween and _phase_announcer_tween.is_valid():
		_phase_announcer_tween.kill()

	_phase_announcer_label.text = phase_name
	_phase_announcer_label.scale = Vector2(1.2, 1.2)
	_phase_announcer_label.modulate.a = 0.0

	_phase_announcer_tween = _main.create_tween()
	_phase_announcer_tween.tween_property(_phase_announcer_label, "modulate:a", 1.0, 0.22).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	_phase_announcer_tween.parallel().tween_property(_phase_announcer_label, "scale", Vector2.ONE, 0.22).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	_phase_announcer_tween.tween_interval(1.1)
	_phase_announcer_tween.tween_property(_phase_announcer_label, "modulate:a", 0.0, 0.30).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	_phase_announcer_tween.parallel().tween_property(_phase_announcer_label, "scale", Vector2(0.9, 0.9), 0.30).set_ease(Tween.EASE_IN)


# =============================================================================
# BOTÓN DE ACCIÓN / PASO FANTASÍA
# =============================================================================
func _setup_paso_button() -> void:
	"""Crea el botón ornamental de acción a la izquierda del TurnTimer."""
	_paso_button = Button.new()
	_paso_button.text = "Pasar [P]"
	_paso_button.name = "PasoButton"
	_paso_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_paso_button.add_theme_font_override("font", FONT_MEDIEVAL)
	_paso_button.add_theme_font_size_override("font_size", 19)

	var style_normal = StyleBoxFlat.new()
	style_normal.bg_color = Color(0.08, 0.12, 0.09, 0.95)
	style_normal.border_color = Color(0.85, 0.72, 0.28, 1.0)
	style_normal.set_border_width_all(2)
	style_normal.set_corner_radius_all(10)
	style_normal.shadow_color = Color(0, 0, 0, 0.8)
	style_normal.shadow_size = 6

	var style_hover = StyleBoxFlat.new()
	style_hover.bg_color = Color(0.12, 0.20, 0.15, 1.0)
	style_hover.border_color = Color(1.0, 0.90, 0.50, 1.0)
	style_hover.set_border_width_all(2)
	style_hover.set_corner_radius_all(10)
	style_hover.shadow_color = Color(0.85, 0.72, 0.28, 0.5)
	style_hover.shadow_size = 10

	var style_pressed = StyleBoxFlat.new()
	style_pressed.bg_color = Color(0.05, 0.08, 0.06, 0.98)
	style_pressed.border_color = Color(0.70, 0.58, 0.22, 1.0)
	style_pressed.set_border_width_all(2)
	style_pressed.set_corner_radius_all(10)

	_paso_button.add_theme_stylebox_override("normal", style_normal)
	_paso_button.add_theme_stylebox_override("hover", style_hover)
	_paso_button.add_theme_stylebox_override("pressed", style_pressed)
	_paso_button.add_theme_color_override("font_color", Color(1.0, 0.95, 0.85, 1.0))
	_paso_button.add_theme_color_override("font_hover_color", Color(1.0, 0.90, 0.50, 1.0))
	_paso_button.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	_paso_button.add_theme_constant_override("shadow_offset_x", 1)
	_paso_button.add_theme_constant_override("shadow_offset_y", 1)

	# Posición: a la izquierda del TurnTimer
	_paso_button.anchor_left = 1.0
	_paso_button.anchor_top = 0.5
	_paso_button.anchor_right = 1.0
	_paso_button.anchor_bottom = 0.5
	_paso_button.offset_right = -128
	_paso_button.offset_left = -268
	_paso_button.offset_top = -27
	_paso_button.offset_bottom = 27
	_paso_button.mouse_filter = Control.MOUSE_FILTER_STOP
	_paso_button.visible = false

	_main.add_child(_paso_button)
	_paso_button.pressed.connect(func(): _main._phase_flow._on_paso_pressed())


func update_paso_button_state() -> void:
	"""Muestra/oculta el botón según si es el turno del jugador en una fase accionable."""
	if not _paso_button:
		return
	var phase = GameManager.current_phase

	# Con ventana de prioridad activa (Bloqueo, Guerra de Talismanes,
	# cualquier ventana de respuesta) quien debe actuar es quien TIENE la
	# prioridad ahora mismo, no necesariamente el dueño del turno (2026-
	# 09-03, bug reportado: 'se queda estancado en guerra de talismanes' —
	# cuando el humano defiende en el turno del oponente, DAR 5.C3 le da
	# la prioridad primero en Guerra de Talismanes, pero la visibilidad
	# dependía solo de active_player_id == 0, así que el botón nunca
	# aparecía y no había forma de pasar).
	if PriorityManager.priority_window_active:
		# 2026-09-25, bug real reportado por el usuario ("el botón de pasar
		# dice atacar aunque es para pasar"): el texto se decidía ANTES de
		# este chequeo, mirando solo la fase — pero con una ventana de
		# prioridad activa, _on_paso_pressed() SIEMPRE solo pasa prioridad
		# (PriorityManager.pass_priority()), sin importar la fase, incluso
		# si esa ventana se abrió durante tu propia Vigilia (p.ej.
		# respondiendo al 'Cuando entra en juego' de una carta). El texto
		# tiene que decir lo que el click realmente va a hacer.
		_paso_button.text = "Pasar [P]"
		_paso_button.visible = GameManager.is_game_active and PriorityManager.current_priority_player == 0
		# 2026-09-15, diagnóstico temporal a pedido del usuario (bug real:
		# "se traba en Guerra de Talismanes, no aparece ningún botón" —
		# reaparición de un síntoma ya arreglado una vez, 2026-09-03, ver
		# comentario de arriba): imprime el estado real detrás de la
		# decisión de mostrar/ocultar, para ver en qué falla esta vez.
		if Constants.VERBOSE_DIAG_LOGS:
			print("[DIAG] update_paso_button_state (con ventana activa): visible=%s is_game_active=%s priority_player=%d fase=%s" % [
				str(_paso_button.visible), str(GameManager.is_game_active), PriorityManager.current_priority_player,
				Constants.PHASE_NAMES.get(phase, "?")
			])
		return

	# 2026-09-20, bug real reportado por el usuario ("el botón de paso
	# desaparece" quedando pegado en Guerra de Talismanes): Guerra de
	# Talismanes/Bloqueo SIN ventana activa es precisamente el estado
	# "clobbereado" que _try_recover_stuck_phase_priority_window() ya sabe
	# recuperar (ver PhaseFlowController.gd, bugs documentados 2026-09-04 y
	# 2026-09-06) — pero antes de este fix el botón se ocultaba en ese
	# mismo estado (ni VIGILIA/ATAQUE/FINAL, ni is_player_turn confiable
	# mientras defiendes: active_player_id es el oponente aunque la
	# prioridad de defensor te toque a ti primero, DAR 5.C3), dejando la
	# recuperación sin ninguna forma de dispararse desde la UI. El botón
	# ahora se mantiene visible en estas 2 fases sin importar de quién sea
	# el turno; al presionarlo, PhaseFlowController._on_paso_pressed() ya
	# llama _try_recover_stuck_phase_priority_window() en esta rama — si de
	# verdad no hay nada que recuperar, esa función no hace nada y el
	# jugador ve "Sin ventana de prioridad activa" en vez de quedar sin
	# ningún botón con qué reaccionar.
	# 2026-09-13, a pedido del usuario: el botón debe reflejar QUÉ pasa al
	# presionarlo, no solo "hiciste una acción" — en Guerra de Talismanes
	# (5.3.3), pasar es lo que hace avanzar a Asignación de Daño (5.3.4)
	# cuando ambos jugadores pasan seguido, así que el botón dice "Daño" en
	# vez del genérico "¿Paso?" aquí, igual que ya decía "Atacar" en Vigilia.
	if phase == Constants.Phase.GUERRA_TALISMANES:
		_paso_button.text = "Daño [P]"
	else:
		_paso_button.text = "Atacar [P]" if phase == Constants.Phase.VIGILIA else "Pasar [P]"

	var is_player_turn = (GameManager.active_player_id == 0)
	var relevant_phase = phase in [
		Constants.Phase.VIGILIA,
		Constants.Phase.ATAQUE,
		Constants.Phase.FINAL
	]
	var recoverable_stuck_phase = phase in [
		Constants.Phase.GUERRA_TALISMANES,
		Constants.Phase.BLOQUEO
	]
	_paso_button.visible = GameManager.is_game_active and \
		((is_player_turn and relevant_phase) or recoverable_stuck_phase)
	if Constants.VERBOSE_DIAG_LOGS:
		print("[DIAG] update_paso_button_state (sin ventana activa): visible=%s is_game_active=%s is_player_turn=%s fase=%s relevant_phase=%s recoverable_stuck_phase=%s" % [
			str(_paso_button.visible), str(GameManager.is_game_active), str(is_player_turn),
			Constants.PHASE_NAMES.get(phase, "?"), str(relevant_phase), str(recoverable_stuck_phase)
		])


func hide_paso_button() -> void:
	if _paso_button:
		_paso_button.visible = false


func is_paso_button_ready() -> bool:
	"""¿El botón ¿Paso?/Atacar está visible y puede clickearse ahora? (2026-09-11,
	a pedido del usuario: atajo de teclado Q — simula el mismo click que el
	mouse, así que solo debe actuar cuando el botón real haría algo)."""
	return _paso_button != null and _paso_button.visible


func start_paso_glow() -> void:
	"""Efecto de pulso/brillo ámbar en el botón para indicar ventana de respuesta activa."""
	if not _paso_button:
		return
	if _paso_glow_tween and _paso_glow_tween.is_valid():
		_paso_glow_tween.kill()

	var style_glow = StyleBoxFlat.new()
	style_glow.bg_color = Color(0.24, 0.10, 0.06, 0.96)
	style_glow.border_color = Color(1.0, 0.65, 0.20, 1.0)
	style_glow.set_border_width_all(3)
	style_glow.set_corner_radius_all(10)
	style_glow.shadow_color = Color(1.0, 0.55, 0.15, 0.8)
	style_glow.shadow_size = 14

	_paso_button.add_theme_stylebox_override("normal", style_glow)
	_paso_button.add_theme_color_override("font_color", Color(1.0, 0.90, 0.50, 1.0))
	_paso_glow_tween = _paso_button.create_tween().set_loops()
	_paso_glow_tween.tween_property(_paso_button, "modulate", Color(1.2, 1.2, 0.9, 1.0), 0.5).set_ease(Tween.EASE_IN_OUT)
	_paso_glow_tween.tween_property(_paso_button, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.5).set_ease(Tween.EASE_IN_OUT)


func stop_paso_glow() -> void:
	"""Detiene el efecto de pulso y restaura el estilo normal del botón."""
	if _paso_glow_tween and _paso_glow_tween.is_valid():
		_paso_glow_tween.kill()
	_paso_glow_tween = null
	if not _paso_button:
		return
	_paso_button.modulate = Color.WHITE

	var style_normal = StyleBoxFlat.new()
	style_normal.bg_color = Color(0.08, 0.12, 0.09, 0.95)
	style_normal.border_color = Color(0.85, 0.72, 0.28, 1.0)
	style_normal.set_border_width_all(2)
	style_normal.set_corner_radius_all(10)
	style_normal.shadow_color = Color(0, 0, 0, 0.8)
	style_normal.shadow_size = 6

	_paso_button.add_theme_stylebox_override("normal", style_normal)
	_paso_button.add_theme_color_override("font_color", Color(1.0, 0.95, 0.85, 1.0))
