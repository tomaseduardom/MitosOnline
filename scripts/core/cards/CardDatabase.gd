extends Node
## CardDatabase - Singleton que maneja la base de datos de cartas
## Se conecta con la API de El Grimorio para obtener las cartas

# =============================================================================
# SEÑALES
# =============================================================================
signal cards_loaded(count: int)
signal cards_load_failed(error: String)
signal card_image_loaded(card_id: String, texture: Texture2D)

# =============================================================================
# CONFIGURACIÓN
# =============================================================================
const API_BASE_URL: String = "http://localhost:3000/api"
const CDN_BASE_URL: String = "https://grimorio-cards.b-cdn.net"
const LOCAL_CACHE_PATH: String = "user://card_cache/"
## Modo offline: sólo usa imágenes locales (res:// + user://). Sin descargas CDN.
const OFFLINE_MODE: bool = true

# =============================================================================
# ESTADO
# =============================================================================
var cards: Dictionary = {}  # card_id -> CardData
var cards_by_uuid: Dictionary = {}  # uuid -> CardData
var cards_by_name: Dictionary = {}  # nombre -> CardData
var _newest_by_name: Dictionary = {}  # nombre -> CardData con edicion_num más alto (primero en respuesta DESC)
var is_loaded: bool = false
var is_loading: bool = false

# Cache de imágenes en memoria
var image_cache: Dictionary = {}  # card_id -> Texture2D

# =============================================================================
# INICIALIZACIÓN
# =============================================================================
func _ready() -> void:
	# Crear directorio de cache si no existe
	DirAccess.make_dir_recursive_absolute(LOCAL_CACHE_PATH.replace("user://", OS.get_user_data_dir() + "/"))
	print("[CardDatabase] Inicializado")


# =============================================================================
# CARGA DE CARTAS
# =============================================================================
func load_cards_from_api(season: String = "all") -> void:
	"""Carga las cartas desde la API de El Grimorio
	   season puede ser 'all' para todas las cartas o un ID numérico de temporada"""
	if is_loading:
		return

	is_loading = true
	print("[CardDatabase] Cargando cartas desde API (temporada: %s)..." % season)

	var http = HTTPRequest.new()
	add_child(http)
	http.timeout = 5.0  # Fallar rápido si el servidor no responde
	http.request_completed.connect(_on_cards_request_completed.bind(http))

	var url = "%s/cartas?temporada=%s" % [API_BASE_URL, season]
	print("[CardDatabase] URL: %s" % url)
	var error = http.request(url)

	if error != OK:
		is_loading = false
		emit_signal("cards_load_failed", "Error al conectar con la API: %d" % error)
		http.queue_free()


# =============================================================================
# CARGA DE CARTAS — API EXTERNA (ShadowForge, reemplaza la fuente vieja)
# =============================================================================
var _external_pending: int = 0
var _external_collected: Array = []

func load_cards_from_external_api(ediciones: Array = ["imp", "esc", "pb", "fx"]) -> void:
	"""Carga cartas desde la nueva API externa. Ver ExternalApiClient.gd para
	el detalle del host/auth — load_cards_from_api() apunta al host viejo
	(localhost:3000), ya no disponible.

	Ediciones confirmadas por el dueño de la API (2026-08-18): imp, pb, fx,
	esc. Antes solo se pedían imp/esc (~2426 cartas) — pb y fx devuelven 0
	sin autenticar, así que probablemente requieren el token Bearer (ver
	ExternalApiClient.fetch_cards())."""
	var client = get_node_or_null("/root/ExternalApiClient")
	if not client:
		emit_signal("cards_load_failed", "ExternalApiClient no disponible")
		return

	# Asegurar login ANTES de pedir las cartas: pb/fx necesitan el token
	# Bearer (a diferencia de imp/esc, que responden sin autenticar) — sin
	# esto, esas dos ediciones siempre volvían con 0 cartas. GDScript no
	# tiene 'await señal_a O señal_b' directo, así que se sondea un flag
	# que cualquiera de las dos señales puede marcar.
	if not client.is_authenticated():
		var login_attempt_done := false
		var on_login_succeeded := func(): login_attempt_done = true
		var on_login_failed := func(_reason): login_attempt_done = true
		client.login_succeeded.connect(on_login_succeeded, CONNECT_ONE_SHOT)
		client.login_failed.connect(on_login_failed, CONNECT_ONE_SHOT)
		client.login()
		while not login_attempt_done:
			await get_tree().process_frame

	is_loading = true
	_external_pending = ediciones.size()
	_external_collected.clear()

	if not client.cards_received.is_connected(_on_external_cards_received):
		client.cards_received.connect(_on_external_cards_received)
	if not client.cards_failed.is_connected(_on_external_cards_failed):
		client.cards_failed.connect(_on_external_cards_failed)

	for edicion in ediciones:
		client.fetch_cards(edicion)


