extends Node
class_name SceneSetupModule
## SceneSetupModule — Setup inicial de escena: estilos, menú de pausa, zonas de drop, etc.
## Se instancia como hijo de Main en _ready().

const DropZoneScript = preload("res://scripts/ui/zones/DropZone.gd")
const OpponentFanScript = preload("res://scripts/ui/hand/OpponentFan.gd")
const PauseMenuOverlayScript = preload("res://scripts/ui/hud/PauseMenuOverlay.gd")

var _main: Node = null
var pause_menu: CanvasLayer = null
var is_paused: bool:
	get:
		if pause_menu and pause_menu.has_method("is_open"):
			return pause_menu.is_open()
		return false
	set(val):
		if pause_menu and pause_menu.has_method("is_open"):
			if val != pause_menu.is_open():
				pause_menu.toggle_menu()


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
	var font_medieval = preload("res://assets/fonts/Marcellus-Regular.ttf")
	var font_bold = preload("res://assets/fonts/Cinzel-Bold.ttf")

	var topbar_style = StyleBoxEmpty.new()
	_main.get_node("TopBar").add_theme_stylebox_override("panel", topbar_style)

	var topbar_title = _main.get_node_or_null("TopBar/TurnLabel")
	if topbar_title:
		topbar_title.add_theme_font_override("font", font_medieval)
		topbar_title.add_theme_font_size_override("font_size", 16)
		topbar_title.add_theme_color_override("font_color", Color(1.0, 0.92, 0.70, 1.0))
		topbar_title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
		topbar_title.add_theme_constant_override("shadow_offset_x", 1)
		topbar_title.add_theme_constant_override("shadow_offset_y", 2)

	var debug_style = StyleBoxFlat.new()
	debug_style.bg_color = Color(0, 0, 0, 0.7)
	debug_style.set_corner_radius_all(8)
	var debug_panel = _main.get_node_or_null("UI/DebugPanel")
	if debug_panel:
		debug_panel.add_theme_stylebox_override("panel", debug_style)
		debug_panel.visible = false

	var mulligan_keep_style = StyleBoxFlat.new()
	mulligan_keep_style.bg_color = Color(0.06, 0.22, 0.12, 0.95)
	mulligan_keep_style.border_color = Color(0.40, 0.85, 0.50, 0.90)
	mulligan_keep_style.set_border_width_all(2)
	mulligan_keep_style.set_corner_radius_all(8)
	mulligan_keep_style.shadow_color = Color(0, 0, 0, 0.6)
	mulligan_keep_style.shadow_size = 8
	_main.keep_hand_button.add_theme_stylebox_override("normal", mulligan_keep_style)
	_main.keep_hand_button.add_theme_font_override("font", font_bold)
	_main.keep_hand_button.add_theme_font_size_override("font_size", 15)
	_main.keep_hand_button.add_theme_color_override("font_color", Color(0.90, 1.0, 0.90, 1.0))

	var mulligan_keep_hover = StyleBoxFlat.new()
	mulligan_keep_hover.bg_color = Color(0.10, 0.32, 0.18, 1.0)
	mulligan_keep_hover.border_color = Color(0.55, 1.0, 0.65, 1.0)
	mulligan_keep_hover.set_border_width_all(2)
	mulligan_keep_hover.set_corner_radius_all(8)
	mulligan_keep_hover.shadow_color = Color(0, 0, 0, 0.7)
	mulligan_keep_hover.shadow_size = 10
	_main.keep_hand_button.add_theme_stylebox_override("hover", mulligan_keep_hover)
	_main.keep_hand_button.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0, 1.0))

	var mulligan_btn_style = StyleBoxFlat.new()
	mulligan_btn_style.bg_color = Color(0.22, 0.08, 0.08, 0.95)
	mulligan_btn_style.border_color = Color(0.85, 0.35, 0.35, 0.90)
	mulligan_btn_style.set_border_width_all(2)
	mulligan_btn_style.set_corner_radius_all(8)
	mulligan_btn_style.shadow_color = Color(0, 0, 0, 0.6)
	mulligan_btn_style.shadow_size = 8
	_main.mulligan_button.add_theme_stylebox_override("normal", mulligan_btn_style)
	_main.mulligan_button.add_theme_font_override("font", font_bold)
	_main.mulligan_button.add_theme_font_size_override("font_size", 15)
	_main.mulligan_button.add_theme_color_override("font_color", Color(1.0, 0.88, 0.88, 1.0))

	var mulligan_btn_hover = StyleBoxFlat.new()
	mulligan_btn_hover.bg_color = Color(0.32, 0.12, 0.12, 1.0)
	mulligan_btn_hover.border_color = Color(1.0, 0.50, 0.50, 1.0)
	mulligan_btn_hover.set_border_width_all(2)
	mulligan_btn_hover.set_corner_radius_all(8)
	mulligan_btn_hover.shadow_color = Color(0, 0, 0, 0.7)
	mulligan_btn_hover.shadow_size = 10
	_main.mulligan_button.add_theme_stylebox_override("hover", mulligan_btn_hover)
	_main.mulligan_button.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0, 1.0))


