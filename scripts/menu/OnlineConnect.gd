extends Control
## OnlineConnect — pantalla de conexión del multiplayer remoto (Fase A,
## docs/plans/2026-09-09-multiplayer-remoto-design.md). Crea o une una sala
## contra el relay (ver NetworkClient autoload) ANTES de entrar a Main.tscn.
## Esta pantalla solo valida la conexión — el intercambio de mazo real y el
## resto del handshake (Fase A, siguiente incremento) todavía no están aquí.

# 2026-09-19: relay desplegado en Railway (gratis, sin tarjeta — ver
# relay-server/README.md). wss:// (no ws://) porque es HTTPS/TLS sobre esa
# URL pública — Railway rechaza websocket sin cifrar en producción. Para
# probar contra un relay local en cambio, cambiar a mano a
# "ws://localhost:8080" (server.js corriendo con `npm start` en
# relay-server/).
const DEFAULT_RELAY_URL := "wss://mitos-relay-server-production.up.railway.app"

@onready var relay_url_edit: LineEdit = %RelayUrlEdit if has_node("%RelayUrlEdit") else $VBoxContainer/RelayUrlEdit
@onready var create_room_button: Button = %CreateRoomButton if has_node("%CreateRoomButton") else $VBoxContainer/HostSection/CreateRoomButton
@onready var room_code_label: Label = %RoomCodeLabel if has_node("%RoomCodeLabel") else $VBoxContainer/HostSection/RoomCodeLabel
@onready var code_edit: LineEdit = %CodeEdit if has_node("%CodeEdit") else $VBoxContainer/JoinSection/CodeEdit
@onready var join_room_button: Button = %JoinRoomButton if has_node("%JoinRoomButton") else $VBoxContainer/JoinSection/JoinRoomButton
@onready var status_label: Label = %StatusLabel if has_node("%StatusLabel") else $VBoxContainer/StatusLabel
@onready var continue_button: Button = %ContinueButton if has_node("%ContinueButton") else $VBoxContainer/ContinueButton
@onready var back_button: Button = %BackButton if has_node("%BackButton") else $VBoxContainer/BackButton


func _ready() -> void:
	for btn in [create_room_button, join_room_button, back_button]:
		if btn:
			btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			btn.mouse_entered.connect(func():
				var tw = btn.create_tween()
				tw.tween_property(btn, "modulate", Color(1.15, 1.15, 1.15, 1.0), 0.12)
			)
			btn.mouse_exited.connect(func():
				var tw = btn.create_tween()
				tw.tween_property(btn, "modulate", Color(1.0, 1.0, 1.0, 1.0), 0.12)
			)

	relay_url_edit.text = DEFAULT_RELAY_URL
	room_code_label.text = ""
	continue_button.visible = false

	create_room_button.pressed.connect(_on_create_room_pressed)
	join_room_button.pressed.connect(_on_join_room_pressed)
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
		status_label.text = "Escribe el código de sala primero."
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
	status_label.text = "Esperando jugador..."


func _on_room_joined(_code: String) -> void:
	# 2026-09-20: ya no espera un click en "Continuar" — la sala ya tiene 2
	# jugadores confirmados (el relay solo emite room_joined cuando la sala
	# existía y tenía hueco), así que pasa directo a la partida.
	status_label.text = "¡Conectado! Entrando a la partida..."
	_enter_match()


func _on_peer_ready() -> void:
	# Solo le llega al Anfitrión (el Remoto ya sabe que hay 2 desde room_joined).
	status_label.text = "¡Conectado! Entrando a la partida..."
	_enter_match()


func _on_peer_disconnected() -> void:
	status_label.text = "El otro jugador se desconectó."


func _on_relay_error(message: String) -> void:
	status_label.text = "Error: %s" % message
	_set_busy_done()


func _enter_match() -> void:
	# Fase A/B: el intercambio de mazo real (GameBootstrap leyendo
	# NetworkClient) y el resto del handshake pasan en Main.tscn — ver
	# GameBootstrap._on_decks_selected()/_load_opponent_deck_from_network()/
	# _send_own_deck_and_wait_for_host().
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