func _on_external_cards_received(edicion: String, cards: Array) -> void:
	print("[CardDatabase] %d cartas recibidas de la edición externa '%s'" % [cards.size(), edicion])
	_external_collected.append_array(cards)
	_external_pending -= 1
	_check_external_cards_done()


func _on_external_cards_failed(edicion: String, reason: String) -> void:
	push_warning("[CardDatabase] Falló la carga de la edición externa '%s': %s" % [edicion, reason])
	_external_pending -= 1
	_check_external_cards_done()


func _check_external_cards_done() -> void:
	if _external_pending > 0:
		return
	is_loading = false
	if _external_collected.is_empty():
		emit_signal("cards_load_failed", "La API externa no devolvió cartas")
		return
	var mapped: Array = []
	for c in _external_collected:
		mapped.append(_create_card_from_external(c))
	_process_cards_data(mapped)


func _create_card_from_external(data: Dictionary) -> Dictionary:
	"""Mapea el formato de la API externa (ShadowForge) al formato interno.
	Campos confirmados en vivo: myl_id, name, cost, damage, ability, race,
	type, image_url, edition_title, rarity (cost/damage vienen como String)."""
	var tipo_val = data.get("type")
	var habilidad: String = str(data.get("ability", "")) if data.get("ability") != null else ""
	var card_id: String = str(data.get("myl_id", data.get("id", "")))

	return {
		"id": card_id,
		"uuid": card_id,
		"nombre": str(data.get("name", "Sin nombre")),
		"tipo": _parse_card_type(tipo_val) if tipo_val != null else Constants.CardType.ALIADO,
		"coste": int(data.get("cost", 0)) if data.get("cost") != null else 0,
		"fuerza": int(data.get("damage", 0)) if data.get("damage") != null else 0,
		"raza": str(data.get("race", "")) if data.get("race") != null else "",
		"habilidad": habilidad,
		"texto_epico": "",
		"edicion": str(data.get("edition_title", "")),
		"frecuencia": str(data.get("rarity", "")),
		"imagen": str(data.get("image_url", "")),
		"keywords": _parse_keywords(habilidad)
	}


func _on_cards_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	"""Callback cuando se reciben las cartas de la API"""
	http.queue_free()
	is_loading = false

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		emit_signal("cards_load_failed", "Error HTTP: %d" % response_code)
		return

	var json = JSON.parse_string(body.get_string_from_utf8())
	if json == null:
		emit_signal("cards_load_failed", "Error parseando JSON")
		return

	_process_cards_data(json)


func _process_cards_data(data: Array) -> void:
	"""Procesa los datos de cartas recibidos"""
	cards.clear()
	cards_by_uuid.clear()
	cards_by_name.clear()
	_newest_by_name.clear()

	# Contadores por tipo para debug
	var type_counts: Dictionary = {}

	for card_data in data:
		var card = _create_card_from_api(card_data)
		if card:
			cards[card.id] = card
			cards_by_name[card.nombre] = card

			# Indexar también por UUID si existe
			if card.has("uuid") and not card.uuid.is_empty():
				cards_by_uuid[card.uuid] = card

			# Guardar versión más nueva por nombre (API ordena id_edicion DESC → primera = más nueva)
			var nombre: String = card.get("nombre", "")
			if nombre != "" and not _newest_by_name.has(nombre):
				_newest_by_name[nombre] = card

			# Contar por tipo
			var tipo_name = Constants.CARD_TYPE_NAMES.get(card.tipo, "Desconocido")
			type_counts[tipo_name] = type_counts.get(tipo_name, 0) + 1

	is_loaded = true
	print("[CardDatabase] %d cartas cargadas (por UUID: %d)" % [cards.size(), cards_by_uuid.size()])
	print("[CardDatabase] Distribución por tipo:")
	for tipo_name in type_counts:
		print("  - %s: %d" % [tipo_name, type_counts[tipo_name]])

	emit_signal("cards_loaded", cards.size())


func _create_card_from_api(data: Dictionary) -> Dictionary:
	"""Crea un diccionario de carta desde los datos de la API"""
	# La API usa nombre_tipo en vez de tipo
	var tipo_str = data.get("nombre_tipo", data.get("tipo", "Aliado"))
	var nombre = data.get("nombre", "")

	# Debug: mostrar info de cartas que deberían ser Oro
	var oros_conocidos = ["diadema celestial", "estrella de kirin", "oro"]
	if nombre.to_lower() in oros_conocidos or "oro" in nombre.to_lower():
		print("[CardDatabase] Posible Oro: '%s' -> nombre_tipo: '%s', tipo_raw: '%s'" % [nombre, tipo_str, data.get("tipo", "N/A")])
	var raza_str = data.get("nombre_raza", data.get("raza", ""))

	return {
		"id": str(data.get("id", data.get("uuid", ""))),
		"uuid": str(data.get("uuid", "")),
		"nombre": data.get("nombre", "Sin nombre"),
		"tipo": _parse_card_type(tipo_str),
		"coste": data.get("coste", 0) if data.get("coste") != null else 0,
		"fuerza": data.get("fuerza", 0) if data.get("fuerza") != null else 0,
		"raza": raza_str,
		"habilidad": data.get("habilidad", ""),
		"texto_epico": data.get("texto_epico", ""),
		"edicion": data.get("nombre_edicion", data.get("edicion", "")),
		"frecuencia": data.get("frecuencia", ""),
		"imagen": data.get("imagen", ""),
		"keywords": _parse_keywords(data.get("habilidad", ""))
	}


