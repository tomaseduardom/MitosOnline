extends Control
## Main - Escena principal del juego. Punto de entrada que instancia módulos y conecta señales.

@export var test_mode: bool = false

# =============================================================================
# ESCENAS PRECARGADAS
# =============================================================================
const CardScene = preload("res://scenes/cards/Card.tscn")
const DropZoneScript = preload("res://scripts/ui/zones/DropZone.gd")
const OpponentFanScript = preload("res://scripts/ui/hand/OpponentFan.gd")
const GameStateScript = preload("res://scripts/core/config/GameState.gd")

# Preloads de módulos (fuerzan registro de class_name antes del parse de Main)
const _ZoneManagerScript      = preload("res://scripts/core/game/ZoneManager.gd")
const _PhaseFlowScript        = preload("res://scripts/core/game/PhaseFlowController.gd")
const _GameHUDScript          = preload("res://scripts/ui/hud/GameHUDModule.gd")
const _GameBootstrapScript    = preload("res://scripts/core/game/GameBootstrap.gd")
const _CardInteractionScript  = preload("res://scripts/ui/hud/CardInteractionModule.gd")
const _SceneSetupScript       = preload("res://scripts/ui/hud/SceneSetupModule.gd")
const _DebugInputScript       = preload("res://scripts/ui/hud/DebugInputModule.gd")

# =============================================================================
# REFERENCIAS A NODOS
# =============================================================================

@onready var turn_label: Label               = $TopBar/TurnLabel
@onready var phase_label: Label              = $TopBar/PhaseLabel
@onready var player_info: Label              = $TopBar/PlayerInfo
@onready var debug_label: Label              = $UI/DebugPanel/DebugLabel
@onready var game_board: Control             = $GameBoard
@onready var player_hand: Control            = $GameBoard/PlayerArea/PlayerHand
@onready var player_field: HBoxContainer     = $GameBoard/PlayerArea/PlayerField
@onready var player_linea_ataque: HBoxContainer = $GameBoard/PlayerArea/PlayerLineaAtaque
@onready var player_linea_apoyo: HBoxContainer  = $GameBoard/PlayerArea/PlayerLineaApoyo
@onready var player_gold: HBoxContainer      = $GameBoard/PlayerArea/PlayerReservaOro
@onready var player_oro_pagado: HBoxContainer= $GameBoard/PlayerArea/PlayerOroPagado
@onready var opponent_field: HBoxContainer   = $GameBoard/OpponentArea/OpponentField
@onready var opponent_linea_ataque: HBoxContainer = $GameBoard/OpponentArea/OpponentLineaAtaque
@onready var opponent_linea_apoyo: HBoxContainer  = $GameBoard/OpponentArea/OpponentLineaApoyo
# Contenedores ya existían en la escena sin usar (2026-08-25): el Oro del
# oponente solo se mostraba como número en OpponentReservaOroLabel/
# OpponentOroPagadoLabel, nunca como carta real — ni siquiera el Oro
# Inicial con el que arranca la partida (ver GameBootstrap._setup_oro_
# inicial(), que para J1 solo hacía agregar_oro_reserva() sin crear nodo).
@onready var opponent_gold: HBoxContainer         = $GameBoard/OpponentArea/OpponentReservaOro
@onready var opponent_oro_pagado: HBoxContainer   = $GameBoard/OpponentArea/OpponentOroPagado
var _opponent_fan: Node = null

@onready var player_castillo_count: Label    = $GameBoard/PlayerArea/PlayerCastillo/Count
@onready var player_cementerio_count: Label  = $GameBoard/PlayerArea/PlayerCementerio/Count
@onready var player_destierro_count: Label   = $GameBoard/PlayerArea/PlayerDestierro/Count
@onready var opponent_castillo_count: Label  = $GameBoard/OpponentArea/OpponentCastillo/Count
@onready var opponent_cementerio_count: Label= $GameBoard/OpponentArea/OpponentCementerio/Count
@onready var opponent_destierro_count: Label = $GameBoard/OpponentArea/OpponentDestierro/Count

@onready var _panel_player_castillo: Panel = $GameBoard/PlayerArea/PlayerCastillo
@onready var _panel_player_cem: Panel = $GameBoard/PlayerArea/PlayerCementerio
@onready var _panel_player_dst: Panel = $GameBoard/PlayerArea/PlayerDestierro
@onready var _panel_opp_cem: Panel    = $GameBoard/OpponentArea/OpponentCementerio
@onready var _panel_opp_dst: Panel    = $GameBoard/OpponentArea/OpponentDestierro

