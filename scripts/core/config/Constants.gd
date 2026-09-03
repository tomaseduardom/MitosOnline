extends Node
## Constantes del juego basadas en el DAR de Mitos y Leyendas
## Revisión Septiembre 2025 - Imperio

# =============================================================================
# CONSTRUCCIÓN DE MAZO
# =============================================================================
const DECK_SIZE: int = 50
const MAX_COPIES_PER_CARD: int = 3
const MAX_COPIES_UNIQUE: int = 1
const SIDE_DECK_SIZE: int = 15
const MIN_ALLIES_WEAPONS_TOTEMS: int = 17  # Imperio
const MAX_RACELESS_ALLIES: int = 4  # Imperio Racial

# =============================================================================
# MANO Y ROBO
# =============================================================================
const STARTING_HAND_SIZE: int = 8
const MAX_HAND_SIZE: int = 8
const CARDS_DRAWN_PER_TURN: int = 1

## Escala de las cartas de Oro en Reserva y Oro Pagado (1.0 = tamaño completo estándar)
const GOLD_CARD_SCALE: Vector2 = Vector2(1.0, 1.0)

# =============================================================================
# TIPOS DE CARTA
# =============================================================================
enum CardType {
	ORO,
	ALIADO,
	ARMA,
	TALISMAN,
	TOTEM
}

const CARD_TYPE_NAMES: Dictionary = {
	CardType.ORO: "Oro",
	CardType.ALIADO: "Aliado",
	CardType.ARMA: "Arma",
	CardType.TALISMAN: "Talismán",
	CardType.TOTEM: "Tótem"
}

# =============================================================================
# ZONAS DE JUEGO
# =============================================================================
enum Zone {
	# Zonas dentro del juego (públicas)
	RESERVA_ORO,
	ORO_PAGADO,
	LINEA_DEFENSA,
	LINEA_ATAQUE,
	LINEA_APOYO,
	# Zonas fuera del juego
	CASTILLO,      # Privada (mazo)
	MANO,          # Privada
	CEMENTERIO,    # Pública
	DESTIERRO      # Pública
}

const ZONE_NAMES: Dictionary = {
	Zone.RESERVA_ORO: "Reserva de Oro",
	Zone.ORO_PAGADO: "Oro Pagado",
	Zone.LINEA_DEFENSA: "Línea de Defensa",
	Zone.LINEA_ATAQUE: "Línea de Ataque",
	Zone.LINEA_APOYO: "Línea de Apoyo",
	Zone.CASTILLO: "Castillo",
	Zone.MANO: "Mano",
	Zone.CEMENTERIO: "Cementerio",
	Zone.DESTIERRO: "Destierro"
}

# Zonas que están "en juego"
const ZONES_IN_PLAY: Array = [
	Zone.RESERVA_ORO,
	Zone.ORO_PAGADO,
	Zone.LINEA_DEFENSA,
	Zone.LINEA_ATAQUE,
	Zone.LINEA_APOYO
]

# Zonas públicas (información visible para ambos jugadores)
const ZONES_PUBLIC: Array = [
	Zone.RESERVA_ORO,
	Zone.ORO_PAGADO,
	Zone.LINEA_DEFENSA,
	Zone.LINEA_ATAQUE,
	Zone.LINEA_APOYO,
	Zone.CEMENTERIO,
	Zone.DESTIERRO
]

# =============================================================================
# FASES DEL TURNO (DAR Septiembre 2025 - Sección 5)
# =============================================================================
enum Phase {
	AGRUPACION,          # 5.1 - Aliados pasan a defensa, oros a reserva
	VIGILIA,             # 5.2 - Jugar cartas, poner oro, usar habilidades
	ATAQUE,              # 5.3.1 - Declarar atacantes
	BLOQUEO,             # 5.3.2 - Declarar bloqueadores
	GUERRA_TALISMANES,   # 5.3.3 - Jugar talismanes y habilidades de combate
	ASIGNACION_DANIO,    # 5.3.4 - Resolver daño de combate
	FINAL                # 5.4 - Robar carta, descartar exceso
}

const PHASE_NAMES: Dictionary = {
	Phase.AGRUPACION: "Fase de Agrupación",
	Phase.VIGILIA: "Fase de Vigilia",
	Phase.ATAQUE: "Paso de Ataque",
	Phase.BLOQUEO: "Paso de Bloqueo",
	Phase.GUERRA_TALISMANES: "Guerra de Talismanes",
	Phase.ASIGNACION_DANIO: "Asignación de Daño",
	Phase.FINAL: "Fase Final"
}