func _parse_card_type(tipo) -> Constants.CardType:
	"""Convierte el tipo de carta de string o int a enum"""
	# Si ya es un número (int o float, ya que JSON devuelve floats), retornarlo como enum
	if tipo is int or tipo is float:
		var tipo_int = int(tipo)
		if tipo_int >= 0 and tipo_int <= 4:
			return tipo_int as Constants.CardType
		return Constants.CardType.ALIADO

	# Si es string, parsearlo
	if tipo is String:
		match tipo.to_lower():
			"oro":
				return Constants.CardType.ORO
			"aliado":
				return Constants.CardType.ALIADO
			"arma":
				return Constants.CardType.ARMA
			"talisman", "talismán":
				return Constants.CardType.TALISMAN
			"totem", "tótem":
				return Constants.CardType.TOTEM

	return Constants.CardType.ALIADO


func _parse_keywords(habilidad: String) -> Array:
	"""Extrae las keywords del texto de habilidad"""
	var keywords: Array = []
	var text = habilidad.to_lower()

	if "furia" in text:
		keywords.append(Constants.Keyword.FURIA)
	if "imbloqueable" in text:
		keywords.append(Constants.Keyword.IMBLOQUEABLE)
	if "indestructible" in text:
		keywords.append(Constants.Keyword.INDESTRUCTIBLE)
	if "indesterrable" in text:
		keywords.append(Constants.Keyword.INDESTERRABLE)
	if "exhumar" in text or "desde tu cementerio" in text:
		keywords.append(Constants.Keyword.EXHUMAR)
	if "única" in text:
		keywords.append(Constants.Keyword.UNICA)

	return keywords


# =============================================================================
# CARGA DE CARTAS — BUNDLED (res://) y CACHE (user://)
# =============================================================================
const BUNDLED_CARDS_PATH: String = "res://data/cards.json"

func load_cards_from_bundled() -> bool:
	"""Carga cartas desde el archivo bundleado res://data/cards.json.
	Este archivo se genera con export_for_bundling() y se incluye en el proyecto."""
	if not FileAccess.file_exists(BUNDLED_CARDS_PATH):
		return false
	var file = FileAccess.open(BUNDLED_CARDS_PATH, FileAccess.READ)
	if file == null:
		return false
	var json = JSON.parse_string(file.get_as_text())
	file.close()
	if json == null or not json is Array:
		return false
	_process_cards_data(json)
	print("[CardDatabase] Cartas cargadas desde bundled (res://data/cards.json): %d" % cards.size())
	return true


func export_for_bundling() -> void:
	"""Exporta las cartas actuales a user://data/cards.json para luego moverlas a res://data/.
	Llamar una vez con el servidor levantado para generar el archivo bundleable."""
	if not is_loaded:
		push_warning("[CardDatabase] No hay cartas cargadas para exportar")
		return
	DirAccess.make_dir_recursive_absolute(OS.get_user_data_dir() + "/data")
	var path = "user://data/cards.json"
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[CardDatabase] No se pudo escribir %s" % path)
		return
	var data: Array = []
	for card in cards.values():
		data.append(card)
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	var abs_path = OS.get_user_data_dir() + "/data/cards.json"
	print("[CardDatabase] EXPORTADO → %s\nCopia ese archivo a game/data/cards.json" % abs_path)


func load_cards_from_cache() -> bool:
	"""Intenta cargar las cartas desde el cache local"""
	var cache_file = LOCAL_CACHE_PATH + "cards.json"

	if not FileAccess.file_exists(cache_file):
		return false

	var file = FileAccess.open(cache_file, FileAccess.READ)
	if file == null:
		return false

	var json = JSON.parse_string(file.get_as_text())
	file.close()

	if json == null or not json is Array:
		return false

	_process_cards_data(json)
	print("[CardDatabase] Cartas cargadas desde cache local")
	return true


func save_cards_to_cache() -> void:
	"""Guarda las cartas actuales en cache local"""
	var cache_file = LOCAL_CACHE_PATH + "cards.json"
	var file = FileAccess.open(cache_file, FileAccess.WRITE)

	if file == null:
		push_error("[CardDatabase] No se pudo guardar cache")
		return

	var data: Array = []
	for card in cards.values():
		data.append(card)

	file.store_string(JSON.stringify(data))
	file.close()
	print("[CardDatabase] Cache guardado")