@onready var player_oro_reserva_label: Label   = $GameBoard/PlayerArea/GoldAreaLabel
@onready var player_oro_pagado_label: Label    = $GameBoard/PlayerArea/OroPagadoLabel
@onready var opponent_oro_reserva_label: Label = $GameBoard/OpponentArea/OpponentReservaOroLabel
@onready var opponent_oro_pagado_label: Label  = $GameBoard/OpponentArea/OpponentOroPagadoLabel
@onready var timer_label: Label                = $TurnTimer/VBox/TimerLabel

@onready var mulligan_overlay: Panel      = $UI/MulliganOverlay
@onready var mulligan_hand: MulliganHand  = $UI/MulliganOverlay/MulliganHand
@onready var mulligan_cards_label: Label  = $UI/MulliganOverlay/MulliganCardsLabel
@onready var keep_hand_button: Button     = $UI/MulliganOverlay/MulliganButtons/KeepHandButton
@onready var mulligan_button: Button      = $UI/MulliganOverlay/MulliganButtons/MulliganButton

@onready var inspection_layer: CanvasLayer      = $CardInspectionLayer
@onready var inspection_blur: ColorRect         = $CardInspectionLayer/BlurBackground
@onready var inspection_container: CenterContainer = $CardInspectionLayer/CardContainer

# =============================================================================
# MÓDULOS (hijos Node creados en _ready)
# =============================================================================
var _gold_manager: GoldManager             = null
var _mulligan_ctrl: MulliganController     = null
var _card_inspector: CardInspectionLayer   = null
var _zone_viewer: ZoneViewerModule         = null
var _selection: SelectionModule            = null
var _zone_manager: ZoneManager             = null
var _phase_flow: PhaseFlowController       = null
var _easy_bot: EasyBotController           = null
var _game_hud: GameHUDModule               = null
var _bootstrap: GameBootstrap              = null
var _card_interaction: CardInteractionModule = null
var _scene_setup: SceneSetupModule         = null
var _debug_input: DebugInputModule         = null
var _remote_mirror: RemoteMirrorController  = null
var _state_broadcaster: GameStateBroadcaster = null

# =============================================================================
# ESTADO
# =============================================================================
var _dice_winner: int = 0
var gold_cards: Array = []
var player_deck: Array = []
var opponent_deck: Array = []
var player_cemetery: Array = []
var opponent_cemetery: Array = []
const INITIAL_HAND_SIZE: int = 8  # DAR 4.3

# =============================================================================
# INICIALIZACIÓN
# =============================================================================
func _ready() -> void:
	print("[Main] Escena principal cargada")
	GameManager.game_started.connect(_on_game_started)
	GameManager.game_ended.connect(_on_game_ended)

	# ── Módulos ──────────────────────────────────────────────────────────────
	_scene_setup = SceneSetupModule.new(); _scene_setup.name = "SceneSetupModule"
	add_child(_scene_setup); _scene_setup.setup(self)

	_game_hud = GameHUDModule.new(); _game_hud.name = "GameHUDModule"
	add_child(_game_hud); _game_hud.setup(self)

	_zone_manager = ZoneManager.new(); _zone_manager.name = "ZoneManager"
	add_child(_zone_manager); _zone_manager.setup(self)

	# Multiplayer remoto (2026-09-11, Fase B — docs/plans/2026-09-09-
	# multiplayer-remoto-design.md): si esta instancia es el Anfitrión de una
	# sala de red activa, el jugador 1 lo controla una PERSONA real por
	# network, no la IA. RemotePlayerController extiende EasyBotController y
	# expone la misma superficie pública — ningún otro archivo que llama a
	# _easy_bot.<método> necesitó cambiar.
	if NetworkClient.room_code != "" and NetworkClient.is_host:
		_easy_bot = RemotePlayerController.new()
	else:
		_easy_bot = EasyBotController.new()
	_easy_bot.name = "EasyBotController"
	add_child(_easy_bot); _easy_bot.setup(self)

	# Multiplayer remoto — lado Remoto: si esta instancia es el Remoto de una
	# sala de red activa, RemoteMirrorController es lo que le permite seguir
	# jugando después de mandar su mazo (ver GameBootstrap._send_own_deck_
	# and_wait_for_host()) — sin esto, se quedaría en la pantalla de espera
	# para siempre. No hace nada si esta instancia es el Anfitrión o no hay
	# sala de red activa (chequea NetworkClient en su propio setup()).
	_remote_mirror = RemoteMirrorController.new(); _remote_mirror.name = "RemoteMirrorController"
	add_child(_remote_mirror); _remote_mirror.setup(self)

	# Multiplayer remoto — lado Anfitrión: traduce on_card_entered_play/
	# on_card_left_play (señales que EffectController ya emite) a
	# instrucciones de red para que RemoteMirrorController, del otro lado,
	# pueda reflejar el tablero. Inerte si no hay sala de red activa o esta
	# instancia no es el Anfitrión (chequea NetworkClient en su setup()).
	_state_broadcaster = GameStateBroadcaster.new(); _state_broadcaster.name = "GameStateBroadcaster"
	add_child(_state_broadcaster); _state_broadcaster.setup(self)

	_phase_flow = PhaseFlowController.new(); _phase_flow.name = "PhaseFlowController"
	add_child(_phase_flow); _phase_flow.setup(self)

	_gold_manager = GoldManager.new(); _gold_manager.name = "GoldManager"
	add_child(_gold_manager); _gold_manager.setup(self)

	_card_interaction = CardInteractionModule.new(); _card_interaction.name = "CardInteractionModule"
	add_child(_card_interaction); _card_interaction.setup(self)

	_mulligan_ctrl = MulliganController.new(); _mulligan_ctrl.name = "MulliganController"
	add_child(_mulligan_ctrl); _mulligan_ctrl.setup(self)

	_card_inspector = CardInspectionLayer.new(); _card_inspector.name = "CardInspectorModule"
	add_child(_card_inspector); _card_inspector.setup(self)

	_zone_viewer = ZoneViewerModule.new(); _zone_viewer.name = "ZoneViewerModule"
	add_child(_zone_viewer); _zone_viewer.setup(self)

	_selection = SelectionModule.new(); _selection.name = "SelectionModule"
	add_child(_selection); _selection.setup(self)

	_bootstrap = GameBootstrap.new(); _bootstrap.name = "GameBootstrap"
	add_child(_bootstrap); _bootstrap.setup(self)

	_debug_input = DebugInputModule.new(); _debug_input.name = "DebugInputModule"
	add_child(_debug_input); _debug_input.setup(self)

	VisualManager.setup(self, $Background)

	UIManager.setup({
		"turn_label": turn_label, "phase_label": phase_label,
		"player_info": player_info, "debug_label": debug_label,
		"timer_label": timer_label,
		"player_castillo_count": player_castillo_count,
		"player_cementerio_count": player_cementerio_count,
		"player_destierro_count": player_destierro_count,
		"opponent_castillo_count": opponent_castillo_count,
		"opponent_cementerio_count": opponent_cementerio_count,
		"opponent_destierro_count": opponent_destierro_count,
		"player_oro_reserva_label": player_oro_reserva_label,
		"player_oro_pagado_label": player_oro_pagado_label,
		"opponent_oro_reserva_label": opponent_oro_reserva_label,
		"opponent_oro_pagado_label": opponent_oro_pagado_label,
	})

	_bootstrap.start()


