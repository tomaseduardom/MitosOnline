extends RefCounted
class_name ActionBlock
## ActionBlock — Datos de un bloque de acción colapsable del CombatLog
## (DAR Sección 18). Extraído de CombatLog.gd (Fase 4 de reestructuración)
## para poder tipar referencias desde DetailedPlayLog.gd — CombatLog.gd es
## un autoload sin class_name (colisionaría con su propio nombre de autoload).

var id: int = 0
var card_name: String = ""
var display_name: String = ""     # Nombre con prefijos ([EXHUMAR], etc.)
var card_data: Dictionary = {}
var player_id: int = 0
var started_at: float = 0.0
var steps: Array[Dictionary] = []
var is_collapsed: bool = false
var cost_breakdown: Dictionary = {}
var has_x_cost: bool = false
var instance_x: int = -1
var total_cost: int = 0
var was_annulled: bool = false
var annuller_name: String = ""
# Trazabilidad de origen
var via_exhumar: bool = false     # Jugada desde Cementerio → Destino: Destierro
var source_zone: int = -1         # Zona de origen