# =============================================================================
# ACCESO A CARTAS
# =============================================================================
func get_card(card_id: String) -> Dictionary:
	"""Obtiene una carta por su ID o UUID"""
	# Primero buscar por ID
	if cards.has(card_id):
		return cards[card_id]
	# Luego buscar por UUID
	if cards_by_uuid.has(card_id):
		return cards_by_uuid[card_id]
	return {}


func get_card_by_name(nombre: String) -> Dictionary:
	"""Obtiene una carta por su nombre"""
	return cards_by_name.get(nombre, {})


func get_all_cards() -> Array:
	"""Obtiene todas las cartas"""
	return cards.values()


func get_cards_by_type(tipo: Constants.CardType) -> Array:
	"""Obtiene todas las cartas de un tipo específico"""
	var result: Array = []
	for card in cards.values():
		if card.tipo == tipo:
			result.append(card)
	return result


func get_cards_by_raza(raza: String) -> Array:
	"""Obtiene todas las cartas de una raza específica"""
	var result: Array = []
	for card in cards.values():
		if card.raza == raza:
			result.append(card)
	return result


# =============================================================================
# IMÁGENES LOCALES
# Carpetas disponibles en res://cartas_descargadas/ (ediciones vigentes).
# La ruta se deriva del campo `imagen` de cada carta (CDN path), no del card_id.
# =============================================================================
const LOCAL_CARDS_PATH: String = "res://cartas_descargadas/"

# Mapea el número de edición embebido en el nombre de archivo CDN (p.ej. el
# "162" en ".../162_001_transformacion_secreta.webp") a la carpeta local en
# cartas_descargadas/. Solo estas 12 ediciones están descargadas localmente
# — el resto cae a dorso hasta que se descarguen (ver docs/audit-2026-08-13.html,
# "la mitad de las cartas no cargan visualización").
#
# IMPORTANTE — esta función asumía que `imagen` traía una carpeta
# ("{edicion}_{CARPETA}/archivo.webp"), pero el dato real es una URL PLANA
# sin carpeta ("https://.../{edicion}_{carta}_{slug}[_rareza].webp"). Por
# eso NINGUNA imagen local resolvía antes de este fix, para ninguna carta.
const CDN_NUMBER_TO_FOLDER: Dictionary = {
	"136": "AK",    # Amenaza Kaiju
	"148": "BEST",  # Bestiarium
	"156": "CF",    # Toolkit Cenizas de Fuego
	"137": "EM",    # Escuadrón Mecha
	"125": "ES",    # Espíritu Samurai
	"155": "HI",    # Toolkit Hielo Inmortal
	"162": "KVM",   # KVM Titanes (nombres por slug, no numéricos)
	"161": "LIB",   # Libertadores
	"150": "LT24",  # Lootbox 2024
	"160": "ONY",   # Onyria
	"149": "SA",    # Secretos Arcanos
	"126": "ZOD",   # Zodiaco
}


func _get_local_res_path(card_id: String) -> String:
	"""Devuelve la ruta res:// a la imagen local derivada del campo 'imagen' de la carta."""
	var card_data = cards.get(card_id, {})
	return _imagen_to_local_path(card_data.get("imagen", ""))


func _imagen_to_local_path(imagen: String) -> String:
	"""Convierte la URL de imagen a la ruta local en cartas_descargadas/, si
	esa edición fue descargada (ver CDN_NUMBER_TO_FOLDER). Formato real del
	campo `imagen`: URL plana sin carpeta, filename "{edicion}_{carta}_{slug}
	[_rareza].webp" — p.ej. "162_001_transformacion_secreta.webp" o, para
	ediciones no-KVM, "148_001_nombre_comun.webp" (local: "148-001.png")."""
	if imagen.is_empty() or imagen == "/dorso_default.webp":
		return ""

	var filename := imagen
	if filename.begins_with("http"):
		filename = filename.replace(CDN_BASE_URL + "/", "")
	if filename.begins_with("/"):
		filename = filename.substr(1)
	# Por si alguna vez vuelve a traer una carpeta intermedia, quedarse con
	# la última parte del path.
	var last_slash := filename.rfind("/")
	if last_slash != -1:
		filename = filename.substr(last_slash + 1)

	var fn_no_ext := filename.replace(".webp", "").replace(".png", "").replace(".jpg", "")
	var parts := fn_no_ext.split("_")
	if parts.size() < 2 or not parts[0].is_valid_int():
		return ""

	var edition_num := parts[0]
	var local_folder: String = CDN_NUMBER_TO_FOLDER.get(edition_num, "")
	if local_folder.is_empty():
		return ""  # Edición no descargada localmente

	# KVM usa nombres por slug (todo lo que sigue al número de carta)
	if local_folder == "KVM":
		if parts.size() < 3:
			return ""
		var slug := "_".join(parts.slice(2))          # "transformacion_secreta"
		return LOCAL_CARDS_PATH + local_folder + "/" + slug + ".png"

	# Resto: numérico "{edicion}-{numero_carta}.png" — salvo LIB, cuyos
	# archivos usan el código de letras en vez del número ("LIB-001.png",
	# no "161-001.png"). Además, algunas ediciones (p.ej. AK) tienen los
	# DOS formatos mezclados dentro de la misma carpeta — las primeras
	# cartas descargadas quedaron como "136-001.png" y un lote posterior
	# como "AK-018.png" — así que no alcanza con elegir un prefijo fijo por
	# edición: hay que probar cuál archivo existe de verdad.
	if not parts[1].is_valid_int():
		return ""
	var preferred_prefix := local_folder if local_folder == "LIB" else edition_num
	var alternate_prefix := edition_num if local_folder == "LIB" else local_folder
	var preferred_path := LOCAL_CARDS_PATH + local_folder + "/" + preferred_prefix + "-" + parts[1] + ".png"
	if ResourceLoader.exists(preferred_path):
		return preferred_path
	var alternate_path := LOCAL_CARDS_PATH + local_folder + "/" + alternate_prefix + "-" + parts[1] + ".png"
	if ResourceLoader.exists(alternate_path):
		return alternate_path
	return preferred_path


