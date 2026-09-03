# Ventana de Prevención reactiva (DAR — Utilizar Habilidades: Prevenir)

Fecha: 2026-09-02
Estado: diseño validado, pendiente de implementación

## Problema

Hoy las cartas de Prevención (Estaca, Legión Paladín, Drácula, Paladín Bestiarium) se activan
como una **carga guardada**: el jugador las usa por adelantado ("dejo esto listo por si acaso"),
y `EffectController._try_consume_leave_play_prevention()` la consume en silencio la próxima vez
que algo intenta sacar esa carta de juego.

Esto no es como funciona Prevenir en el DAR real: el jugador debería poder decidir **en el momento
exacto** en que un efecto está por afectar a una carta, no tener que adivinar antes. Se necesita una
ventana de respuesta real: pausar antes de aplicar el efecto, preguntar, y solo entonces resolver.

## Reglas DAR confirmadas (con el usuario, juez de Mitos y Leyendas)

1. **"Prevenir que una carta sea afectada por un efecto"** aplica a la carta mientras está **EN
   JUEGO**. No aplica a Castillo (mazo) ni a la mano — buscar, descartar, dañar el Castillo, etc.
   quedan fuera. Ejemplo confirmado: si Aho destierra un Aliado + 5 cartas del tope del Castillo,
   Estaca puede prevenir que el Aliado salga, pero las 5 del Castillo se destierran igual — son
   dos efectos independientes, y Estaca solo alcanza al que afecta a una carta en juego.

2. **Los COSTOS nunca son "efectos"**, no se pueden prevenir. Si una habilidad dice "Puedes
   Barajarla [a sí misma] para Destruir una carta de coste 2 o menos" (Miguel Grau, myl_id 20508),
   el autobarajado es el costo — nadie lo previene, ni el propio dueño. El Destruir sí es el
   efecto, y ESE sí es prevenible si el objetivo elegido está en juego.

3. **"Efecto oponente" vs "un efecto"** — depende del texto de CADA carta de Prevención:
   - Estaca: "prevenir que una carta sea afectada por un efecto **oponente**" — solo cubre
     efectos cuya fuente controla el rival de quien la usa.
   - Ngenchen-estilo: "prevenir **un efecto**" sin calificador — cubre cualquier efecto, sin
     importar de quién sea la fuente (incluso el propio).
   - Drácula: su propio texto nombra explícitamente Anular/Cancelar como parte de lo que
     previene — Estaca, en cambio, NO cubre Anular/Cancelar porque esos no "afectan" a la carta
     en el sentido que su texto exige (la carta no cambia de estado por Anular/Cancelar per se).

4. **Inmunidad a Prevención es POR EFECTO PUNTUAL, no por carta entera.** Duelo Espacial
   (myl_id 20612): "Busca una carta... ponlo en tu Oro Pagado... **Este efecto no puede ser
   prevenido**." — la frase de inmunidad está pegada solo a esa oración; su segunda habilidad
   (robar en Vigilia) no tiene esa protección.
   Distinto de Cancha Rayada (myl_id 20339) / Psicofonía: "No se pueden jugar ni utilizar
   habilidades... mientras juegas este Talismán" — esto cierra la ventana de respuesta COMPLETA
   para toda la resolución de esa carta (bloquea Prevención y cualquier otra cosa reactiva), no
   es una excepción puntual.

## Alcance de esta implementación

Familia de efectos que sacan a una carta de su zona de juego (confirmado necesario, cartas reales
ya identificadas):

- **Destruir** → `EffectController.destroy_card()`
- **Desterrar** → `EffectController.exile_card()`
- **Barajar de vuelta al Castillo** → `ActionModule.return_to_deck()` (hoy sin NINGÚN chequeo de
  Prevención, ni siquiera el viejo sistema de carga — hueco real a cerrar)
- **Convertir con cambio de zona** (tipo Jormundgander: Aliado → Oro → Oro Pagado)

Más, sumado ahora a pedido del usuario porque ya existe una carta real que lo necesita:

