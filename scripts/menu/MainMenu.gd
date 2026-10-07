extends Control
## MainMenu - Pantalla de inicio del juego con temática de fantasía medieval
## Mitos y Leyendas: Arena de Leyendas

# =============================================================================
# REFERENCIAS UI
# =============================================================================
@onready var play_button: Button = $VBoxContainer/PlayButton
@onready var shadowforge_button: Button = $VBoxContainer/ShadowForgeButton
@onready var decks_button: Button = $VBoxContainer/DecksButton
@onready var backs_button: Button = $VBoxContainer/BacksButton
@onready var exit_button: Button = $VBoxContainer/ExitButton


func _ready() -> void:
	# Conectar botones y aplicar estilos interactivos
	var buttons = [play_button, shadowforge_button, decks_button, backs_button, exit_button]
	for btn in buttons:
		if btn:
			btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			_setup_button_hover(btn)

	play_button.pressed.connect(_on_play_pressed)
	shadowforge_button.pressed.connect(_on_shadowforge_pressed)
	decks_button.pressed.connect(_on_decks_pressed)
	backs_button.pressed.connect(_on_backs_pressed)
	exit_button.pressed.connect(_on_exit_pressed)

	# 2026-09-22: el botón muestra si ya hay una sesión de ShadowForge
	# guardada — no hace falta abrir la pantalla solo para chequearlo.
	shadowforge_button.text = "SHADOWFORGE (conectado)" if ExternalApiClient.is_authenticated() else "SHADOWFORGE"

	# Focus inicial en Play
	play_button.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			var overlay = get_node_or_null("PlayModeSelection")
			if overlay:
				if overlay.has_meta("close_action"):
					var close_cb: Callable = overlay.get_meta("close_action")
					close_cb.call()
				else:
					overlay.queue_free()
					play_button.grab_focus()
				get_viewport().set_input_as_handled()


func _setup_button_hover(btn: Button) -> void:
	btn.mouse_entered.connect(func():
		var tw = btn.create_tween()
		tw.tween_property(btn, "modulate", Color(1.15, 1.15, 1.15, 1.0), 0.12)
	)
	btn.mouse_exited.connect(func():
		var tw = btn.create_tween()
		tw.tween_property(btn, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.12)
	)


func _on_play_pressed() -> void:
	_open_play_mode_popup()


