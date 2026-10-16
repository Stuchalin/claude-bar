# ClaudeBar — черновик дизайна (brainstorm)

Статус: обсуждение технических решений (Claude ↔ Codex). Бизнес-решения уже приняты пользователем.

## Задача (принято пользователем)

macOS-приложение в менюбаре, показывающее лимиты подписки Claude, когда трафик идёт через
self-hosted прокси https://github.com/shanuflash/claude-code-proxy (CodexBar не может — ходит на
api.anthropic.com напрямую с локальными OAuth-кредами, которых на машине нет).

- Показывать: 5-часовой лимит (Session), недельный (Weekly), недельный по модели (weekly_scoped, сейчас Fable), Extra usage.
- Графики использования + прогноз расходования, как в CodexBar.
- Визуал — полностью стиль CodexBar. Только macOS.
- Подход A (выбран): своё небольшое приложение, не форк CodexBar.
- Иконка: две полоски CodexBar (верх 5ч, низ неделя, заливка = остаток) + большой серый логотип Claude водяным знаком позади (alpha ~0.3), вырезанный с зазором ~1px вокруг полосок.

## Факты, проверенные в этой сессии

- Прокси (`server.js`) форвардит ЛЮБОЙ путь на `api.anthropic.com` (`path: req.url`), сам подставляет
  `Authorization: Bearer <oauth>` и добавляет `anthropic-beta: oauth-2025-04-20`, вырезает `x-proxy-secret`.
- `GET {ANTHROPIC_BASE_URL}/api/oauth/usage` с `x-proxy-secret` → HTTP 200. Ключевые поля ответа:
  `five_hour{utilization,resets_at}` (resets_at = null, когда окно не начато), `seven_day{...}`,
  `limits[]{kind: session|weekly_all|weekly_scoped, group, percent, severity, resets_at, scope.model.display_name, is_active}`,
  `extra_usage{is_enabled, monthly_limit, used_credits, utilization, currency, ...}`, `spend{...}`,
  много экспериментальных null-полей (`cedar_ember`, `amber_gauge`, ...).
- CodexBar 0.77.1 исходники склонированы в /tmp/codexbar-src (read-only). Ключевые места:
  - Иконка: `Sources/CodexBar/IconRenderer.swift` (18×18pt template, 2x bitmap, PixelGrid, верх RectPx(y:19,h:12), низ RectPx(y:5,h:8), ширина 30px).
  - Меню: NSStatusItem + NSMenu с `NSMenuItem.view = NSHostingView(SwiftUI)`; ширина 310 (`StatusItemController+Menu.swift:10`); раскладка `UsageMenuCardLayout.swift`, `MenuCardMetricRow.swift`, `UsageProgressBar.swift`.
  - Прогноз: `Sources/CodexBarCore/UsagePace.swift`, тексты `Sources/CodexBar/UsagePaceText.swift`.
  - История: `PlanUtilizationHistoryStore.swift` (часовой пик, retention 24*730), `UsageStore+PlanUtilization.swift`.
  - Графики: `QuotaBurndownChartMenuView.swift`/`QuotaBurndownModel.swift`, `PlanUtilizationHistoryChartMenuView.swift`.
  - Claude fetch: `Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageFetcher.swift`, маппинг `ClaudeUsageFetcher.swift:955-1040`.

## Предлагаемые технические решения (на обсуждение)

1. Стек: Swift 6.2, macOS 14+, SPM (без Xcode-проекта), свой скрипт сборки .app + ad-hoc подпись. AppKit NSStatusItem/NSMenu + NSHostingView, Swift Charts. Без сторонних зависимостей.
2. Модули: `ClaudeBarCore` (UsageClient, UsageSnapshot, HistoryStore, UsagePace — тестируемо без UI) + `ClaudeBar` (StatusItemController, IconRenderer, карточки, графики, Settings).
3. Опрос: интервал по умолчанию 5 мин (manual/1/2/5/15/30), + при открытии меню (троттлинг 30с), + на `NSWorkspace.didWakeNotification`. Таймаут 30с. 429 → Retry-After или cooldown 5 мин.
4. Парсинг: tolerant Codable; Session←five_hour (300 мин), Weekly←seven_day (10080), scoped←limits[kind=weekly_scoped], extra←extra_usage (центы/100). five_hour.resets_at == null → «100% left · not started», без прогноза.
5. История: `~/Library/Application Support/ClaudeBar/history.json`, схема как у CodexBar. Отличие: писать замер только при изменении usedPercent/resetsAt + heartbeat раз в час (у CodexBar часовой пик → для 5ч окна всего 5 точек). Retention 1 год. Атомарная запись.
6. Прогноз: формула CodexBar 1:1 (linear pace, пороги 2/6/12, не показывать при expected < 3%).
7. Настройки: URL прокси, секрет в Keychain, интервал, launch at login (SMAppService).

## Решения после обсуждения с Codex (2026-10-17) — заменяют пункты выше при расхождении

1. **Сборка:** SPM + небольшой скрипт упаковки .app (по образцу `Scripts/package_app.sh` CodexBar, без его обвязки), `LSUIElement`. Стабильные bundle ID и путь установки.
   Первая задача — smoke: запуск бандла из Finder, Settings, Keychain save/read после пересборки, SMAppService enable/disable + реальный логин. Если ad-hoc ломает Keychain/логин — пробуем стабильную локальную подпись (без обещания, что она чинит SMAppService, см. TN2206). Plaintext-файл и memory-only секрет — вне v1, только решением пользователя.