- **Cambio de Fuerza de un solo golpe** (Dulce Canasta, myl_id 20255: "un Aliado gana o pierde 2
  de Fuerza permanentemente") — un efecto que NO saca a la carta de juego, pero sí la "afecta"
  mientras está en juego.

Explícitamente NO en este alcance (otro tipo de mecanismo, no ventana de Prevención):
- Protecciones PASIVAS continuas tipo "Si está en tu Reserva, los Aliados de coste 1 o menos no
  pueden ser Desterrados" (tercera habilidad de Dulce Canasta) — eso es un aura, mismo patrón que
  la inmunidad a Talismanes de Espíritu Kotaix (`ContinuousEffectManager` + `protection_type`).

## Arquitectura: por qué tiene que ser escalable

El usuario pidió explícitamente que el diseño soporte tipos de efecto que todavía no se
mencionaron. La solución NO es una cadena de `if` por carta en cada choke point (no escala: cada
carta nueva de Prevención, o cada tipo de efecto nuevo, obligaría a tocar código en varios lugares
distintos). En cambio:

### 1. Un solo punto de entrada genérico

```gdscript
# PreventionSystem.gd (nuevo autoload, o método de EffectController)
func offer_prevention(affected_card: Node, effect_source: Node, effect_tag: String, is_immune: bool = false) -> bool
    # Returns: true si el efecto quedó PREVENIDO (el llamador debe abortar la acción)
```

- `affected_card`: la carta que el efecto está por afectar.
- `effect_source`: qué carta/nodo causa el efecto (para decidir "oponente" vs "propio").
- `effect_tag`: string corto que identifica el TIPO de efecto ("leave_play", "strength_change",
  y lo que aparezca después — "damage", "lose_ability", etc.). Cada carta de Prevención declara
  contra cuáles `effect_tag` protege.
- `is_immune`: el llamador lo pasa en `true` cuando el efecto puntual que se está resolviendo
  tiene su propio "esto no puede ser prevenido" (Duelo Espacial) — corta la función al toque, sin
  siquiera mirar candidatos.

Cada choke point actual (`destroy_card`, `exile_card`, `return_to_deck`, el futuro
`apply_strength_change` de Dulce Canasta, y cualquiera que se agregue después) llama a
`offer_prevention()` UNA vez, con su propio `effect_tag`, antes de aplicar el efecto de verdad.
Ninguno necesita saber qué cartas de Prevención existen — eso vive en el registro.

### 2. Registro de cartas de Prevención (no una cadena de `if`)

Un diccionario/array chico, un entry por carta de Prevención ya detectada (reusa la MISMA
detección por texto que ya existe en `PreventionAbilityHandler.gd`/`CardInspectionLayer.gd`, no
la duplica):

```gdscript
# cada entry: {effect_tags: Array[String], opponent_only: bool, resolver: Callable}
_prevention_registry = [
  {
    "detect": func(text): return "prevenir que una carta sea afectada por un efecto oponente" in text, # Estaca
    "effect_tags": ["leave_play"],
    "opponent_only": true,
    "resolver": _prevention_handler._activate_estaca_banish_for_prevention,
  },
  {
    "detect": func(text): return "prevenir que un aliado sea afectado" in text, # Legión Paladín, etc.
    "effect_tags": ["leave_play"],
    "opponent_only": true,
    "resolver": ...,
  },
  {
    "detect": func(text): return "anulado o una habilidad cancelada" in text, # Drácula
    "effect_tags": ["annul", "cancel"],
    "opponent_only": true,
    "resolver": ...,
  },
  # Sumar acá cada carta nueva de Prevención — un entry, nada más.
]
```

`offer_prevention()` filtra el registro por: candidato controlado por el dueño de `affected_card`,
sin usar todavía, `effect_tag` incluido en `effect_tags`, y (si `opponent_only`) que
`effect_source` sea del rival. Con 0 candidatos, no pregunta nada (sigue como si no existiera el
sistema). Con 1+, abre la pregunta (solo para el jugador humano — el bot no actúa todavía, mismo
límite ya documentado en el resto del proyecto).

### 3. Agregar un `effect_tag` nuevo más adelante

Cuando aparezca un tipo de efecto que hoy no está cubierto (daño directo a un Aliado, perder una
habilidad, lo que sea): el choke point nuevo llama a `offer_prevention(card, source, "el_tag_nuevo")`,
y cualquier carta de Prevención cuyo texto real cubra ese tag se suma al registro. No hace falta
tocar ningún choke point existente.

## Piezas concretas a construir

1. `ActionModule.return_to_deck()` — agregar parámetro `bypass_prevention: bool = false` (mismo
   patrón que ya tiene `exile_card()`), y el chequeo real vía `offer_prevention(..., "leave_play")`
   cuando NO es bypass.
2. `EffectController.destroy_card()`/`exile_card()` — reemplazar `_try_consume_leave_play_prevention()`
   (carga guardada) por `offer_prevention(..., "leave_play")` reactivo. Decidir si la carga guardada
   vieja se elimina del todo o queda como fallback — a definir en el plan.
3. Convertir-con-cambio-de-zona (Jormundgander) — sumar el mismo llamado en
   `GoldManager.convert_ally_to_gold_in_pagado()`.
4. Nuevo choke point para cambio de Fuerza de un solo golpe (para poder implementar Dulce Canasta
   más adelante) con `effect_tag = "strength_change"`.
5. El registro de cartas de Prevención (`_prevention_registry`), poblado con las 4 ya
   implementadas (Estaca, Legión Paladín, Drácula, Paladín Bestiarium) usando sus detecciones de
   texto YA existentes.
6. UI: una pregunta simple (sí/no, o elegir cuál si hay más de una candidata) en el momento exacto
   — reusar `SelectionManager.await_two_choice`/`await_single_pick`, mismo patrón que el resto del
   proyecto.

## Fuera de alcance (a propósito)

- Bot/rival usando Prevención — el proyecto entero todavía no tiene un rival que actúe solo.
- Efectos en Castillo/mano (buscar, descartar, daño al Castillo) — confirmado que Estaca-estilo no
  los cubre.
- Protecciones pasivas continuas (Dulce Canasta cláusula 3) — otro sistema, no esta ventana.
