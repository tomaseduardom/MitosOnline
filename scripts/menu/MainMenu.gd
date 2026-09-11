extends Control
## MainMenu - Pantalla de inicio del juego con temática de fantasía medieval
## Mitos y Leyendas: Arena de Leyendas

# =============================================================================
# REFERENCIAS UI
# =============================================================================
@onready var play_button: Button = $VBoxContainer/PlayButton
@onready var online_button: Button = $VBoxContainer/OnlineButton
@onready var decks_button: Button = $VBoxContainer/DecksButton
@onready var backs_button: Button = $VBoxContainer/BacksButton
@onready var test_button: Button = $VBoxContainer/TestButton
@onready var exit_button: Button = $VBoxContainer/ExitButton


func _ready() -> void:
	# Conectar botones y aplicar estilos interactivos
	var buttons = [play_button, online_button, decks_button, backs_button, test_button, exit_button]
	for btn in buttons:
		if btn:
			btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			_setup_button_hover(btn)

	play_button.pressed.connect(_on_play_pressed)
	online_button.pressed.connect(_on_online_pressed)
	decks_button.pressed.connect(_on_decks_pressed)
	backs_button.pressed.connect(_on_backs_pressed)
	test_button.pressed.connect(_on_test_pressed)
	exit_button.pressed.connect(_on_exit_pressed)

	# Focus inicial en Play
	play_button.grab_focus()


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
	"""Inicia el juego"""
	print("[MainMenu] Iniciando juego...")
	get_tree().change_scene_to_file("res://scenes/game/Main.tscn")


func _on_online_pressed() -> void:
	"""Abre la pantalla de conexión al multiplayer remoto (crear/unirse sala)"""
	print("[MainMenu] Abriendo Jugar Online...")
	get_tree().change_scene_to_file("res://scenes/menu/OnlineConnect.tscn")


func _on_decks_pressed() -> void:
	"""Abre el gestor de mazos"""
	print("[MainMenu] Abriendo mazos...")
	get_tree().change_scene_to_file("res://scenes/menu/DeckManager.tscn")


func _on_backs_pressed() -> void:
	"""Abre el selector de dorsos"""
	print("[MainMenu] Abriendo dorsos...")
	get_tree().change_scene_to_file("res://scenes/menu/BackSelector.tscn")


func _on_test_pressed() -> void:
	print("[MainMenu] Abriendo zona de testeo...")
	get_tree().change_scene_to_file("res://scenes/test/TestScene.tscn")


func _on_exit_pressed() -> void:
	"""Sale del juego"""
	print("[MainMenu] Saliendo...")
	get_tree().quit()
