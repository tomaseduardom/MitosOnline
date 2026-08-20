extends Node
## ExternalApiClient - Cliente para la nueva API de cartas/mazos (ShadowForge)
##
## Reemplaza la fuente vieja (localhost:3000, a la que ya no hay acceso).
## El dominio que se usaba como referencia (shadow-forge-deck.vercel.app) es
## solo el frontend Angular; el backend real es un Django/DRF aparte:
##   https://iterva.pythonanywhere.com/api
## (encontrado inspeccionando el bundle JS compilado del frontend).
##
## CREDENCIALES: nunca hardcodeadas. Al arrancar, este autoload busca
##   user://shadowforge_credentials.json   →  {"username": "...", "password": "..."}
## Si no existe, crea una plantilla vacía y avisa por consola dónde está
## (fuera del repo — la carpeta de datos de usuario de Godot). El token
## obtenido se guarda en user://shadowforge_token.json y se reutiliza hasta
## que expire (7 días) o falle con 401, momento en que se reautentica solo.
##
## FORMA DE RESPUESTA SIN CONFIRMAR: el endpoint de cartas se verificó en
## vivo (campos: myl_id, name, cost, damage, ability, race, type, image_url).
## El de /external/my-decks/ exige login y no se pudo verificar sin
## credenciales reales — fetch_my_decks() prueba varias formas razonables y,
## si ninguna calza, imprime el JSON crudo para ajustar esto en una pasada.

signal login_succeeded
signal login_failed(reason: String)
signal decks_received(decks: Array)
signal decks_failed(reason: String)
signal cards_received(edicion: String, cards: Array)
signal cards_failed(edicion: String, reason: String)

const API_BASE: String = "https://iterva.pythonanywhere.com/api"
const CREDENTIALS_PATH: String = "user://shadowforge_credentials.json"
const TOKEN_PATH: String = "user://shadowforge_token.json"

var _token: String = ""
var _is_logging_in: bool = false


func _ready() -> void:
	_load_saved_token()
	if _token.is_empty():
		_ensure_credentials_template()
	print("[ExternalApiClient] Inicializado (token guardado: %s)" % (not _token.is_empty()))


# =============================================================================
# CREDENCIALES Y TOKEN (persistidos en user://, nunca en el repo)
# =============================================================================
func _ensure_credentials_template() -> void:
	if FileAccess.file_exists(CREDENTIALS_PATH):
		return
	var file = FileAccess.open(CREDENTIALS_PATH, FileAccess.WRITE)
	if not file:
		push_error("[ExternalApiClient] No se pudo crear la plantilla de credenciales")
		return
	file.store_string(JSON.stringify({"username": "", "password": ""}, "\t"))
	file.close()
	push_warning("[ExternalApiClient] Completa tus credenciales en: %s/shadowforge_credentials.json" % OS.get_user_data_dir())


func _load_credentials() -> Dictionary:
	if not FileAccess.file_exists(CREDENTIALS_PATH):
		return {}
	var file = FileAccess.open(CREDENTIALS_PATH, FileAccess.READ)
	if not file:
		return {}
	var json = JSON.parse_string(file.get_as_text())
	file.close()
	return json if json is Dictionary else {}


func _load_saved_token() -> void:
	if not FileAccess.file_exists(TOKEN_PATH):
		return
	var file = FileAccess.open(TOKEN_PATH, FileAccess.READ)
	if not file:
		return
	var json = JSON.parse_string(file.get_as_text())
	file.close()
	if json is Dictionary and String(json.get("token", "")) != "":
		_token = json.token
		print("[ExternalApiClient] Token cargado desde user://shadowforge_token.json")


func _save_token(token: String) -> void:
	_token = token
	var file = FileAccess.open(TOKEN_PATH, FileAccess.WRITE)
	if not file:
		push_error("[ExternalApiClient] No se pudo guardar el token")
		return
	file.store_string(JSON.stringify({"token": token, "saved_at": Time.get_unix_time_from_system()}))
	file.close()
	print("[ExternalApiClient] Token guardado")


func is_authenticated() -> bool:
	return not _token.is_empty()


# =============================================================================
# LOGIN
# =============================================================================
func login() -> void:
	"""Inicia sesión con las credenciales de user://shadowforge_credentials.json.
	Si ya hay un login en curso, no hace nada — quien llamó login() debe
	escuchar login_succeeded/login_failed (ver _authed_request) en vez de
	asumir que esta llamada en particular resuelve su propia petición."""
	if _is_logging_in:
		return

	var creds = _load_credentials()
	var username: String = str(creds.get("username", ""))
	var password: String = str(creds.get("password", ""))

	if username.is_empty() or password.is_empty():
		var msg = "Faltan credenciales en %s/shadowforge_credentials.json" % OS.get_user_data_dir()
		push_warning("[ExternalApiClient] %s" % msg)
		emit_signal("login_failed", msg)
		return

	_is_logging_in = true
	var http = HTTPRequest.new()
	add_child(http)
	http.timeout = 15.0
	var body = JSON.stringify({"username": username, "password": password})
	http.request_completed.connect(_on_login_completed.bind(http))

	var err = http.request(
		API_BASE + "/external/token/",
		["Content-Type: application/json", "Accept: application/json"],
		HTTPClient.METHOD_POST,
		body
	)
	if err != OK:
		_is_logging_in = false
		http.queue_free()
		emit_signal("login_failed", "No se pudo conectar (error %d)" % err)


