extends Node
## GameSettings - Gestiona la configuración del juego (dorsos, preferencias, etc.)

# =============================================================================
# SEÑALES
# =============================================================================
signal card_back_changed(back_id: String)
signal audio_volume_changed(bus_name: String, volume_linear: float)
signal animation_speed_changed(speed: float)

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

## Ajustes de Audio (0.0 a 1.0)
var master_volume: float = 1.0
var music_volume: float = 0.8
var sfx_volume: float = 1.0

## Velocidad de Animación (1.0, 1.5, 2.0)
var animation_speed: float = 1.0

var _player_back_texture: Texture2D = null
var _opponent_back_texture: Texture2D = null


func _ready() -> void:
	_load_config()
	_load_back_textures()
	_apply_all_audio_settings()
	_apply_animation_speed()
	print("[GameSettings] Initialized - Player back: ", player_card_back, ", Opponent back: ", opponent_card_back, ", Speed: ", animation_speed)


func _load_config() -> void:
	"""Carga la configuración desde archivo"""
	var config = ConfigFile.new()
	var err = config.load(CONFIG_PATH)
	if err == OK:
		player_card_back = config.get_value("game", "player_card_back", "dorso_1")
		opponent_card_back = config.get_value("game", "opponent_card_back", "dorso_1")
		animation_speed = config.get_value("game", "animation_speed", 1.0)
		master_volume = config.get_value("audio", "master_volume", 1.0)
		music_volume = config.get_value("audio", "music_volume", 0.8)
		sfx_volume = config.get_value("audio", "sfx_volume", 1.0)


func _save_config() -> void:
	"""Guarda la configuración a archivo"""
	var config = ConfigFile.new()
	config.load(CONFIG_PATH)
	config.set_value("game", "player_card_back", player_card_back)
	config.set_value("game", "opponent_card_back", opponent_card_back)
	config.set_value("game", "animation_speed", animation_speed)
	config.set_value("audio", "master_volume", master_volume)
	config.set_value("audio", "music_volume", music_volume)
	config.set_value("audio", "sfx_volume", sfx_volume)
	config.save(CONFIG_PATH)


func _apply_all_audio_settings() -> void:
	apply_audio_bus_volume("Master", master_volume)
	apply_audio_bus_volume("Music", music_volume)
	apply_audio_bus_volume("SFX", sfx_volume)


func _apply_animation_speed() -> void:
	if not get_tree().paused:
		Engine.time_scale = animation_speed


func apply_audio_bus_volume(bus_name: String, val: float) -> void:
	var idx = AudioServer.get_bus_index(bus_name)
	if idx < 0 and bus_name != "Master":
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, "Master")
	if idx >= 0:
		AudioServer.set_bus_volume_db(idx, linear_to_db(clampf(val, 0.0001, 1.0)))
		AudioServer.set_bus_mute(idx, val <= 0.01)


func set_master_volume(val: float) -> void:
	master_volume = clampf(val, 0.0, 1.0)
	apply_audio_bus_volume("Master", master_volume)
	_save_config()
	audio_volume_changed.emit("Master", master_volume)


func set_music_volume(val: float) -> void:
	music_volume = clampf(val, 0.0, 1.0)
	apply_audio_bus_volume("Music", music_volume)
	_save_config()
	audio_volume_changed.emit("Music", music_volume)


func set_sfx_volume(val: float) -> void:
	sfx_volume = clampf(val, 0.0, 1.0)
	apply_audio_bus_volume("SFX", sfx_volume)
	_save_config()
	audio_volume_changed.emit("SFX", sfx_volume)


func set_animation_speed(val: float) -> void:
	animation_speed = clampf(val, 0.5, 3.0)
	_apply_animation_speed()
	_save_config()
	animation_speed_changed.emit(animation_speed)


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