# =============================================================================
# CARGA DE IMÁGENES
# =============================================================================
func get_card_image(card_id: String) -> Texture2D:
	"""Obtiene la imagen de una carta (desde cache si está disponible).
	Si la edición local fue eliminada, intenta automáticamente la versión más nueva del mismo nombre."""
	if card_id in image_cache:
		return image_cache[card_id]

	# 1. Imagen local empaquetada (res://) — derivada del campo imagen de la carta
	var res_path := _get_local_res_path(card_id)
	if res_path != "":
		var tex: Texture2D = load(res_path)
		if tex:
			image_cache[card_id] = tex
			return tex

	# 2. Fallback: cualquier otra edición del mismo nombre de carta que SÍ
	# tenga imagen descargada localmente. Antes probaba solo _newest_by_name
	# (la edición más nueva según el orden de la API) sin verificar que esa
	# edición en particular tuviera el archivo — si esa "más nueva" tampoco
	# estaba descargada (caso real: Gurzil promo de LIB, sin archivo local,
	# mientras que sus ediciones de Bestiarium sí lo tienen), el fallback
	# fallaba igual aunque existieran otras ediciones perfectamente válidas.
	var card_data: Dictionary = cards.get(card_id, {})
	var nombre: String = card_data.get("nombre", "")
	if nombre != "":
		for other_id in cards:
			if other_id == card_id:
				continue
			var other: Dictionary = cards[other_id]
			if other.get("nombre", "") != nombre:
				continue
			var other_path := _imagen_to_local_path(other.get("imagen", ""))
			if other_path != "" and ResourceLoader.exists(other_path):
				var tex: Texture2D = load(other_path)
				if tex:
					print("[CardDatabase] Fallback a otra edición para '%s': %s" % [nombre, other_path])
					image_cache[card_id] = tex
					return tex

	# 3. Cache en disco (descargas previas del CDN)
	var local_path := LOCAL_CACHE_PATH + "images/" + card_id + ".png"
	if FileAccess.file_exists(local_path):
		var image := Image.load_from_file(local_path)
		if image:
			var texture := ImageTexture.create_from_image(image)
			image_cache[card_id] = texture
			return texture

	# 4. Descargar: directo si es una URL externa absoluta (p.ej. Cloudinary de
	#    la API nueva — no necesita el proxy ni el workaround de Referer que sí
	#    requiere el CDN viejo); vía proxy Nuxt si es el CDN viejo (deshabilitado
	#    en OFFLINE_MODE — ese proxy ya no está disponible).
	var imagen_path: String = card_data.get("imagen", "")
	var is_direct_external := imagen_path.begins_with("http") and not imagen_path.begins_with(CDN_BASE_URL)
	if is_direct_external or not OFFLINE_MODE:
		_download_card_image(card_id)
	return null


func check_deck_images(deck: Array) -> void:
	"""Diagnóstico: imprime qué cartas del mazo tienen imagen local y cuáles no."""
	var ok := 0
	var fallback := 0
	var missing := 0
	print("[CardDatabase] === CHECK IMÁGENES DEL MAZO (%d cartas) ===" % deck.size())
	for card_data in deck:
		var card_id: String = str(card_data.get("id", ""))
		var nombre: String = card_data.get("nombre", "Sin nombre")
		var imagen: String = card_data.get("imagen", "")
		var local_path := _imagen_to_local_path(imagen)
		if local_path != "" and ResourceLoader.exists(local_path):
			ok += 1
		else:
			# ¿Hay versión más nueva disponible?
			var newest: Dictionary = _newest_by_name.get(nombre, {})
			var newest_path := _imagen_to_local_path(newest.get("imagen", ""))
			if newest_path != "" and ResourceLoader.exists(newest_path) and newest.get("id","") != card_id:
				fallback += 1
				print("  [FALLBACK] %s → %s" % [nombre, newest_path])
			else:
				missing += 1
				print("  [FALTA]    %s (imagen: %s)" % [nombre, imagen])
	print("[CardDatabase] Resultado: %d OK, %d con fallback, %d sin imagen" % [ok, fallback, missing])