func _open_play_mode_popup() -> void:
	if has_node("PlayModeSelection"):
		return

	var tex_header = load("res://assets/ui/menu/play_mode/header_title.png")
	var tex_card_bot = load("res://assets/ui/menu/play_mode/card_bot.png")
	var tex_card_online = load("res://assets/ui/menu/play_mode/card_online.png")
	var tex_btn_bot = load("res://assets/ui/menu/play_mode/btn_bot_plaque.png")
	var tex_btn_bot_hover = load("res://assets/ui/menu/play_mode/btn_bot_plaque_hover.png")
	var tex_btn_online = load("res://assets/ui/menu/play_mode/btn_online_plaque.png")
	var tex_btn_online_hover = load("res://assets/ui/menu/play_mode/btn_online_plaque_hover.png")
	var tex_btn_back = load("res://assets/ui/menu/play_mode/btn_back.png")
	var tex_btn_back_hover = load("res://assets/ui/menu/play_mode/btn_back_hover.png")

	var overlay := Control.new()
	overlay.name = "PlayModeSelection"
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)

	# Fondo oscuro cinematográfico con fade-in
	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.01, 0.01, 0.03, 0.88)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(backdrop)

	var title_container = get_node_or_null("TitleContainer")
	var menu_vbox = get_node_or_null("VBoxContainer")
	if title_container:
		var tw_t := create_tween()
		tw_t.tween_property(title_container, "modulate:a", 0.0, 0.16)
	if menu_vbox:
		var tw_v := create_tween()
		tw_v.tween_property(menu_vbox, "modulate:a", 0.0, 0.16)
		menu_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE

	overlay.modulate.a = 0.0
	var fade_tw := overlay.create_tween()
	fade_tw.tween_property(overlay, "modulate:a", 1.0, 0.20).set_ease(Tween.EASE_OUT)

	var close_action = func():
		var close_tw := overlay.create_tween()
		close_tw.tween_property(overlay, "modulate:a", 0.0, 0.16).set_ease(Tween.EASE_IN)
		if is_instance_valid(title_container):
			var tw_t2 := create_tween()
			tw_t2.tween_property(title_container, "modulate:a", 1.0, 0.20)
		if is_instance_valid(menu_vbox):
			menu_vbox.mouse_filter = Control.MOUSE_FILTER_STOP
			var tw_v2 := create_tween()
			tw_v2.tween_property(menu_vbox, "modulate:a", 1.0, 0.20)
		close_tw.tween_callback(func():
			if is_instance_valid(overlay):
				overlay.queue_free()
			play_button.grab_focus()
		)

	overlay.set_meta("close_action", close_action)

	backdrop.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			close_action.call()
	)

	# Contenedor central (Vertical)
	var center_box := VBoxContainer.new()
	center_box.set_anchors_preset(Control.PRESET_CENTER)
	center_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	center_box.grow_vertical = Control.GROW_DIRECTION_BOTH
	center_box.add_theme_constant_override("separation", 24)
	overlay.add_child(center_box)

	# 1. Encabezado "MODO DE JUEGO"
	var header_rect := TextureRect.new()
	header_rect.texture = tex_header
	header_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	header_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	header_rect.custom_minimum_size = Vector2(480, 117)
	header_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	center_box.add_child(header_rect)

	# 2. Fila con las dos tarjetas heroicas
	var cards_row := HBoxContainer.new()
	cards_row.add_theme_constant_override("separation", 36)
	cards_row.alignment = BoxContainer.ALIGNMENT_CENTER
	center_box.add_child(cards_row)

	var card_size := Vector2(336, 492)

	# --- Tarjeta CONTRA EL BOT ---
	var bot_action = func():
		overlay.queue_free()
		print("[MainMenu] Iniciando juego contra el bot...")
		get_tree().change_scene_to_file("res://scenes/game/Main.tscn")

	var card_bot_node := _build_interactive_mode_card(
		tex_card_bot,
		tex_btn_bot,
		tex_btn_bot_hover,
		card_size,
		bot_action
	)
	cards_row.add_child(card_bot_node)

	# --- Tarjeta JUGAR ONLINE ---
	var online_action = func():
		overlay.queue_free()
		print("[MainMenu] Abriendo Jugar Online...")
		get_tree().change_scene_to_file("res://scenes/menu/OnlineConnect.tscn")

	var card_online_node := _build_interactive_mode_card(
		tex_card_online,
		tex_btn_online,
		tex_btn_online_hover,
		card_size,
		online_action
	)
	cards_row.add_child(card_online_node)

	# 3. Botón inferior VOLVER AL MENÚ [ESC]
	var footer_box := HBoxContainer.new()
	footer_box.alignment = BoxContainer.ALIGNMENT_CENTER
	center_box.add_child(footer_box)

	var back_btn := TextureButton.new()
	back_btn.texture_normal = tex_btn_back
	back_btn.texture_hover = tex_btn_back_hover
	back_btn.texture_focused = tex_btn_back_hover
	back_btn.ignore_texture_size = true
	back_btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	back_btn.custom_minimum_size = Vector2(260, 64)
	back_btn.pivot_offset = Vector2(130, 32)
	back_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	back_btn.mouse_entered.connect(func():
		var tw := back_btn.create_tween()
		tw.tween_property(back_btn, "scale", Vector2(1.04, 1.04), 0.12).set_ease(Tween.EASE_OUT)
	)
	back_btn.mouse_exited.connect(func():
		var tw := back_btn.create_tween()
		tw.tween_property(back_btn, "scale", Vector2.ONE, 0.12).set_ease(Tween.EASE_OUT)
	)
	back_btn.pressed.connect(close_action)
	footer_box.add_child(back_btn)

	# Foco inicial
	var bot_btn_sub = card_bot_node.get_node_or_null("Btn")
	if bot_btn_sub:
		bot_btn_sub.grab_focus()


