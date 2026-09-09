# Multiplayer remoto (Anfitrión-Remoto vía relay propio)

Fecha: 2026-09-09
Estado: diseño validado, pendiente de implementación

## Problema

Hoy MitosOnline es 100% local: un solo proceso Godot corre `Main.tscn` con "jugador 0" (humano
local) y "jugador 1" (controlado por `EasyBotController`) en la misma sesión. No hay ninguna capa
de red. El objetivo es poder jugar contra **otra persona real**, desde cualquier lugar (no solo
LAN), usando al menos los mazos ya cacheados localmente (`CardDatabase` — catálogo completo,
`DeckLoader` — mazos concretos vía `user://decks/`), sin depender de la API Nuxt en vivo durante
la partida.

## Decisiones de arquitectura (validadas con el usuario)

1. **Alcance de red**: internet, no solo LAN — los dos jugadores pueden estar en cualquier lado.
2. **Transporte/servidor intermedio**: relay propio, chico (Node/Bun/Python), sin ninguna noción
   de reglas de Mitos y Leyendas — solo agrupa conexiones por código de sala y reenvía ciegamente
   los mensajes de un jugador al otro. Hosteado gratis (Railway/Fly.io/Render). Se descartó reusar
   Supabase Realtime (protocolo Phoenix Channels a mano en GDScript, más trabajo de integración) y
   WebRTC P2P (señalización + posible TURN de respaldo, más piezas móviles para un proyecto hobby).
3. **Modelo de simulación**: **Anfitrión-autoritativo total**. Un cliente ("Anfitrión") corre el
   motor completo exactamente como hoy corre contra el bot — `GameManager`, `EffectController`,
   `TriggerSystem`, todo sin cambios de fondo — para jugador 0 (el propio Anfitrión) y jugador 1
   (el Remoto). El otro cliente ("Remoto") corre la misma escena pero en modo espejo: no simula
   nada, solo manda intenciones y aplica instrucciones. Se descartó servidor dedicado (requeriría
   desacoplar todo el motor de la UI/escena, refactor grande) y lockstep (el motor usa
   temporizadores, animaciones y azar no determinístico — `randf()`, `.shuffle()` — alto riesgo de
   desincronización entre 2 simulaciones paralelas).
4. **Autoridad y trampa**: aceptado explícitamente por el usuario — el Anfitrión, al correr todo,
   tiene en memoria el estado completo (incluida la mano del Remoto). Para un entorno entre amigos
   esto es 100% aceptable; no hay validación anti-trampa más allá de la que ya existe para un solo
   jugador.
5. **Latencia**: un relay agregando 100-300ms de ping es imperceptible en un juego de cartas por
   turnos (confirmado por el usuario) — no hace falta optimizar para esto.

## Reemplazo del punto de enganche del bot

Hoy `EasyBotController` decide por "jugador 1" en cada punto donde el motor necesita una decisión
(jugar Aliado, poner Oro, declarar atacantes, responder un diálogo de `SelectionManager`). En modo
multiplayer se agrega `RemotePlayerController` — mismo rol estructural, pero en vez de decidir con
lógica propia, espera y aplica los mensajes `intent` que llegan por red desde el Remoto real. Los
mismos choke points ya usados por el bot (`GoldManager`, `TriggerSystem`, `SelectionManager`)
quedan intactos; solo cambia quién alimenta la decisión.

## Protocolo: instrucciones, no snapshots (niebla de guerra)

El motor ya tiene, sin saberlo, la información necesaria para resolver la niebla de guerra: cada
carta ya tiene un flag `esta_oculta`, y las zonas ya están clasificadas en públicas
(`Constants.ZONES_IN_PLAY`, Cementerio, Destierro, Oro) vs. privadas (Mano, Castillo/mazo). El
protocolo de red reusa ese mismo criterio en vez de inventar uno nuevo.

**Anfitrión → Remoto (instrucciones)**: en cada punto donde el motor hoy mueve/crea/revela una
carta, además de aplicarlo localmente, el Anfitrión emite una instrucción, p.ej.:
`{"op": "move_card", "card_id": 45, "from": "deck:opponent", "to": "hand:opponent", "data": null}`.

- Perspectiva **relativa al receptor**, no `player_id` crudo: las cartas del propio Anfitrión se
  etiquetan `"own": false` (es decir, "opponent" desde el punto de vista del Remoto) y las del
  Remoto `"own": true`. Así el cliente Remoto reusa sus propios contenedores `player_*`/
  `opponent_*` sin transformar nada — "own" siempre va a `player_*` (abajo), igual que cualquiera
  espera ver sus propias cartas.
- Si la carta es del Remoto o va a una zona pública, `data` lleva la carta completa (nombre,
  coste, habilidad, imagen). Si es la mano/mazo del Anfitrión, `data` es `null` — el Remoto solo
  sabe que "algo" se movió ahí y renderiza un dorso genérico.
