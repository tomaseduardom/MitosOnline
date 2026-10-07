extends Node
## NetworkClient — autoload, capa de red del multiplayer remoto (Fase A,
## docs/plans/2026-09-09-multiplayer-remoto-design.md e
## iterative-booping-abelson.md). Cliente WebSocket crudo (WebSocketPeer,
## builtin de Godot 4 — no MultiplayerAPI/ENet, porque el relay del lado del
## servidor es un reenviador ciego por sala, no un peer de multiplayer real)
## contra `relay-server/` (Node.js + ws, protocolo documentado en su
## server.js). No sabe NADA de reglas de Mitos y Leyendas — solo mueve JSON
## de un lado a otro. Quien interpreta esos mensajes es GameBootstrap/
## RemotePlayerController (fases B/C), no este archivo.
##
## Modo Anfitrión vs Remoto: `is_host` se fija solo al llamar create_room()/
## join_room() — antes de eso no hay ningún modo elegido (partida 100% local
## contra el bot, camino existente intacto).

signal connected_to_relay
signal connection_failed(reason: String)
signal room_created(code: String)
signal room_joined(code: String)
signal peer_joined
signal peer_disconnected
signal message_received(data: Dictionary)
signal relay_error(message: String)

var _socket: WebSocketPeer = null
var is_host: bool = false
var room_code: String = ""
var peer_present: bool = false

# Último mensaje de juego recibido por "op" (2026-09-10, Fase A — intercambio
# de mazo): un mensaje puede llegar antes de que el receptor esté listo para
# escucharlo (p.ej. el Remoto manda su mazo apenas confirma, pero el
# Anfitrión solo empieza a escuchar cuando llega a ese punto del flujo) —
# quien lo necesite puede revisar aquí en vez de depender solo de la señal en
# vivo. Se limpia junto con el resto del estado de sala.
var last_message_by_op: Dictionary = {}


func await_intent(expected_kinds: Array) -> Dictionary:
	"""Espera el próximo {"op":"intent","kind":X,...} con X en expected_kinds.
	Sin timeout — mismo criterio que el resto del motor espera a un jugador
	humano local (SelectionManager). Si la conexión se cae mientras se
	espera, esto queda colgado para siempre — aceptable en v1 (el diseño ya
	decidió 'sin reconexión, la partida termina').

	2026-09-30 — movido aquí desde RemotePlayerController._await_intent()
	(que ahora delega en este) para que SelectionManager.gd/SelectionDialogs.gd
	también puedan esperar un intent del Remoto sin duplicar la lógica
	(Fase 3 del plan de paridad, docs/plans/2026-09-20-remote-multiplayer-
	parity.md)."""
	while true:
		var data = await message_received
		if data.get("op", "") == "intent" and data.get("kind", "") in expected_kinds:
			return data
	return {}


func connect_to_relay(url: String) -> void:
	"""Abre la conexión al relay. No crea ni une ninguna sala todavía — eso
	se hace solo cuando `connected_to_relay` se emite, llamando
	create_room()/join_room()."""
	is_host = false
	room_code = ""
	peer_present = false
	_announced_connected = false
	_pending_control.clear()
	last_message_by_op.clear()
	_socket = WebSocketPeer.new()
	var err := _socket.connect_to_url(url)
	if err != OK:
		_socket = null
		emit_signal("connection_failed", "No se pudo iniciar la conexión (error %d)" % err)
		return
	set_process(true)


func create_room() -> void:
	"""Pide al relay un código de sala nuevo — este cliente queda como
	Anfitrión. Solo tiene efecto si ya hay conexión abierta al relay."""
	is_host = true
	_send_control({"op": "create_room"})


func join_room(code: String) -> void:
	"""Pide unirse a una sala existente — este cliente queda como Remoto."""
	is_host = false
	_send_control({"op": "join_room", "code": code.strip_edges().to_upper()})


func send_message(data: Dictionary) -> void:
	"""Manda un mensaje de juego (intent/instrucción) al otro lado de la
	sala. No hace nada si todavía no hay sala confirmada de los dos lados —
	llamarlo antes de eso es un error del llamador, no de esta capa."""
	if not is_instance_valid(_socket) or _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		push_warning("[NetworkClient] send_message() sin conexión abierta — descartado: %s" % str(data))
		return
	_socket.send_text(JSON.stringify(data))


func is_connected_to_peer() -> bool:
	return peer_present


func disconnect_from_relay() -> void:
	if is_instance_valid(_socket):
		_socket.close()
	_socket = null
	set_process(false)
	is_host = false
	room_code = ""
	peer_present = false
	_announced_connected = false


func _send_control(data: Dictionary) -> void:
	# Los mensajes de control (create_room/join_room) pueden llegar a
	# pedirse antes de que el socket termine su handshake — se reintenta en
	# _process() hasta que STATE_OPEN, en vez de exigirle al llamador que
	# espere la señal a mano.
	_pending_control.append(data)


var _pending_control: Array = []


func _process(_delta: float) -> void:
	if not is_instance_valid(_socket):
		set_process(false)
		return

	_socket.poll()
	var state := _socket.get_ready_state()

	if state == WebSocketPeer.STATE_OPEN:
		if not _announced_connected:
			_announced_connected = true
			emit_signal("connected_to_relay")
		if not _pending_control.is_empty():
			for msg in _pending_control:
				_socket.send_text(JSON.stringify(msg))
			_pending_control.clear()
		while _socket.get_available_packet_count() > 0:
			_handle_packet(_socket.get_packet())
	elif state == WebSocketPeer.STATE_CLOSED:
		var code := _socket.get_close_code()
		set_process(false)
		if not _announced_connected:
			emit_signal("connection_failed", "El relay cerró la conexión (código %d)" % code)
		else:
			emit_signal("peer_disconnected")
		_socket = null


var _announced_connected: bool = false


func _handle_packet(packet: PackedByteArray) -> void:
	var text := packet.get_string_from_utf8()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_warning("[NetworkClient] Paquete no-JSON/no-Dictionary ignorado: %s" % text)
		return
	var data: Dictionary = parsed
	match data.get("op", ""):
		"room_created":
			room_code = str(data.get("code", ""))
			emit_signal("room_created", room_code)
		"room_joined":
			room_code = str(data.get("code", ""))
			peer_present = true
			emit_signal("room_joined", room_code)
		"peer_joined":
			peer_present = true
			emit_signal("peer_joined")
		"peer_disconnected":
			peer_present = false
			emit_signal("peer_disconnected")
		"error":
			emit_signal("relay_error", str(data.get("message", "")))
		_:
			last_message_by_op[str(data.get("op", ""))] = data
			emit_signal("message_received", data)