func preload_deck_images(deck: Array) -> void:
	"""Pre-descarga en segundo plano las imágenes de todas las cartas del mazo.
	Las cartas ya cacheadas localmente se saltan. Se respeta MAX_CONCURRENT_DOWNLOADS."""
	var queued := 0
	var already_cached := 0
	for card_data in deck:
		var card_id = str(card_data.get("id", ""))
		if card_id.is_empty():
			continue
		# Ya en memoria o descargando
		if card_id in image_cache or card_id in _pending_downloads or card_id in _download_queue:
			already_cached += 1
			continue
		# Imagen local empaquetada (res://) — no necesita descarga
		if _get_local_res_path(card_id) != "":
			already_cached += 1
			continue
		# Ya guardado en disco
		var local_path = LOCAL_CACHE_PATH + "images/" + card_id + ".png"
		if FileAccess.file_exists(local_path):
			already_cached += 1
			continue
		if OFFLINE_MODE:
			continue
		# Imagen válida para descargar
		var imagen_path = card_data.get("imagen", "")
		if imagen_path.is_empty() or imagen_path == "/dorso_default.webp":
			continue
		# Encolar directamente sin pasar por get_card() (ya tenemos el path)
		if _pending_downloads.size() < MAX_CONCURRENT_DOWNLOADS:
			_start_image_download(card_id, imagen_path)
		else:
			_download_queue.append(card_id)
		queued += 1
	print("[CardDatabase] Pre-carga: %d en cola, %d ya cacheadas" % [queued, already_cached])


var _pending_downloads: Dictionary = {}  # card_id -> true (en progreso)
var _download_queue: Array[String] = []   # Cola de card_ids esperando
const MAX_CONCURRENT_DOWNLOADS: int = 8   # Máximo de requests simultáneos

func _download_card_image(card_id: String) -> void:
	"""Encola la descarga de la imagen. Máximo MAX_CONCURRENT_DOWNLOADS simultáneos."""
	if card_id in _pending_downloads:
		return

	# Validar que la carta tiene imagen descargable
	var card = get_card(card_id)
	if card.is_empty():
		return
	var imagen_path = card.get("imagen", "")
	if imagen_path.is_empty() or imagen_path == "/dorso_default.webp":
		print("[CardDatabase] Sin imagen CDN para carta %s (path: '%s')" % [card_id, imagen_path])
		return

	# Si hay slots libres, descargar ahora; si no, encolar
	if _pending_downloads.size() < MAX_CONCURRENT_DOWNLOADS:
		_start_image_download(card_id, imagen_path)
	elif card_id not in _download_queue:
		_download_queue.append(card_id)


func _build_cdn_url(imagen_path: String) -> String:
	"""Construye la URL CDN directa a partir del path relativo de la imagen."""
	if imagen_path.begins_with("/"):
		imagen_path = imagen_path.substr(1)
	if not "/" in imagen_path and not imagen_path.begins_with("http"):
		imagen_path = "cards/" + imagen_path
	return imagen_path if imagen_path.begins_with("http") else CDN_BASE_URL + "/" + imagen_path


func _start_image_download(card_id: String, imagen_path: String) -> void:
	"""Inicia la descarga HTTP de una imagen.
	URLs externas absolutas (p.ej. Cloudinary, API nueva) se descargan directo.
	El CDN viejo (bunny.net) necesita el proxy Nuxt para evitar su 403 — pero
	ese proxy ya no está disponible, así que ese camino queda solo por
	compatibilidad si alguna vez vuelve a levantarse."""
	_pending_downloads[card_id] = true

	var is_direct_external := imagen_path.begins_with("http") and not imagen_path.begins_with(CDN_BASE_URL)
	var download_url: String
	if is_direct_external:
		download_url = imagen_path
	else:
		var cdn_url = _build_cdn_url(imagen_path)
		download_url = API_BASE_URL + "/game/card-image?url=" + cdn_url.uri_encode()

	print("[CardDatabase] Descargando imagen %s → %s" % [card_id, download_url])

	var http = HTTPRequest.new()
	add_child(http)
	http.timeout = 15.0
	http.request_completed.connect(_on_image_request_completed.bind(http, card_id))

	var error = http.request(download_url)
	if error != OK:
		print("[CardDatabase] Falló request para %s (url: %s): %d" % [card_id, download_url, error])
		_pending_downloads.erase(card_id)
		http.queue_free()
		emit_signal("card_image_loaded", card_id, null)  # notificar fallo inmediato
		_process_download_queue()


