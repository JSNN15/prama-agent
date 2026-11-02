# ADR-0006: English source strings as message ids, per-module catalogs

Status: Accepted · Date: 2026-11-01

## Context

Up to 6.3 the interface was Spanish only. 6.4.0 made the whole tool bilingual: menu, CLI, help, the
agents' role prompts and bus messages (so agents report in the operator's language), and the Telegram
bot. Constraints: no new dependency (ADR-0001), hot paths such as the TUI redraw and the status line
must not fork per string, machine-read output must not change with the language, and the language is
known only after `config.env` is loaded.

## Decision

- The message id is the English text: a one-line printf format literal with `%s` / `%d` placeholders.
  `_t 'Unknown zone: %s' "$zone"` prints; `_tv var 'Sessions'` assigns with `printf -v`, without a
  subshell, for hot paths. A missing translation falls back to the English text.
- Translations live in `lib/lang/es/<module>.sh`, one catalog per module, which only add
  `I18N[msgid]=text`. They ship with prama, next to `lib/i18n.sh`, and only the active language is
  loaded. The Telegram bridge uses `_()` with `lib/lang/es/telegram_bot.json`.
- `PRAMA_LANG` is `en`, `es` or `auto` (an `es_*` locale gives Spanish); the environment wins over
  `config.env`. `i18n_init` runs when `lib/i18n.sh` is sourced and again in `prama_load_config` after
  the config files. Strings are translated when used, never at source time.
- Long texts (role prompts, some usage blocks) are written once per language and chosen with
  `case $PRAMA_UI_LANG`.
- Machine contracts are never translated: `--json` and `--porcelain` output, `events.jsonl`, state and
  health keys, the `[PRAMA-SWARM ROLE: …]` marker, Telegram callback data.
- Bus messages typed into agents are translated (`[TASK FROM %s]`, `[REPORT FROM %s]`), so the screen
  parser that skips quoted messages accepts both languages' tags.
- `tools/i18n_check.py` runs in `make lint`. It extracts literal message ids from `_t`, `_tv` and the
  TUI helpers, and fails on a missing translation, a placeholder mismatch, two catalogs translating
  the same id differently, or an id containing a `$` expansion. Today: 1,022 bash and 204 Python ids.

## Consequences

Good:
- The code reads in English and every user-facing string is greppable where it is used.
- Adding a language is a new `lib/lang/<code>/` directory; the checker already takes a list.
- Translation drift fails CI instead of reaching users.

Bad:
- Changing English wording changes the id, so the catalog entry must change too (the checker catches
  it, but it is churn).
- `_t` inside `$(…)` still costs a subshell; only `_tv` is fork-free, so hot paths must use it.
- Per-language long texts are outside the checker and can drift apart; the tests check that the
  English role prompt keeps the machine marker, not that both prompts say the same thing.
- Catalogs are bash files that get `source`d. They are code shipped with prama, never user or state
  files, but they carry the same review burden as code.
- The "never translate machine output" rule is a convention backed by review and tests, not by the
  checker.

## Alternatives considered

- **GNU gettext**: the standard answer, but a dependency (`gettext` at runtime, `msgfmt` to compile
  `.mo` files), and calling `gettext` from bash is one external process per string, too slow for the
  TUI. bash's own `$"…"` avoids the process but still needs compiled catalogs and a matching system
  locale; prama sets `LC_ALL=C.UTF-8` when the locale is not UTF-8, and servers often lack a Spanish
  locale. prama's language is a setting, not a locale.
- **Symbolic keys** (`MSG_UNKNOWN_ZONE`): no churn on rewording, but the code hides the text and a
  missing entry shows a key.
- **Translating at source time** (strings assigned when a module loads): wrong, because the language
  is known only after `config.env`.

## Where in the code

- `lib/i18n.sh`: `i18n_detect`, `i18n_init`, `_t`, `_tv`
- `lib/lang/es/*.sh`, `lib/lang/es/telegram_bot.json`, `_()` in `lib/telegram_bot.py`
- `lib/core.sh`: `prama_load_config`; `screen_block_reason` (tags in both languages)
- `lib/roles.sh`: `build_role_system_prompt`, `_role_prompt_en` / `_role_prompt_es`
- `lib/prefs.sh`: `prefs_set_lang`
- `tools/i18n_check.py`, `Makefile` (`lint`, `i18n`)
- `docs/ARCHITECTURE.md`: invariant 16