# =============================================================================
# CARTA — fábrica y señales
# =============================================================================
func _create_card(data: Dictionary, is_hidden: bool = false) -> Node:
	var card = CardScene.instantiate()
	card.load_from_data(data, is_hidden)
	return card


func _connect_card_signals(card: Node) -> void:
	card.card_clicked.connect(_card_interaction._on_card_clicked)
	card.card_double_clicked.connect(_card_interaction._on_card_double_clicked)
	card.card_right_clicked.connect(_card_inspector.on_card_right_clicked)
	card.card_hovered.connect(_card_interaction._on_card_hovered)
	card.card_unhovered.connect(_card_interaction._on_card_unhovered)
	card.card_dropped.connect(_card_interaction._on_card_dropped)


# =============================================================================
# CALLBACKS DEL GAMEMANAGER
# =============================================================================
func _on_game_started() -> void:
	_update_debug("Partida iniciada!")

func _on_game_ended(winner: int) -> void:
	_update_debug("Jugador %d gana!" % (winner + 1))
	UIManager.set_phase_text("VICTORIA!")

func _update_buttons_for_phase(_phase: Constants.Phase) -> void:
	pass

func get_deck_size(player_id: int) -> int:
	return CardManager.get_deck_count(player_id)

func _sync_oro_ui() -> void:
	UIManager.update_oro_reserva(0, GameState.get_oro_reserva(0))
	UIManager.update_oro_pagado(0, GameState.get_oro_pagado(0))
	UIManager.update_oro_reserva(1, GameState.get_oro_reserva(1))
	UIManager.update_oro_pagado(1, GameState.get_oro_pagado(1))


# =============================================================================
# DEBUG
# =============================================================================
# Los atajos de teclado F1-F9/ESC y el _input() que los procesa se movieron a
# DebugInputModule.gd (2026-08-28, a pedido del usuario: "el main es para
# arrancar la app", eso es tooling de runtime, no arranque). _update_debug()
# se queda acá porque es infraestructura mínima usada por TODO el proyecto
# (142 llamadores vía _main._update_debug()) — sacarla implicaría tocar cada
# uno de esos archivos por puro cosmética, sin beneficio real.
func _update_debug(text: String) -> void:
	UIManager.show_debug(text)
	print("[Main] %s" % text)