func _process_download_queue() -> void:
	"""Inicia descargas pendientes si hay slots libres."""
	while _download_queue.size() > 0 and _pending_downloads.size() < MAX_CONCURRENT_DOWNLOADS:
		var next_id = _download_queue.pop_front()
		if next_id in _pending_downloads:
			continue  # Ya descargándose
		var card = get_card(next_id)
		if card.is_empty():
			continue
		var img = card.get("imagen", "")
		if img.is_empty() or img == "/dorso_default.webp":
			continue
		_start_image_download(next_id, img)


func _on_image_request_completed(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest, card_id: String) -> void:
	"""Callback cuando se descarga una imagen"""
	http.queue_free()
	_pending_downloads.erase(card_id)
	_process_download_queue()  # Liberar slot → siguiente en cola

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		var card = get_card(card_id)
		var img_path = card.get("imagen", "N/A") if not card.is_empty() else "N/A"
		printerr("[CardDatabase] NEGRO — Error imagen id='%s' path='%s' result=%d code=%d" % [card_id, img_path, result, response_code])
		emit_signal("card_image_loaded", card_id, null)  # notificar fallo → carta muestra dorso
		return

	var image = Image.new()
	var error = image.load_webp_from_buffer(body)

	if error != OK:
		error = image.load_png_from_buffer(body)

	if error != OK:
		error = image.load_jpg_from_buffer(body)

	if error != OK:
		printerr("[CardDatabase] NEGRO — Error decodificando id='%s' error=%d" % [card_id, error])
		emit_signal("card_image_loaded", card_id, null)
		return

	var texture = ImageTexture.create_from_image(image)
	image_cache[card_id] = texture

	# Guardar en cache local
	var images_dir = (LOCAL_CACHE_PATH + "images/").replace("user://", OS.get_user_data_dir() + "/")
	DirAccess.make_dir_recursive_absolute(images_dir)
	image.save_png(LOCAL_CACHE_PATH + "images/" + card_id + ".png")

	emit_signal("card_image_loaded", card_id, texture)


