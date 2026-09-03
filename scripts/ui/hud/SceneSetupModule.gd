extends Node
class_name SceneSetupModule
## SceneSetupModule — Setup inicial de escena: estilos, menú de pausa, zonas de drop, etc.
## Se instancia como hijo de Main en _ready().

const DropZoneScript = preload("res://scripts/ui/DropZone.gd")
const OpponentFanScript = preload("res://scripts/ui/OpponentFan.gd")

var _main: Node = null
var pause_menu: CanvasLayer = null
var is_paused: bool = false


func setup(main: Node) -> void:
	_main = main
	_setup_styles()
	_setup_card_backs()
	_create_pause_menu()
	_setup_opponent_fan()
	_setup_drop_zones()


# =============================================================================
# ESTILOS
# =============================================================================
func _setup_styles() -> void:
	var topbar_style = StyleBoxFlat.new()
	topbar_style.bg_color = Color(0.12, 0.14, 0.18, 0.9)
	topbar_style.border_color = Color(0.3, 0.35, 0.4)
	topbar_style.border_width_bottom = 2
	_main.get_node("TopBar").add_theme_stylebox_override("panel", topbar_style)

	var debug_style = StyleBoxFlat.new()
	debug_style.bg_color = Color(0, 0, 0, 0.7)
	debug_style.set_corner_radius_all(8)
	_main.get_node("UI/DebugPanel").add_theme_stylebox_override("panel", debug_style)

	var mulligan_keep_style = StyleBoxFlat.new()
	mulligan_keep_style.bg_color = Color(0.2, 0.5, 0.3, 1)
	mulligan_keep_style.set_corner_radius_all(8)
	_main.keep_hand_button.add_theme_stylebox_override("normal", mulligan_keep_style)

	var mulligan_keep_hover = StyleBoxFlat.new()
	mulligan_keep_hover.bg_color = Color(0.25, 0.6, 0.35, 1)
	mulligan_keep_hover.set_corner_radius_all(8)
	_main.keep_hand_button.add_theme_stylebox_override("hover", mulligan_keep_hover)

	var mulligan_btn_style = StyleBoxFlat.new()
	mulligan_btn_style.bg_color = Color(0.5, 0.35, 0.2, 1)
	mulligan_btn_style.set_corner_radius_all(8)
	_main.mulligan_button.add_theme_stylebox_override("normal", mulligan_btn_style)

	var mulligan_btn_hover = StyleBoxFlat.new()
	mulligan_btn_hover.bg_color = Color(0.6, 0.4, 0.25, 1)
	mulligan_btn_hover.set_corner_radius_all(8)
	_main.mulligan_button.add_theme_stylebox_override("hover", mulligan_btn_hover)


func _setup_card_backs() -> void:
	var game_settings = get_node_or_null("/root/GameSettings")
	if not game_settings:
		return
	var player_dorso = _main.get_node_or_null("GameBoard/PlayerArea/PlayerCastillo/DorsoImage")
	if player_dorso:
		var tex = game_settings.get_card_back_texture(0)
		if tex:
			player_dorso.texture = tex
	var opponent_dorso = _main.get_node_or_null("GameBoard/OpponentArea/OpponentCastillo/DorsoImage")
	if opponent_dorso:
		var tex = game_settings.get_card_back_texture(1)
		if tex:
			opponent_dorso.texture = tex
	if not game_settings.card_back_changed.is_connected(_on_card_back_changed):
		game_settings.card_back_changed.connect(_on_card_back_changed)


func _on_card_back_changed(_back_id: String) -> void:
	_setup_card_backs()


