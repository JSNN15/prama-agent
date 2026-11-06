# Cómo se construyó prama-agent

[English](HOW-IT-WAS-BUILT.md) · **Español**

prama-agent se escribió con agentes de código de IA, y en el último tramo con equipos de agentes que
el propio prama-agent dirigía. El historial lo muestra: la mayoría de los commits llevan
`Co-Authored-By: Claude`. Esta página explica quién hizo qué, cómo se verificó y qué se rompió en el
camino.

## Por qué existe

Construyo **pramatic**, un producto con varios repositorios (plataforma, landing y monitoreo) que
desarrollo con agentes de código en un servidor remoto, muchas veces desde el celular. prama-agent
empezó como los scripts que mantenían vivos a esos agentes. Cada función nació de un problema concreto
de ese trabajo:

| Problema | Función |
| --- | --- |
| Un corte de SSH mataba a los agentes | servidor tmux dedicado; las sesiones sobreviven (v6.0) |
| Un agente pasaba una hora esperando un login o un límite de uso | salud desde los hooks del CLI, BLOCKED con motivo, trabajo en cola (v6.0) |
| La cuota semanal se acababa en medio de una tarea | telemetría de cuota y alerta al 90 % (v6.0) |
| Un solo coordinador no daba abasto con varios frentes | varios equipos por zona (v6.3) |
| Los agentes en una misma carpeta se pisaban | un worktree y una rama de git por agente, con merge condicionado a los tests (v6.5) |
| Tenía que preguntarle al coordinador qué estaba haciendo | el plan en vivo (v6.6) |
| "Listo" resultaba ser "creo que sí" | `plan verify`: prama corre la verificación de la tarea por su cuenta (v6.7) |

## Quién hizo qué

**Yo:** qué construir y en qué orden, las restricciones, las decisiones de diseño, la revisión y la
decisión de publicar. Las restricciones no han cambiado desde la v6:

- persistencia: la sesión de un agente sobrevive a mi conexión;
- sobrevivir a cortes de SSH;
- determinismo: objetivos tmux exactos, el estado como datos, nunca escribir en un agente que no está
  listo;
- el scrollback nunca se pierde.

Antes de diseñar el plan pedí investigación, tanto de papers como de repositorios y foros de quienes
trabajan con agentes. Dos hallazgos le dieron forma: las tareas preasignadas rinden más que los agentes
que se coordinan solos, y la mayoría de las fallas multiagente son fallas de especificación y de
verificación.

**Los agentes:** la mayor parte del código, los tests y la documentación, dentro de esas restricciones.
La mayor parte la hicieron sesiones de Claude Code. Desde la v6.4 el trabajo también se repartió entre
equipos que dirigía prama-agent. Por ejemplo, la traducción de la interfaz al español se repartió entre
cuatro agentes en paralelo, cada uno en su propio worktree de git. La herramienta también corre trabajo
real sobre pramatic: mientras se escribía la v6.6, un equipo de prama llevó a producción un paquete de
trabajo de pramatic.

**Lo que no se les confía a los agentes:**
- No pueden hacer merge a `main`. Todo cambio pasa por un pull request, y `main` está protegida:
  checks obligatorios, historial lineal, sin force push y reglas que aplican también a los
  administradores.
- No pueden publicar. Los reportes de fallos que crean los agentes quedan en el servidor, y convertir
  uno en un issue de GitHub es un paso explícito que hago yo.

## Cómo se verificó

- **Unas 600 comprobaciones de punta a punta** corren sobre un servidor tmux aislado, con HOME y estado
  privados. Usan agentes simulados cuyos procesos se llaman `claude` y `agy`. Además hay 33 tests
  unitarios del bot de Telegram.
- **CI** corre la suite en Ubuntu 22.04, Debian 12 y Ubuntu 24.04 (tmux 3.2a, 3.3a y 3.4), con un
  usuario sin privilegios cuyo shell de login es `/bin/sh`. También corre shellcheck, actionlint,
  CodeQL y OpenSSF Scorecard. Las actions están fijadas por SHA de commit.
- **Las traducciones** se revisan en el lint con `tools/i18n_check.py`: entradas faltantes,
  marcadores que no coinciden y mensajes dinámicos.
- **Los pantallazos y la demo** se generan desde una flota de demostración real (`make screenshots`,
  `make demo`), no se dibujan a mano.

## Qué se rompió

- **Leer la pantalla no bastaba.** Un agente que *citaba* un mensaje de error en su respuesta quedaba
  marcado como BLOCKED (`f310bf8`). Desde entonces los hooks deciden BLOCKED, y la pantalla solo cuenta
  los diálogos que aparecen antes de que corran los hooks.
- **Portabilidad.** Un filtro de pantalla que funcionaba con gawk fallaba con mawk, el awk por defecto
  de Debian (`74ef686`). La matriz de CI existe por fallos como este.
- **Huecos de autorización encontrados en revisión.** Antes de publicar la v6.5, un ejecutor podía hacer
  merge de la rama de *otro* ejecutor. Ahora solo hacen merge el coordinador o el operador.
- **El orden de evaluación de bash.** En `local i=$1 st=${P_status[i]}`, la segunda asignación se
  expande antes de que exista la primera. Eso ponía las tareas del plan en columnas equivocadas del
  tablero. Los tests lo detectaron antes de publicar.
- **Un tag de versión en el commit equivocado.** Un hilo de revisión de CodeQL bloqueó en silencio el
  merge de la v6.6.0, y el tag quedó en el commit anterior. El workflow de release falló de forma segura
  y no se publicó nada. El tag se rehízo. Ahora los pasos de release confirman el merge antes de
  etiquetar.
- **El README prometía más de lo que hacía el código.** Una auditoría antes del lanzamiento contrastó
  cada afirmación con el código y encontró dos brechas. Primero, los hooks deciden *bloqueado*, pero
  *inactivo* o *trabajando* se sigue leyendo de la pantalla. Segundo, "sin verificar" solo significaba
  que nadie había escrito evidencia, y esa evidencia era el propio texto del agente. El README ahora
  dice exactamente lo que hace el código, y la v6.7 agregó `plan verify` para que "verificada"
  signifique que prama corrió la verificación por su cuenta.

## Números (v6.7.0)

| | |
| --- | --- |
| bash | ~13.000 líneas en `bin/` y `lib/`, en 17 módulos |
| Python | el puente de Telegram (~1.300 líneas) y las herramientas de desarrollo |
| Tests | ~600 comprobaciones de punta a punta y 33 tests unitarios del bot |
| Historial público | de la v5.0.0 (2026-10-28) a la v6.7.0 (2026-11-01). Las versiones anteriores a la 5.0 nunca se publicaron. |

Las decisiones de diseño, con sus costos y alternativas, están en los [ADRs](adr/README.md) (en
inglés).