func _build_interactive_mode_card(
	card_tex: Texture2D,
	btn_tex: Texture2D,
	btn_hover_tex: Texture2D,
	target_size: Vector2,
	on_select: Callable
) -> Control:
	var container := Control.new()
	container.custom_minimum_size = target_size
	container.pivot_offset = target_size / 2.0
	container.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	# Imagen de la carta base (marco + arte + textos en su diseño auténtico)
	var card_rect := TextureRect.new()
	card_rect.texture = card_tex
	card_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	card_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	card_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	card_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_child(card_rect)

	# Botón interactivo sobre la placa inferior (proporción 28..440 en X, 532..648 en Y de 468x686)
	var btn_x := target_size.x * (28.0 / 468.0)
	var btn_y := target_size.y * (532.0 / 686.0)
	var btn_w := target_size.x * (412.0 / 468.0)
	var btn_h := target_size.y * (116.0 / 686.0)

	var action_btn := TextureButton.new()
	action_btn.name = "Btn"
	action_btn.texture_normal = btn_tex
	action_btn.texture_hover = btn_hover_tex
	action_btn.texture_focused = btn_hover_tex
	action_btn.ignore_texture_size = true
	action_btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	action_btn.position = Vector2(btn_x, btn_y)
	action_btn.size = Vector2(btn_w, btn_h)
	action_btn.pivot_offset = Vector2(btn_w / 2.0, btn_h / 2.0)
	action_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	container.add_child(action_btn)

	# Glow pulsante / feedback visual sincronizado entre la tarjeta completa y el botón
	var set_highlight = func(active: bool):
		var tw := container.create_tween()
		tw.set_parallel(true)
		if active:
			tw.tween_property(container, "scale", Vector2(1.028, 1.028), 0.14).set_ease(Tween.EASE_OUT)
			tw.tween_property(action_btn, "scale", Vector2(1.035, 1.035), 0.14).set_ease(Tween.EASE_OUT)
			action_btn.texture_normal = btn_hover_tex
		else:
			tw.tween_property(container, "scale", Vector2.ONE, 0.14).set_ease(Tween.EASE_OUT)
			tw.tween_property(action_btn, "scale", Vector2.ONE, 0.14).set_ease(Tween.EASE_OUT)
			action_btn.texture_normal = btn_tex

	container.mouse_entered.connect(func(): set_highlight.call(true))
	container.mouse_exited.connect(func(): set_highlight.call(false))
	action_btn.mouse_entered.connect(func(): set_highlight.call(true))
	action_btn.mouse_exited.connect(func(): set_highlight.call(false))

	# Clic tanto en el botón como en cualquier parte de la tarjeta activa la selección
	action_btn.pressed.connect(on_select)
	container.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			on_select.call()
	)

	return container


func _on_shadowforge_pressed() -> void:
	"""Abre la pantalla de login real de ShadowForge (2026-09-22, a pedido
	del usuario: conectar tu cuenta para ver tus mazos privados en el
	selector, en vez de editar un archivo a mano)."""
	print("[MainMenu] Abriendo ShadowForge...")
	get_tree().change_scene_to_file("res://scenes/menu/ShadowForgeLogin.tscn")


func _on_decks_pressed() -> void:
	"""Abre el gestor de mazos"""
	print("[MainMenu] Abriendo mazos...")
	get_tree().change_scene_to_file("res://scenes/menu/DeckManager.tscn")


func _on_backs_pressed() -> void:
	"""Abre el selector de dorsos"""
	print("[MainMenu] Abriendo dorsos...")
	get_tree().change_scene_to_file("res://scenes/menu/BackSelector.tscn")


func _on_exit_pressed() -> void:
	"""Sale del juego"""
	print("[MainMenu] Saliendo...")
	get_tree().quit()