# =============================================================================
# MENÚ DE PAUSA
# =============================================================================
func _create_pause_menu() -> void:
	pause_menu = CanvasLayer.new()
	pause_menu.layer = 100
	pause_menu.visible = false
	pause_menu.process_mode = Node.PROCESS_MODE_ALWAYS
	_main.add_child(pause_menu)

	var blur_bg = ColorRect.new()
	blur_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	blur_bg.color = Color(0, 0, 0, 0.7)
	blur_bg.name = "BlurBackground"
	pause_menu.add_child(blur_bg)

	var panel = Panel.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -200
	panel.offset_top = -175
	panel.offset_right = 200
	panel.offset_bottom = 175
	panel.name = "PausePanel"
	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.1, 0.1, 0.15, 0.95)
	panel_style.border_color = Color(0.8, 0.65, 0.3, 1)
	panel_style.border_width_bottom = 3
	panel_style.border_width_top = 3
	panel_style.border_width_left = 3
	panel_style.border_width_right = 3
	panel_style.corner_radius_top_left = 12
	panel_style.corner_radius_top_right = 12
	panel_style.corner_radius_bottom_left = 12
	panel_style.corner_radius_bottom_right = 12
	panel.add_theme_stylebox_override("panel", panel_style)
	pause_menu.add_child(panel)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 25; vbox.offset_top = 25
	vbox.offset_right = -25; vbox.offset_bottom = -25
	vbox.add_theme_constant_override("separation", 15)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(vbox)

	var title = Label.new()
	title.text = "PAUSA"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", Color(1, 0.9, 0.6, 1))
	vbox.add_child(title)

	var btn_style = StyleBoxFlat.new()
	btn_style.bg_color = Color(0.15, 0.12, 0.2, 0.9)
	btn_style.border_color = Color(0.8, 0.65, 0.3, 1)
	btn_style.border_width_bottom = 2; btn_style.border_width_top = 2
	btn_style.border_width_left = 2; btn_style.border_width_right = 2
	btn_style.corner_radius_top_left = 8; btn_style.corner_radius_top_right = 8
	btn_style.corner_radius_bottom_left = 8; btn_style.corner_radius_bottom_right = 8

	for btn_info in [
		["CONTINUAR", _on_pause_continue, Color(1, 0.95, 0.8, 1)],
		["VOLVER AL INICIO", _on_pause_main_menu, Color(1, 0.95, 0.8, 1)],
		["SALIR DEL JUEGO", _on_pause_exit, Color(1, 0.7, 0.7, 1)],
	]:
		var btn = Button.new()
		btn.text = btn_info[0]
		btn.custom_minimum_size = Vector2(300, 55)
		btn.add_theme_font_size_override("font_size", 22)
		btn.add_theme_color_override("font_color", btn_info[2])
		btn.add_theme_stylebox_override("normal", btn_style.duplicate())
		btn.pressed.connect(btn_info[1])
		vbox.add_child(btn)


func toggle_pause_menu() -> void:
	is_paused = not is_paused
	pause_menu.visible = is_paused
	get_tree().paused = is_paused


func _on_pause_continue() -> void:
	toggle_pause_menu()


func _on_pause_main_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/menu/MainMenu.tscn")


func _on_pause_exit() -> void:
	get_tree().quit()


# =============================================================================
# ABANICO DEL OPONENTE Y ZONAS DE DROP
# =============================================================================
func _setup_opponent_fan() -> void:
	var opponent_area = _main.get_node("GameBoard/OpponentArea")
	_main._opponent_fan = OpponentFanScript.new()
	_main._opponent_fan.name = "OpponentFan"
	opponent_area.add_child(_main._opponent_fan)
	_main._opponent_fan.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_main._opponent_fan.offset_bottom = 148
	print("[SceneSetup] OpponentFan creado (size: %s)" % _main._opponent_fan.size)


func _setup_drop_zones() -> void:
	var field_drop = DropZoneScript.new()
	field_drop.name = "PlayerFieldDropZone"
	field_drop.zone_name = "Campo de Batalla"
	field_drop.zone_type = Constants.Zone.LINEA_DEFENSA
	field_drop.player_id = 0
	field_drop.highlight_color = Color(0.2, 0.5, 0.2, 0.25)
	field_drop.set_accepts_types([
		Constants.CardType.ALIADO, Constants.CardType.ARMA,
		Constants.CardType.TALISMAN, Constants.CardType.TOTEM
	])
	field_drop.set_anchors_preset(Control.PRESET_CENTER)
	field_drop.offset_left = -400; field_drop.offset_top = -120
	field_drop.offset_right = 400; field_drop.offset_bottom = 120
	_main.game_board.add_child(field_drop)

	var gold_drop = DropZoneScript.new()
	gold_drop.name = "GoldReserveDropZone"
	gold_drop.zone_name = "Reserva de Oro"
	gold_drop.zone_type = Constants.Zone.RESERVA_ORO
	gold_drop.player_id = 0
	gold_drop.highlight_color = Color(0.6, 0.5, 0.1, 0.25)
	gold_drop.set_accepts_types([Constants.CardType.ORO])
	gold_drop.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	gold_drop.offset_left = 10; gold_drop.offset_top = -240
	gold_drop.offset_right = 360; gold_drop.offset_bottom = -130
	_main.game_board.add_child(gold_drop)

	var battle_drop = DropZoneScript.new()
	battle_drop.name = "BattleZoneDropZone"
	battle_drop.zone_name = "Zona de Batalla"
	battle_drop.zone_type = Constants.Zone.LINEA_ATAQUE
	battle_drop.player_id = 0
	battle_drop.highlight_color = Color(0.85, 0.35, 0.1, 0.22)
	battle_drop.runic_glow_color = Color(1.0, 0.55, 0.1, 0.8)
	battle_drop.set_accepts_types([Constants.CardType.ALIADO])
	battle_drop.set_anchors_preset(Control.PRESET_CENTER)
	battle_drop.offset_left = -350; battle_drop.offset_top = -48
	battle_drop.offset_right = 350; battle_drop.offset_bottom = 48
	_main.game_board.add_child(battle_drop)

	print("[SceneSetup] Zonas de drop configuradas")