# Fases que son parte de la Batalla Mitológica (5.3)
const BATTLE_PHASES: Array = [
	Phase.ATAQUE,
	Phase.BLOQUEO,
	Phase.GUERRA_TALISMANES,
	Phase.ASIGNACION_DANIO
]

# Alias para compatibilidad (deprecado, usar Phase)
const TurnPhase = Phase
const BattleStep = Phase

# =============================================================================
# HABILIDADES KEYWORD (DAR Sección 7-8)
# =============================================================================
enum Keyword {
	# Confirmadas como reales en Mitos y Leyendas (2026-08-20, corrección del
	# usuario — el set anterior mezclaba keywords de otros CCG que no existen
	# en este juego; ver docs/audit-2026-08-13.html para el historial).
	FURIA,              # Puede atacar sin esperar Agrupación
	IMBLOQUEABLE,       # No puede ser bloqueado (sin excepción por keyword —
	                    # si algo puede bloquearlo, lo dice su propio texto)
	INDESTRUCTIBLE,     # No puede ser destruido
	INDESTERRABLE,      # No puede ser desterrado
	UNICA,              # Solo 1 copia en el mazo
	EXHUMAR,            # Puede jugarse desde Cementerio
	ERRANTE,            # Solo puede haber 1 copia de esta carta EN JUEGO a
	                    # la vez (a diferencia de Única, que limita el mazo)
	RETADOR,            # El atacante elige qué Aliado enemigo debe bloquearlo
}

const KEYWORD_NAMES: Dictionary = {
	Keyword.FURIA: "Furia",
	Keyword.IMBLOQUEABLE: "Imbloqueable",
	Keyword.INDESTRUCTIBLE: "Indestructible",
	Keyword.INDESTERRABLE: "Indesterrable",
	Keyword.UNICA: "Única",
	Keyword.EXHUMAR: "Exhumar",
	Keyword.ERRANTE: "Errante",
	Keyword.RETADOR: "Retador",
}

const KEYWORD_DESCRIPTIONS: Dictionary = {
	Keyword.FURIA: "Este Aliado no necesita pasar por una Fase de Agrupación para ser declarado Atacante.",
	Keyword.IMBLOQUEABLE: "Este Aliado no puede ser bloqueado.",
	Keyword.INDESTRUCTIBLE: "Esta carta no puede ser Destruida.",
	Keyword.INDESTERRABLE: "Esta carta no puede ser Desterrada.",
	Keyword.UNICA: "Solo puedes tener una copia de esta carta en tu mazo.",
	Keyword.EXHUMAR: "Puedes jugar esta carta desde tu Cementerio pagando su coste.",
	Keyword.ERRANTE: "Solo puede haber una copia de esta carta en juego al mismo tiempo.",
	Keyword.RETADOR: "El controlador de este Aliado elige qué Aliado enemigo debe bloquearlo.",
}

# NOTA (2026-08-20): "Inmune a X" y "portar múltiples armas" NO son keywords
# fijas en Mitos y Leyendas — son texto libre de cada carta ("no puede ser
# afectada por talismanes", "tus aliados pueden portar un arma adicional").
# Se detectan por texto donde hace falta (ver TriggerSystem._target_text_denies
# y GoldManager._player_has_ally_in_play/lógica de Armas), no como Keyword.

# =============================================================================
# TIPOS DE HABILIDAD
# =============================================================================
enum AbilityType {
	ACTIVADA,      # Se puede usar a voluntad
	DISPARADA,     # Se dispara por un evento
	CONTINUA,      # Efecto permanente mientras está en juego
	CONSTRUCCION   # Afecta la construcción del mazo
}

# =============================================================================
# RAREZAS
# =============================================================================
enum Rarity {
	COMUN,
	POCO_COMUN,
	RARA,
	ULTRA_RARA,
	SECRETA
}

const RARITY_NAMES: Dictionary = {
	Rarity.COMUN: "Común",
	Rarity.POCO_COMUN: "Poco Común",
	Rarity.RARA: "Rara",
	Rarity.ULTRA_RARA: "Ultra Rara",
	Rarity.SECRETA: "Secreta"
}

# =============================================================================
# SEÑALES GLOBALES (eventos del juego)
# =============================================================================
# Estas se usarán para el sistema de habilidades disparadas

const GAME_EVENTS: Array[String] = [
	"card_played",
	"card_entered_play",
	"card_destroyed",
	"card_exiled",
	"card_discarded",
	"card_drawn",
	"ally_attacked",
	"ally_blocked",
	"damage_dealt",
	"damage_received",
	"turn_started",
	"turn_ended",
	"phase_started",
	"phase_ended",
	"ability_activated",
	"ability_triggered"
]
