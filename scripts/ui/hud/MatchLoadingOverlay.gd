extends Node
## MatchLoadingOverlay — Pantalla de transición y carga atmosférica estilo fantasía.
## Se muestra durante la carga de mazos, inicio de partida y preparación del campo de batalla.

const GOLD := Color(0.83, 0.69, 0.22, 1.0)
const GOLD_BRIGHT := Color(1.0, 0.88, 0.45, 1.0)

const FONT_TITLE := preload("res://assets/fonts/Cinzel-Bold.ttf")
const FONT_MEDIEVAL := preload("res://assets/fonts/Marcellus-Regular.ttf")

var _canvas_layer: CanvasLayer = null
var _overlay: Control = null
var _spinner: Control = null
var _title_label: Label = null
var _subtitle_label: Label = null
var _progress_bar: ProgressBar = null
var _tween_spinner: Tween = null
var _tween_fade: Tween = null

const TIPS := [
	"Barajando los grimorios...",
	"Convocando las fuerzas mitológicas...",
	"Alineando las líneas de Ley...",
	"Preparando el campo de batalla...",
	"Consagrando la Reserva de Oro..."
]


func show_loading(parent: Node, title_text: String = "CARGANDO PARTIDA", initial_tip: String = "Preparando el campo de batalla...") -> void:
	"""Muestra la pantalla de carga con fade-in."""
	if _overlay and is_instance_valid(_overlay):
		return

	_canvas_layer = CanvasLayer.new()
	_canvas_layer.layer = 85
	parent.add_child(_canvas_layer)

	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.modulate = Color(1, 1, 1, 0)
	_canvas_layer.add_child(_overlay)

	# 1. Fondo oscuro con viñeta ambiental
	var bg = ColorRect.new()
	bg.color = Color(0.04, 0.03, 0.05, 0.94)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(bg)

	# 2. Contenedor central
	var center = VBoxContainer.new()
	center.set_anchor(SIDE_LEFT, 0.5)
	center.set_anchor(SIDE_TOP, 0.5)
	center.set_anchor(SIDE_RIGHT, 0.5)
	center.set_anchor(SIDE_BOTTOM, 0.5)
	center.set_offset(SIDE_LEFT, -250)
	center.set_offset(SIDE_TOP, -140)
	center.set_offset(SIDE_RIGHT, 250)
	center.set_offset(SIDE_BOTTOM, 140)
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_theme_constant_override("separation", 18)
	_overlay.add_child(center)

	# 3. Spinner místico dorado
	var spinner_holder = Control.new()
	spinner_holder.custom_minimum_size = Vector2(70, 70)
	center.add_child(spinner_holder)

	_spinner = _build_mystic_spinner()
	_spinner.position = Vector2(35, 35)
	spinner_holder.add_child(_spinner)

	# Animación de rotación continua
	_tween_spinner = _spinner.create_tween().set_loops()
	_tween_spinner.tween_property(_spinner, "rotation", TAU, 1.8).from(0.0)

	# 4. Título principal
	_title_label = Label.new()
	_title_label.text = title_text
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_override("font", FONT_TITLE)
	_title_label.add_theme_font_size_override("font_size", 22)
	_title_label.add_theme_color_override("font_color", GOLD_BRIGHT)
	_title_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	_title_label.add_theme_constant_override("shadow_offset_x", 1)
	_title_label.add_theme_constant_override("shadow_offset_y", 1)
	center.add_child(_title_label)

	# 5. Barra de progreso dorada
	_progress_bar = ProgressBar.new()
	_progress_bar.custom_minimum_size = Vector2(380, 10)
	_progress_bar.max_value = 1.0
	_progress_bar.value = 0.15
	_progress_bar.show_percentage = false
	var p_bg = StyleBoxFlat.new()
	p_bg.bg_color = Color(0.1, 0.08, 0.12, 1.0)
	p_bg.set_corner_radius_all(5)
	_progress_bar.add_theme_stylebox_override("background", p_bg)
	var p_fill = StyleBoxFlat.new()
	p_fill.bg_color = GOLD
	p_fill.set_corner_radius_all(5)
	_progress_bar.add_theme_stylebox_override("fill", p_fill)
	center.add_child(_progress_bar)

	# 6. Subtítulo / Lore tip
	_subtitle_label = Label.new()
	_subtitle_label.text = initial_tip
	_subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle_label.add_theme_font_override("font", FONT_MEDIEVAL)
	_subtitle_label.add_theme_font_size_override("font_size", 14)
	_subtitle_label.add_theme_color_override("font_color", Color(0.85, 0.78, 0.70, 1.0))
	center.add_child(_subtitle_label)

	# Animación de fade-in
	_tween_fade = _overlay.create_tween()
	_tween_fade.tween_property(_overlay, "modulate:a", 1.0, 0.35).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)


func set_progress(val: float, message: String = "") -> void:
	"""Actualiza la barra de progreso y mensaje."""
	if _progress_bar:
		var tw = _progress_bar.create_tween()
		tw.tween_property(_progress_bar, "value", clampf(val, 0.0, 1.0), 0.2)
	if not message.is_empty() and _subtitle_label:
		_subtitle_label.text = message


func hide_loading(on_finish: Callable = Callable()) -> void:
	"""Oculta la pantalla de carga con fade-out suave."""
	if not _overlay or not is_instance_valid(_overlay):
		if on_finish.is_valid(): on_finish.call()
		return

	if _tween_spinner:
		_tween_spinner.kill()

	var tw = _overlay.create_tween()
	tw.tween_property(_overlay, "modulate:a", 0.0, 0.4).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.finished.connect(func():
		if _canvas_layer and is_instance_valid(_canvas_layer):
			_canvas_layer.queue_free()
			_canvas_layer = null
			_overlay = null
		if on_finish.is_valid():
			on_finish.call()
	)


func _build_mystic_spinner() -> Control:
	var root = Control.new()
	# Círculo místico dibujado proceduralmente con runas y rayos dorados
	var drawer = Node2D.new()
	drawer.script = _SpinnerDrawerScript.new()
	root.add_child(drawer)
	return root


# Script interno para dibujar el spinner místico
class _SpinnerDrawerScript extends GDScript:
	func _init():
		source_code = """
extends Node2D

func _draw() -> void:
	var gold = Color(1.0, 0.86, 0.42, 0.95)
	var dim = Color(0.7, 0.55, 0.25, 0.35)
	# Anillo exterior punteado
	draw_arc(Vector2.ZERO, 28, 0, TAU, 32, dim, 2.0)
	# Arco brillante activo
	draw_arc(Vector2.ZERO, 28, -PI * 0.5, PI * 0.7, 24, gold, 3.5)
	# Runas / Rayos cardinales
	for i in range(4):
		var angle = i * (PI / 2.0)
		var p1 = Vector2.from_angle(angle) * 14.0
		var p2 = Vector2.from_angle(angle) * 23.0
		draw_line(p1, p2, gold, 2.5)
	# Núcleo brillante
	draw_circle(Vector2.ZERO, 5.0, gold)
"""
		reload()