func _setup_card_backs() -> void:
	var player_dorso = _main.get_node_or_null("GameBoard/PlayerArea/PlayerCastillo/DorsoImage")
	if player_dorso:
		var tex = GameSettings.get_card_back_texture(0)
		if tex:
			player_dorso.texture = tex
	var opponent_dorso = _main.get_node_or_null("GameBoard/OpponentArea/OpponentCastillo/DorsoImage")
	if opponent_dorso:
		var tex = GameSettings.get_card_back_texture(1)
		if tex:
			opponent_dorso.texture = tex
		opponent_dorso.pivot_offset = Vector2(50.0, 70.0)
		opponent_dorso.rotation_degrees = 180.0
	if not GameSettings.card_back_changed.is_connected(_on_card_back_changed):
		GameSettings.card_back_changed.connect(_on_card_back_changed)


func _on_card_back_changed(_back_id: String) -> void:
	_setup_card_backs()


# =============================================================================
# MENÚ DE PAUSA
# =============================================================================
func _create_pause_menu() -> void:
	pause_menu = PauseMenuOverlayScript.new()
	pause_menu.name = "PauseMenuOverlay"
	_main.add_child(pause_menu)
	pause_menu.setup(_main)
	pause_menu.resume_requested.connect(_on_pause_continue)


func toggle_pause_menu() -> void:
	if pause_menu and pause_menu.has_method("toggle_menu"):
		pause_menu.toggle_menu()


func _on_pause_continue() -> void:
	# Manejado internamente por PauseMenuOverlay (resume_requested)
	pass


func _on_pause_main_menu() -> void:
	if pause_menu and pause_menu.has_method("_execute_main_menu"):
		pause_menu._execute_main_menu()
	else:
		get_tree().paused = false
		get_tree().change_scene_to_file("res://scenes/menu/MainMenu.tscn")


func _on_pause_exit() -> void:
	get_tree().quit()


# =============================================================================
# ABANICO DEL OPONENTE Y ZONAS DE DROP
# =============================================================================
func _setup_opponent_fan() -> void:
	_main._opponent_fan = OpponentFanScript.new()
	_main._opponent_fan.name = "OpponentFan"
	_main.game_board.add_child(_main._opponent_fan)
	_main._opponent_fan.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_main._opponent_fan.offset_bottom = 120
	print("[SceneSetup] OpponentFan creado pegado al borde superior (size: %s)" % _main._opponent_fan.size)


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
	field_drop.offset_left = -620; field_drop.offset_top = -120
	field_drop.offset_right = 620; field_drop.offset_bottom = 120
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
	battle_drop.offset_left = -620; battle_drop.offset_top = -80
	battle_drop.offset_right = 620; battle_drop.offset_bottom = 80
	_main.game_board.add_child(battle_drop)

	print("[SceneSetup] Zonas de drop configuradas")
