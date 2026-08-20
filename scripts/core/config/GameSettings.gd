extends Node
## GameSettings - Gestiona la configuración del juego (dorsos, preferencias, etc.)

# =============================================================================
# SEÑALES
# =============================================================================
signal card_back_changed(back_id: String)

# =============================================================================
# CONSTANTES
# =============================================================================
const CONFIG_PATH = "user://settings.cfg"
const BACKS_PATH = "res://assets/card_backs/"

const BACK_FILES = {
	"dorso_1": "dorso_1.png",
	"dorso_2": "dorso_2.png",
	"dorso_3": "dorso_3.png",
}

# =============================================================================
# VARIABLES
# =============================================================================
## Dorso del jugador local (player 0)
var player_card_back: String = "dorso_1"
## Dorso del oponente (player 1) - por defecto dorso_1
var opponent_card_back: String = "dorso_1"

var _player_back_texture: Texture2D = null
var _opponent_back_texture: Texture2D = null


func _ready() -> void:
	_load_config()
	_load_back_textures()
	print("[GameSettings] Initialized - Player back: ", player_card_back, ", Opponent back: ", opponent_card_back)


func _load_config() -> void:
	"""Carga la configuración desde archivo"""
	var config = ConfigFile.new()
	var err = config.load(CONFIG_PATH)
	if err == OK:
		player_card_back = config.get_value("game", "player_card_back", "dorso_1")
		opponent_card_back = config.get_value("game", "opponent_card_back", "dorso_1")


func _save_config() -> void:
	"""Guarda la configuración a archivo"""
	var config = ConfigFile.new()
	config.load(CONFIG_PATH)
	config.set_value("game", "player_card_back", player_card_back)
	config.set_value("game", "opponent_card_back", opponent_card_back)
	config.save(CONFIG_PATH)


func _load_back_textures() -> void:
	"""Carga las texturas de dorso para ambos jugadores"""
	# Dorso del jugador
	var player_file = BACK_FILES.get(player_card_back, "dorso_1.png")
	_player_back_texture = load(BACKS_PATH + player_file)
	if not _player_back_texture:
		_player_back_texture = load(BACKS_PATH + "dorso_1.png")

	# Dorso del oponente
	var opponent_file = BACK_FILES.get(opponent_card_back, "dorso_1.png")
	_opponent_back_texture = load(BACKS_PATH + opponent_file)
	if not _opponent_back_texture:
		_opponent_back_texture = load(BACKS_PATH + "dorso_1.png")


# =============================================================================
# API PÚBLICA
# =============================================================================

func set_card_back(back_id: String, player_id: int = 0) -> void:
	"""Cambia el dorso de las cartas para un jugador específico"""
	var current = player_card_back if player_id == 0 else opponent_card_back
	print("[GameSettings] set_card_back llamado - player: ", player_id, ", back: ", back_id, " (actual: ", current, ")")

	if back_id == current:
		print("[GameSettings] Ya es el dorso actual, ignorando")
		return

	if not BACK_FILES.has(back_id):
		print("[GameSettings] Invalid back id: ", back_id)
		return

	if player_id == 0:
		player_card_back = back_id
	else:
		opponent_card_back = back_id

	_save_config()
	_load_back_textures()
	print("[GameSettings] Emitiendo señal card_back_changed...")
	card_back_changed.emit(back_id)
	print("[GameSettings] Card back changed for player ", player_id, " to: ", back_id)


func get_card_back_id(player_id: int = 0) -> String:
	"""Retorna el ID del dorso para un jugador"""
	return player_card_back if player_id == 0 else opponent_card_back


func get_card_back_texture(player_id: int = 0) -> Texture2D:
	"""Retorna la textura del dorso para un jugador"""
	if player_id == 0:
		if not _player_back_texture:
			_load_back_textures()
		return _player_back_texture
	else:
		if not _opponent_back_texture:
			_load_back_textures()
		return _opponent_back_texture


func get_card_back_path(player_id: int = 0) -> String:
	"""Retorna el path del dorso para un jugador"""
	var back_id = player_card_back if player_id == 0 else opponent_card_back
	var file_name = BACK_FILES.get(back_id, "dorso_1.png")
	return BACKS_PATH + file_name