- Una revelación posterior (Muestra/Mira/etc.) llega como instrucción `reveal_card` separada, con
  los datos recién en ese momento — igual que hoy pasa localmente al voltear `esta_oculta`.
- El Remoto **nunca reconstruye el estado por su cuenta**: solo aplica la secuencia de
  instrucciones en orden sobre su propia copia de la escena. Es un reproductor, no un segundo
  motor.

**Remoto → Anfitrión (intenciones)**: `{"op": "intent", "kind": "play_card", "card_id": 12}`,
`{"op": "intent", "kind": "answer_selection", "picked": "..."}`. El Anfitrión decide si son
legales (reusando las validaciones que ya existen) y, si corren, genera las instrucciones de
arriba.

**Sin ejecución local optimista**: un clic del Remoto no mueve nada en su pantalla al tiro — se
manda como `intent` y la carta recién se mueve cuando llega la instrucción de confirmación del
Anfitrión. Evita cualquier desincronización visual (el Remoto nunca "adivina" el resultado); el
costo en latencia percibida es despreciable para este tipo de juego.

## Sala y mazos

Quien arranca de Anfitrión pide al relay un código corto de sala; se lo pasa a la otra persona por
fuera del juego (Discord/WhatsApp/etc.). El Remoto ingresa ese código y el relay los junta.

Intercambio de mazo: el Remoto NO manda su mazo completo con datos de cada carta — manda solo la
lista de IDs/slugs de las cartas de su mazo (paquete chico). El Anfitrión resuelve esos IDs contra
su propio `CardDatabase` local (mismo catálogo bundleado/cacheado en ambos lados) y arma
`opponent_deck` igual que hoy hace `GameBootstrap` con mazos de prueba — mismo camino, otra fuente
de datos. Si el Anfitrión no puede resolver alguna carta (cache desactualizado), se rechaza la
conexión con un mensaje claro en vez de arrancar con huecos.

Orden de arranque: conectar a sala → Remoto manda su lista de mazo → Anfitrión confirma que pudo
resolverlo todo → arranca el flujo normal ya existente (duelo de dados, mulligan, etc.) sin
tocarlo — la única diferencia es que las decisiones del jugador 1 (mulligan, elegir mazo) llegan
como `intent` de red en vez de clics locales o lógica del bot.

## Manejo de errores

Si cualquiera de los dos se desconecta (se cae el Remoto, el Anfitrión, o el relay), **la partida
termina ahí**, con un aviso claro, sin intento de reanudar — decisión deliberada por simplicidad
(YAGNI). El protocolo de instrucciones ya deja la puerta abierta para agregar reconexión más
adelante sin rediseñar nada (el Anfitrión podría guardar la secuencia de instrucciones y
reenviarla entera a quien se reconecte), pero eso queda fuera de esta v1.

Sin timeouts por acción — esperar una decisión de la otra persona, sin importar cuánto tarde, ya
es como funciona hoy localmente con `SelectionManager`.

## Alcance de la v1

**Entra:**
- 1 Anfitrión + 1 Remoto, una sala por partida, código corto vía relay.
- Relay propio chico, sin lógica de juego (solo reenvío ciego por sala).
- Intercambio de mazo por lista de IDs sobre el catálogo local cacheado (sin Nuxt en vivo).
- `RemotePlayerController` (mismo rol que `EasyBotController`) aplicando `intent` de red.
- Protocolo de instrucciones con niebla de guerra y perspectiva relativa "own"/"opponent".
- Desconexión = fin de partida con aviso, sin reconexión.
- Todo lo que ya audita el motor hoy (triggers, prevención, etc.) sigue funcionando igual del lado
  del Anfitrión — el Remoto no necesita saber nada de eso, solo reproduce instrucciones.

**Queda explícitamente afuera (para después):**
- Reconexión tras desconexión.
- P2P/WebRTC.
- Espectadores, más de 2 jugadores, chat in-game.
- Habilidades ACTIVADAS del bot (tema aparte, ya pendiente por separado) — para el Remoto sí
  funcionan igual que para un humano local, porque activar una habilidad es un clic más que pasa
  por el mismo gate de `intent`.
- Cualquier validación anti-trampa del lado del Anfitrión más allá de la que ya existe hoy.

## Verificación

Prueba manual (no automatizada): primero 2 instancias de Godot en la misma máquina contra el
relay ya desplegado (valida sala + protocolo sin depender de 2 personas distintas disponibles),
después con otra persona real en otra red.

## Pendiente de definir (siguiente tema)

Tiempo de respuesta / timeouts en la ventana de decisión del Remoto — a discutir en la próxima
sesión de diseño.
