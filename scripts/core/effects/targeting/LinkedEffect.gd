extends RefCounted
class_name LinkedEffect
## LinkedEffect — Datos de una vinculación entre una carta de respuesta y su
## objetivo en la pila (DAR Sección 8: Anular/Cancelar). Extraído de
## TargetSelector.gd (Fase 4 de reestructuración) para poder tipar
## referencias desde LinkedEffectRegistry.gd — TargetSelector.gd es un
## autoload sin class_name (colisionaría con su propio nombre de autoload).

var response_stack_id: int = -1      # ID de la carta de respuesta en la pila
var target_stack_id: int = -1        # ID del objetivo en la pila
var effect_type: int = 0             # SelectionType (ANNUL/CANCEL)
var source_card: Dictionary = {}     # Datos de la carta fuente
var target_card: Dictionary = {}     # Datos del objetivo
var created_at: int = 0              # Timestamp
var is_pending: bool = true          # Aún no ejecutado
