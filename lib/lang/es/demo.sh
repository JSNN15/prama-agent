# shellcheck shell=bash disable=SC2034
# Spanish catalog for lib/demo.sh (msgid = English text; see lib/i18n.sh)
I18N+=(
  ['The demo is not running: prama-agent demo']='La demo no está corriendo: prama-agent demo'
  ['Demo closed and its sandbox deleted.']='Demo cerrada y su sandbox borrado.'
  ['Usage: prama-agent demo [start|attach|stop]   simulated agents in a sandbox: no tokens, no real fleet touched']='Uso: prama-agent demo [start|attach|stop]   agentes simulados en un sandbox: sin tokens, sin tocar la flota real'
  ['The demo needs git and jq.']='La demo necesita git y jq.'
  ['Building the demo sandbox in %s (simulated agents: no tokens are spent).']='Armando el sandbox de la demo en %s (agentes simulados: no se gastan tokens).'
  ['Could not create the demo zone.']='No se pudo crear la zona de la demo.'
  ['Add a /health endpoint and document the API']='Agregar un endpoint /health y documentar la API'
  ['Could not start the demo team.']='No se pudo iniciar el equipo de la demo.'
  ['Watch the coordinator plan and delegate, the executors commit on their own branches and report, and the merges run the tests.']='Mira cómo el coordinador planifica y delega, los ejecutores hacen commit en sus propias ramas y reportan, y los merges corren los tests.'
  ['An assistant for you appears too (★ in the status bar, Alt+o). Alt+m leaves; prama-agent demo stop deletes it all.']='También aparece un asistente para ti (★ en la barra de estado, Alt+o). Alt+m sale; prama-agent demo stop lo borra todo.'
  ['Open it with: prama-agent demo attach']='Ábrela con: prama-agent demo attach'
  ['The demo keeps running: prama-agent demo attach to go back, prama-agent demo stop to delete it.']='La demo sigue corriendo: prama-agent demo attach para volver, prama-agent demo stop para borrarla.'
)