2. **История:** системный SQLite3 (`import SQLite3`, есть в SDK: `module.modulemap` + `libsqlite3.tbd`), маленький Swift-адаптер, одно сериализованное соединение.
   Таблица runs: run id, stream id, firstSeenAt, lastSeenAt, value (Double), resetsAt, reset identity, schemaVersion. Закрытие/открытие run — в одной транзакции. lastSeenAt продлевается на каждом успешном опросе; синтетических heartbeat нет.
   Явные break-записи при ошибках опроса / пропавшей метрике; не склеивать через сброс, смену источника, долгий оффлайн. Порог разрыва 2.5×интервал — только для отображения; новый интервал ретроактивно не применяется; ручной режим без каденса. Размер оценивать по Double + частоте опроса. Retention и даунсэмплинг графиков — отдельно.
3. **Идентичность:** прокси всегда на одном аккаунте Claude (подтверждено пользователем) — профили/мультиаккаунт не нужны. stream id = нормализованный URL прокси + metric id + model id (не display_name). Действие «Clear history». Документировать: смену аккаунта на прокси обнаружить нельзя.
4. **Настройки/секрет:** явные настройки — источник истины; не подтягивать молча `ANTHROPIC_*` и не читать shell rc. Опционально — разовый «Import from environment» (только `x-proxy-secret`, с превью адреса до запроса). Должно работать без этих env. Секрет только в Keychain, не в URL/query, не логировать заголовки, не пересылать секрет при cross-origin редиректе; явная склейка URL с path-префиксом.
5. **Ошибки:** прокси зеркалит статус/тело апстрима (`server.js:1011-1017`), поэтому 401/403/502 неоднозначны (403: апстрим, policy `:946` или expiry `:903`; 502: нет токена `:986` или транспорт `:1028`). Узнаём известные тела прокси → конкретная подсказка, иначе общий auth/access/server error.
   UI: состояние соединения отдельно от последнего успешного снимка. Первая загрузка — плейсхолдер; первая ошибка — unknown-полоски + ошибка + Retry/Settings; ошибка с кешем — последние значения как stale + время успеха + строка ошибки, прогноз выключен. После сброса не выдумывать новую ёмкость — «waiting for fresh data». Иконка отличает unknown/stale от 0%/100%.
   Retry-After/cooldown действует на все триггеры (меню, wake, ручной), показывать время следующей попытки. Один запрос в полёте, коалесинг триггеров, отбрасывание поздних ответов после смены конфига, ограниченный backoff.
6. **Парсинг:** null resets_at ≠ 100% left: «not started» только при utilization 0 + null, иначе «reset unknown» без прогноза. Пропавшие/битые метрики = unavailable, не 0. Проверка конечности чисел; битая опциональная строка не роняет остальные. Несколько активных weekly_scoped со стабильной идентичностью; явный приоритет canonical vs `limits[]`. Extra: disabled / нет капа / кап 0 / нет валюты — разные состояния.
7. **Прогноз:** линейный UsagePace = средний темп с начала окна (так и подписывать). Пороги 2/6/12. Guard expected ≥ 3% — только для session (`UsagePaceText.swift:160`). ETA выключен для stale/unknown/после сброса/неправдоподобных окон.
8. **Тесты:** фикстура реального ответа (санитизированная) + null/unknown/битые поля, ISO8601-варианты, конфликт canonical/limits, несколько scoped, extra-кейсы; транспортные стабы (тела ошибок прокси vs апстрим, таймаут, битый 200, 429 Retry-After секунды/дата, редирект и непересылка секрета); fake clock для планировщика (коалесинг, cooldown, wake, поздний ответ); границы pace; история (roundtrip, run endpoints, сброс в том же часе, gap, retention, порча файла, разделение источников, рестарт); детерминированный растр иконки 1x/2x для 0/50/100/unknown/stale + ручной осмотр в светлой/тёмной теме, VoiceOver-текст. Интеграция бандла/Keychain/логина — отдельно от `swift test`.
9. При копировании существенных кусков CodexBar — сохранить MIT copyright notice.

## Открытые технические вопросы (закрыты решениями выше)

- Ошибки/состояния: прокси недоступен, 401 (неверный секрет), 403 (access window прокси истёк), 5xx/502 (нет токена на хосте прокси). Как показывать в меню и иконке.
- Тестирование: что покрывать юнит-тестами (парсинг на фикстурах реального ответа, pace, history compaction), как проверять иконку.
- Стоит ли брать в настройки значения по умолчанию из `ANTHROPIC_BASE_URL`/`ANTHROPIC_CUSTOM_HEADERS` (GUI-приложение их не видит из launchd-окружения — нужно проверить).

## Оценка размера истории за год (информационно, Task 5, 2026-10-17)

Не доказательство производительности, а порядок величины для худшего случая.

- Сценарий: опрос раз в минуту, значение меняется на каждом опросе, значит каждый опрос закрывает run и открывает новый: 525 600 run в год на поток. Потоков 4 (session, weekly, два scoped). Break-записи не учитывались (при здоровом соединении их почти нет).
- Метод: схема v1 из `HistoryStore.createSchema` (все таблицы и индексы), 2 102 400 закрытых run со случайными `used_percent`, вставленные системным `sqlite3` 3.51.0 во временный файл (страница 4096 байт), файл удалён после замера.
- Результат: ≈148 МБ (36 231 страница), ≈144 МБ после `VACUUM`, то есть ≈37 МБ на поток в год, ≈70 байт на run вместе с индексами.
- Реальный размер должен быть намного меньше: проценты приходят целыми или с одним знаком и между соседними опросами обычно не меняются, поэтому run продлевается, а не создаётся. Retention 365 дней ограничивает рост этим потолком.
