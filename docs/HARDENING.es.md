# prama-agent en un servidor compartido o de producción

[English](HARDENING.md) · **Español**

prama-agent se construyó en un servidor de su autor, con agentes en modo YOLO a propósito. Esa es una
decisión para una máquina que controlas. En un servidor que además corre servicios de producción, guarda
credenciales o pertenece a una organización con reglas sobre herramientas de IA, configúralo como se
describe aquí.

## Qué protege prama y qué no

Las reglas entre agentes (un agente no puede actuar sobre sí mismo ni sobre un coordinador, se queda en
su zona y su equipo, no puede hacer merge si no es el coordinador del equipo, no puede darle a otro
agente más permisos de los que tiene) son **barandas contra errores**. No son una barrera de seguridad.

- **Quien llama se identifica por proceso, y sigue siendo el mismo usuario Unix.** Cuando un comando
  corre bajo el panel de un agente, prama toma la sesión de ese panel como quien llama, diga lo que diga
  `PRAMA_SESSION`. Así, `env -u PRAMA_SESSION prama-agent fleet kill …` ya no convierte a un agente en
  el operador, y el intento queda registrado como evento `identity`. Pero todos los agentes corren con
  tu usuario y pueden leer y escribir los archivos de estado de prama, matar procesos o desprenderse de
  su panel. Un agente que intenta saltarse prama lo logra; por ejemplo, uno que leyó un archivo
  malicioso y lo obedece.
- **Los mensajes entre agentes se teclean en sus terminales.** Las tareas y los reportes le llegan a un
  agente como texto en su prompt. Un reporte es lo que escribió otro agente: uno que leyó un archivo
  hostil puede pasarle esas instrucciones al coordinador. A los coordinadores se les indica que traten
  los reportes como datos. Eso baja el riesgo, pero no lo elimina.
- **Un agente puede hacer lo que puede hacer tu usuario.** Si tu usuario está en el grupo `docker`,
  `sudo` o `lxd`, un agente tiene, en la práctica, acceso de root. Si tu usuario puede leer `~/.pgpass`
  o una carpeta de secretos, el agente también.

El aislamiento real lo da el sistema operativo: un usuario dedicado, un contenedor o una VM.

## Lista de verificación

1. **Un usuario Unix dedicado** para prama y sus agentes, fuera de los grupos `docker`, `sudo` y `lxd`,
   sin acceso a credenciales que no necesita (`~/.pgpass`, carpetas de secretos, claves de la nube).
   Mejor aún, una VM.
2. **Zonas que apunten a clones**, nunca a carpetas montadas en servicios que están corriendo. Con
   recarga en caliente, un merge local en esa carpeta es un deploy instantáneo.
3. **Pull requests en vez de merges locales**: con `PRAMA_MERGE_MODE=pr`, `worktree merge` sube la rama
   y abre un pull request contra la base del equipo (necesita `gh`, con sesión iniciada), y deciden tu CI
   y tu revisión. La copia de la zona nunca se escribe.
4. **Sin YOLO en este servidor**: `PRAMA_ALLOW_YOLO=0` rechaza `--yolo` en todas partes (CLI, menú, API
   de la flota, reinicios de agentes guardados como yolo) y anula `PRAMA_SKIP_PERMISSIONS=1`.
5. **Solo los proveedores autorizados**: deja en `AGENTS=(claude)` únicamente los agentes permitidos, no
   definas `PRAMA_EXPERIMENTAL` (opencode habla con OpenRouter) y usa `PRAMA_PROFILES="default"` para
   que ningún agente pueda apuntar a otro endpoint (OpenRouter, DeepSeek, GLM). Los niveles gratuitos
   suelen guardar los prompts o usarlos para entrenar: nunca les envíes código que no puedes compartir.
6. **Telegram sin pantallas**, o sin Telegram: `PRAMA_TG_SCREENS=0` deja las pantallas de los agentes
   (que pueden mostrar credenciales o datos de clientes) en el servidor, y con `PRAMA_TG_NOTIFY=alerts`
   solo se envían alertas, no el texto de las tareas ni de los reportes.
7. **No compartas carpetas de dependencias entre worktrees** en este servidor: deja `PRAMA_WORKTREE_LINK`
   sin definir. Un `pip install` o `npm install` de un agente cambiaría el entorno de todos los demás.
   Vigila el disco: cada ejecutor de un equipo aislado tiene su propio worktree.
8. **Fija una versión**: `prama-agent update v6.7.0` deja el repo en esa etiqueta; `update` sin versión
   sigue la rama en la que estás.
9. **Pide autorización primero.** Si tu organización tiene una política para herramientas de IA o para
   los proveedores con los que hablan, una herramienta que lanza muchos agentes también la necesita.

## Un `config.env` endurecido

```bash
# Agentes y proveedores
AGENTS=(claude)
PRAMA_PROFILES="default"          # solo las cuentas propias de los agentes, sin endpoints de terceros
# PRAMA_EXPERIMENTAL queda sin definir

# Permisos
PRAMA_ALLOW_YOLO=0                # nada corre sin confirmaciones, sea cual sea el valor por defecto
PRAMA_SKIP_PERMISSIONS=0
PRAMA_FLEET_SCOPE="children"      # un coordinador administra solo a los agentes que lanzó
PRAMA_FLEET_MAX=4

# Integración a través de tu CI, nunca en una carpeta en vivo
PRAMA_MERGE_MODE="pr"
PRAMA_MERGE_TEST="make test"      # solo lo usan los merges locales
# PRAMA_WORKTREE_LINK queda sin definir

# Telegram, si se usa
PRAMA_TG_SCREENS=0
PRAMA_TG_NOTIFY="alerts"
```

Revisa el resultado con `prama-agent doctor`, y reporta cualquier cosa que pase por encima de estos
ajustes como se indica en [SECURITY.md](../SECURITY.md).