func _on_login_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()
	_is_logging_in = false

	if result != HTTPRequest.RESULT_SUCCESS:
		emit_signal("login_failed", "Error de conexión (%d)" % result)
		return

	var json = JSON.parse_string(body.get_string_from_utf8())

	if code != 200 or json == null:
		var msg = "Error HTTP %d" % code
		if json is Dictionary:
			msg = str(json.get("error", json.get("detail", msg)))
		emit_signal("login_failed", msg)
		return

	# El nombre exacto del campo del token no está confirmado — se prueban
	# las variantes más comunes en DRF (token / access / access_token / key).
	var token: String = ""
	if json is Dictionary:
		for key in ["token", "access", "access_token", "key"]:
			if json.has(key) and json[key] is String and not String(json[key]).is_empty():
				token = json[key]
				break

	if token.is_empty():
		push_error("[ExternalApiClient] Login OK pero no se reconoció el campo del token. Respuesta: %s" % JSON.stringify(json))
		emit_signal("login_failed", "Respuesta sin token reconocible (ver Output)")
		return

	_save_token(token)
	print("[ExternalApiClient] Login exitoso")
	emit_signal("login_succeeded")


# =============================================================================
# PETICIÓN GENÉRICA AUTENTICADA (reintenta login una vez si el token venció)
# =============================================================================
func _authed_request(path: String, on_success: Callable, on_failure: Callable, retried: bool = false) -> void:
	if not is_authenticated():
		# Conexiones one-shot: cada llamador espera a que ESTE intento de login
		# resuelva (éxito o fracaso), en vez de encolarse en un array que un
		# login fallido podía vaciar sin avisarle a nadie — ese era el bug:
		# con credenciales vacías, la petición se quedaba colgada para siempre
		# en vez de caer al fallback (ver DeckSelector._load_local_fallback).
		var retry := func(): _authed_request(path, on_success, on_failure, retried)
		var fail := func(reason: String): on_failure.call(reason)
		login_succeeded.connect(retry, CONNECT_ONE_SHOT)
		login_failed.connect(fail, CONNECT_ONE_SHOT)
		if not _is_logging_in:
			login()
		return

	var http = HTTPRequest.new()
	add_child(http)
	http.timeout = 20.0
	http.request_completed.connect(
		func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
			http.queue_free()

			if code == 401 and not retried:
				print("[ExternalApiClient] Token vencido (401), reautenticando...")
				_token = ""
				var retry := func(): _authed_request(path, on_success, on_failure, true)
				var fail := func(reason: String): on_failure.call(reason)
				login_succeeded.connect(retry, CONNECT_ONE_SHOT)
				login_failed.connect(fail, CONNECT_ONE_SHOT)
				login()
				return

			if result != HTTPRequest.RESULT_SUCCESS or code != 200:
				on_failure.call("Error HTTP %d" % code)
				return

			var json = JSON.parse_string(body.get_string_from_utf8())
			if json == null:
				on_failure.call("Respuesta no es JSON válido")
				return

			on_success.call(json)
	)

	var err = http.request(API_BASE + path, ["Authorization: Bearer %s" % _token, "Accept: application/json"])
	if err != OK:
		http.queue_free()
		on_failure.call("No se pudo conectar (error %d)" % err)


# =============================================================================
# MAZOS
# =============================================================================
func fetch_my_decks() -> void:
	var on_success := func(json):
		var decks: Array = []
		if json is Array:
			decks = json
		elif json is Dictionary:
			# Nombre exacto de la clave sin confirmar (no hay credenciales
			# para verificarlo en vivo) — se prueban las variantes más
			# probables en una API DRF. Si ninguna calza, se imprime el
			# JSON crudo para ajustar esto en la próxima pasada.
			for key in ["decks", "results", "mazos", "data"]:
				if json.get(key) is Array:
					decks = json[key]
					break
			if decks.is_empty():
				push_warning("[ExternalApiClient] No se reconoció la forma de /my-decks/. JSON crudo (primeros 800 chars): %s" % JSON.stringify(json).substr(0, 800))
		emit_signal("decks_received", decks)
	var on_failure := func(reason): emit_signal("decks_failed", reason)
	_authed_request("/external/my-decks/", on_success, on_failure)


# =============================================================================
# CARTAS — algunas ediciones (imp, esc) responden sin autenticación; otras
# (pb, fx, confirmadas por el dueño de la API el 2026-08-18) devolvían 0
# cartas sin token — se manda el Bearer si hay uno disponible, por las dudas.
# =============================================================================
func fetch_cards(edicion: String) -> void:
	var http = HTTPRequest.new()
	add_child(http)
	http.timeout = 30.0
	http.request_completed.connect(
		func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
			http.queue_free()
			if result != HTTPRequest.RESULT_SUCCESS or code != 200:
				emit_signal("cards_failed", edicion, "Error HTTP %d" % code)
				return
			var json = JSON.parse_string(body.get_string_from_utf8())
			if json == null or not json is Dictionary:
				emit_signal("cards_failed", edicion, "Respuesta no es JSON válido")
				return
			var cards: Array = json.get("cards", [])
			emit_signal("cards_received", edicion, cards)
	)
	var headers := ["Accept: application/json"]
	if not _token.is_empty():
		headers.append("Authorization: Bearer %s" % _token)
	var err = http.request(API_BASE + "/external/cards/%s/" % edicion, headers)
	if err != OK:
		http.queue_free()
		emit_signal("cards_failed", edicion, "No se pudo conectar (error %d)" % err)