# =============================================================================
# PRUEBA DE HUMO (SMOKE TEST)
# =============================================================================
func run_smoke_test() -> void:
	"""Diagnóstico profundo del pipeline de carga de imágenes.
	Test 1 — Textura local: si falla, el problema es Godot/runtime, no la red.
	Test 2 — Estado del cache: verifica que las cartas estén cargadas de la API.
	Test 3 — Descarga CDN: descarga 1 imagen con logs verbosos para aislar el fallo."""
	push_warning("[CardDatabase] >>> SMOKE TEST ACTIVO — ver Output para resultados <<<")
	print("\n[CardDatabase] ═══════════ SMOKE TEST INICIO ═══════════")

	# ── TEST 1: Textura local (dorso) ─────────────────────────────────────────
	var local_tex: Texture2D = load("res://assets/card_backs/dorso_1.png")
	if local_tex:
		print("[CardDatabase] ✓ TEST 1 PASS — Textura local OK (%dx%d px)" % [local_tex.get_width(), local_tex.get_height()])
	else:
		printerr("[CardDatabase] ✗ TEST 1 FAIL — No se cargó res://assets/card_backs/dorso_1.png")

	# ── TEST 1b: Imágenes locales de ediciones (numérico + slug) ───────────────
	var sample_ids = {
		"148_001": "BEST", "160_001": "ONY", "161_001": "LIB", "125_001": "ES",
		"136_001": "AK",   "156_001": "CF",  "121_001": "GIGER",
	}
	for sample_id in sample_ids:
		var res_path = _get_local_res_path(sample_id)
		var tex: Texture2D = load(res_path) if res_path != "" else null
		if tex:
			print("[CardDatabase] ✓ TEST 1b PASS — %s (%s) OK" % [sample_ids[sample_id], res_path])
		else:
			printerr("[CardDatabase] ✗ TEST 1b FAIL — %s → path='%s'" % [sample_ids[sample_id], res_path])

	# ── TEST 1c: KVM slug-based (necesita cards cargadas) ─────────────────────
	if not cards.is_empty():
		var kvm_card: Dictionary = {}
		for cid in cards:
			if str(cid).begins_with("162_"):
				kvm_card = cards[cid]
				break
		if not kvm_card.is_empty():
			var kvm_path = _get_local_res_path(kvm_card.get("id", ""))
			var kvm_tex: Texture2D = load(kvm_path) if kvm_path != "" else null
			if kvm_tex:
				print("[CardDatabase] ✓ TEST 1c PASS — KVM (%s) OK" % kvm_path)
			else:
				printerr("[CardDatabase] ✗ TEST 1c FAIL — KVM path='%s'" % kvm_path)
		else:
			print("[CardDatabase] ⚠ TEST 1c SKIP — No hay cartas KVM (162) en BD")

	# ── TEST 2: Estado del cache ───────────────────────────────────────────────
	print("[CardDatabase] TEST 2 — Cartas en BD: %d | Imágenes en memoria: %d | is_loaded: %s" % [
		cards.size(), image_cache.size(), str(is_loaded)])

	if cards.is_empty():
		printerr("[CardDatabase] ✗ TEST 2 FAIL — CardDatabase.cards está vacío (API no cargó)")
		print("[CardDatabase] ═══════════ SMOKE TEST FIN ═══════════\n")
		return

	# Buscar una carta con ruta de imagen CDN real
	var test_card: Dictionary = {}
	for c in cards.values():
		var img = c.get("imagen", "")
		if not img.is_empty() and img != "/dorso_default.webp":
			test_card = c
			break

	if test_card.is_empty():
		printerr("[CardDatabase] ✗ TEST 2b — Ninguna carta tiene imagen CDN (todas usan dorso_default)")
		print("[CardDatabase] ═══════════ SMOKE TEST FIN ═══════════\n")
		return

	var test_id   = str(test_card.get("id", "smoke"))
	var test_path = test_card.get("imagen", "")
	print("[CardDatabase] ✓ TEST 2 PASS — Carta de prueba: '%s'  id='%s'  imagen='%s'" % [
		test_card.get("nombre", "?"), test_id, test_path])

	# ── TEST 3: Descarga vía proxy Nuxt ───────────────────────────────────────
	# El CDN requiere Token Auth — Godot usa el proxy local para evitar el 403
	var cdn_url = _build_cdn_url(test_path)
	var proxy_url = API_BASE_URL + "/game/card-image?url=" + cdn_url.uri_encode()

	print("[CardDatabase] TEST 3 — CDN url  : %s" % cdn_url)
	print("[CardDatabase] TEST 3 — Proxy url: %s" % proxy_url)

	var http = HTTPRequest.new()
	add_child(http)
	http.timeout = 15.0

	http.request_completed.connect(
		func(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
			http.queue_free()
			print("[CardDatabase] TEST 3 respuesta: result=%d  http_code=%d  body=%d bytes" % [result, code, body.size()])

			if result != HTTPRequest.RESULT_SUCCESS or code != 200:
				printerr("[CardDatabase] ✗ TEST 3 FAIL — Descarga fallida. result=%d code=%d" % [result, code])
				printerr("[CardDatabase]   Proxy url: %s" % proxy_url)
				printerr("[CardDatabase]   → ¿Está corriendo 'npm run dev'? ¿Proxy registrado?")
				if body.size() > 0:
					printerr("[CardDatabase]   Primeros bytes: %s" % body.slice(0, min(64, body.size())).get_string_from_utf8())
				print("[CardDatabase] ═══════════ SMOKE TEST FIN ═══════════\n")
				return

			# Intentar los tres formatos en orden
			var img = Image.new()
			var err = img.load_webp_from_buffer(body)
			var fmt = "webp"
			if err != OK:
				err = img.load_png_from_buffer(body)
				fmt = "png"
			if err != OK:
				err = img.load_jpg_from_buffer(body)
				fmt = "jpg"

			if err != OK:
				printerr("[CardDatabase] ✗ TEST 3 FAIL — %d bytes descargados pero decode falló (err=%d)" % [body.size(), err])
				printerr("[CardDatabase]   Primeros 16 bytes (hex): %s" % body.slice(0, min(16, body.size())).hex_encode())
				printerr("[CardDatabase]   Primeros bytes (utf8): '%s'" % body.slice(0, min(64, body.size())).get_string_from_utf8())
				printerr("[CardDatabase]   → Respuesta no es imagen (¿redirect HTML? ¿formato raro?)")
				print("[CardDatabase] ═══════════ SMOKE TEST FIN ═══════════\n")
				return

			var tex = ImageTexture.create_from_image(img)
			if not tex:
				printerr("[CardDatabase] ✗ TEST 3 FAIL — Image decodificada (%s) pero ImageTexture.create_from_image retornó null" % fmt)
				print("[CardDatabase] ═══════════ SMOKE TEST FIN ═══════════\n")
				return

			print("[CardDatabase] ✓ TEST 3 PASS — Imagen CDN OK: %s  %dx%d px" % [fmt, img.get_width(), img.get_height()])
			print("[CardDatabase] ✓ PIPELINE COMPLETO — El sistema de imágenes funciona correctamente")
			# Inyectar en cache y emitir señal para que se aplique a la carta en juego
			image_cache[test_id] = tex
			emit_signal("card_image_loaded", test_id, tex)
			print("[CardDatabase] ═══════════ SMOKE TEST FIN ═══════════\n")
	)

	var smoke_headers = PackedStringArray(["Referer: https://elgrimorio.cl"])
	var req_err = http.request(cdn_url, smoke_headers)
	if req_err != OK:
		printerr("[CardDatabase] ✗ TEST 3 FAIL — http.request() rechazado de inmediato (err=%d)" % req_err)
		printerr("[CardDatabase]   → TLS/SSL no disponible o URL malformada")
		http.queue_free()

	print("[CardDatabase] TEST 3 en curso (esperando respuesta HTTP)...")
