# Changelog — sygen-install

Дополняет git commit history. До Phase 2c этот файл отсутствовал —
relevant изменения были видны через `git log --oneline`. Сохраняется
для совместимости с release-pipeline ниже когда у install.sh появится
own versioning.

## Unreleased

### Changed

- **Phase 2c (Antigravity migration)**: install.sh теперь ставит
  Antigravity CLI (`agy`) вместо `@google/gemini-cli`. Google
  deprecating Gemini CLI free tier 18 июня 2026.
  - Новый helper `install_agy_cli` качает single ~140 MB Go binary
    через `curl -fsSL https://antigravity.google/cli/install.sh | bash`
    и кладёт в `$HOME/.local/bin/agy`. Binary tracked через
    `manifest_record_binary_installed` (не через npm bucket — нет
    npm-пакета).
  - `EFFECTIVE_GEMINI_CLI_PATH` переименован в `EFFECTIVE_AGY_PATH`;
    .env теперь эмитит `AGY_CLI_PATH=...` вместо `GEMINI_CLI_PATH=...`.
    Plist key переименован: `__GEMINI_CLI_PATH__` →
    `__AGY_CLI_PATH__`, `<key>GEMINI_CLI_PATH</key>` →
    `<key>AGY_CLI_PATH</key>`.
  - sygen-core продолжает читать `GEMINI_CLI_PATH` как legacy
    fallback для plist'ов, созданных до 2026-05-22 — back-compat
    safety net, не break.
  - Юзер реавторизуется отдельно после установки через
    `agy auth login` (новый OAuth client_id, refresh-token из
    gemini-cli не работает с Antigravity).
- `scripts/test_gemini_codex_install.sh` обновлён под новую сетку
  Antigravity-binary + Codex-npm, плюс negative assertion: легаси
  `<key>GEMINI_CLI_PATH</key>` не должен оставаться в plist
  template.
- `README.md` секция "Agent CLIs" описывает новый layout: Claude (npm)
  + Antigravity (curl|bash) + Codex (npm).
