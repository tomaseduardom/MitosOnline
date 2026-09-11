extends Control
## OnlineConnect — pantalla de conexión del multiplayer remoto (Fase A,
## docs/plans/2026-09-09-multiplayer-remoto-design.md). Crea o une una sala
## contra el relay (ver NetworkClient autoload) ANTES de entrar a Main.tscn.
## Esta pantalla solo valida la conexión — el intercambio de mazo real y el
## resto del handshake (Fase A, siguiente incremento) todavía no están acá.

const DEFAULT_RELAY_URL := "ws://localhost:8080"

@onready var relay_url_edit: LineEdit = $VBoxContainer/RelayUrlEdit
@onready var create_room_button: Button = $VBoxContainer/HostSection/CreateRoomButton
@onready var room_code_label: Label = $VBoxContainer/HostSection/RoomCodeLabel
@onready var code_edit: LineEdit = $VBoxContainer/JoinSection/CodeEdit
@onready var join_room_button: Button = $VBoxContainer/JoinSection/JoinRoomButton
@onready var status_label: Label = $VBoxContainer/StatusLabel
@onready var continue_button: Button = $VBoxContainer/ContinueButton
@onready var back_button: Button = $VBoxContainer/BackButton


func _ready() -> void:
	relay_url_edit.text = DEFAULT_RELAY_URL
	room_code_label.text = ""
	continue_button.disabled = true

	create_room_button.pressed.connect(_on_create_room_pressed)
	join_room_button.pressed.connect(_on_join_room_pressed)
	continue_button.pressed.connect(_on_continue_pressed)
	back_button.pressed.connect(_on_back_pressed)

	NetworkClient.connected_to_relay.connect(_on_connected_to_relay)
	NetworkClient.connection_failed.connect(_on_connection_failed)
	NetworkClient.room_created.connect(_on_room_created)
	NetworkClient.room_joined.connect(_on_room_joined)
	NetworkClient.peer_joined.connect(_on_peer_ready)
	NetworkClient.peer_disconnected.connect(_on_peer_disconnected)
	NetworkClient.relay_error.connect(_on_relay_error)


func _on_create_room_pressed() -> void:
	_set_busy("Conectando al relay...")
	_pending_action = "create"
	NetworkClient.connect_to_relay(relay_url_edit.text.strip_edges())


func _on_join_room_pressed() -> void:
	if code_edit.text.strip_edges().is_empty():
		status_label.text = "Escribí el código de sala primero."
		return
	_set_busy("Conectando al relay...")
	_pending_action = "join"
	NetworkClient.connect_to_relay(relay_url_edit.text.strip_edges())


var _pending_action: String = ""


func _on_connected_to_relay() -> void:
	if _pending_action == "create":
		status_label.text = "Conectado. Creando sala..."
		NetworkClient.create_room()
	elif _pending_action == "join":
		status_label.text = "Conectado. Uniéndose a la sala..."
		NetworkClient.join_room(code_edit.text)


func _on_connection_failed(reason: String) -> void:
	status_label.text = "No se pudo conectar: %s" % reason
	_set_busy_done()


func _on_room_created(code: String) -> void:
	room_code_label.text = "Código de sala: %s  (pasáselo a la otra persona)" % code
	status_label.text = "Esperando a que se una el otro jugador..."


func _on_room_joined(_code: String) -> void:
	status_label.text = "¡Conectado! Ambos jugadores listos."
	continue_button.disabled = false


func _on_peer_ready() -> void:
	# Solo le llega al Anfitrión (el Remoto ya sabe que hay 2 desde room_joined).
	status_label.text = "¡Conectado! Ambos jugadores listos."
	continue_button.disabled = false


func _on_peer_disconnected() -> void:
	status_label.text = "El otro jugador se desconectó."
	continue_button.disabled = true


func _on_relay_error(message: String) -> void:
	status_label.text = "Error: %s" % message
	_set_busy_done()


func _on_continue_pressed() -> void:
	# Fase A, primer incremento: solo valida la conexión — el intercambio de
	# mazo real (DeckSelector leyendo NetworkClient) es el siguiente paso,
	# todavía no conectado acá. Por ahora entra al flujo normal existente.
	get_tree().change_scene_to_file("res://scenes/game/Main.tscn")


func _on_back_pressed() -> void:
	NetworkClient.disconnect_from_relay()
	get_tree().change_scene_to_file("res://scenes/menu/MainMenu.tscn")


func _set_busy(text: String) -> void:
	status_label.text = text
	create_room_button.disabled = true
	join_room_button.disabled = true


func _set_busy_done() -> void:
	create_room_button.disabled = false
	join_room_button.disabled = false
