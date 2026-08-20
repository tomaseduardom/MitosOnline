extends Control
## MainMenu - Pantalla de inicio del juego

# =============================================================================
# REFERENCIAS UI
# =============================================================================
@onready var play_button: Button = $VBoxContainer/PlayButton
@onready var decks_button: Button = $VBoxContainer/DecksButton
@onready var backs_button: Button = $VBoxContainer/BacksButton
@onready var test_button: Button = $VBoxContainer/TestButton
@onready var exit_button: Button = $VBoxContainer/ExitButton


func _ready() -> void:
	# Conectar botones
	play_button.pressed.connect(_on_play_pressed)
	decks_button.pressed.connect(_on_decks_pressed)
	backs_button.pressed.connect(_on_backs_pressed)
	test_button.pressed.connect(_on_test_pressed)
	exit_button.pressed.connect(_on_exit_pressed)

	# Focus inicial en Play
	play_button.grab_focus()


func _on_play_pressed() -> void:
	"""Inicia el juego"""
	print("[MainMenu] Iniciando juego...")
	get_tree().change_scene_to_file("res://scenes/game/Main.tscn")


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
