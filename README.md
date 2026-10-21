# MatterDock

Нативный macOS-клиент Mattermost (Swift/SwiftUI + AppKit, без Electron и
WebView). Форк [MatterMac](https://github.com/dfrnoch/MatterMac) (MIT),
отвязанный от upstream: развитие, сборка и распространение — самостоятельные.
Подробности форка, изменённое и причины — в [FORK.md](FORK.md).

## Сборка

Нужен Xcode 27 (Swift 6.4), macOS 14+.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMac \
  -configuration Debug -derivedDataPath build build \
  CODE_SIGN_IDENTITY="MatterDock Dev" DEVELOPMENT_TEAM= OTHER_CODE_SIGN_FLAGS=
open build/Build/Products/Debug/MatterDock.app
```

Подпись — стабильный локальный сертификат `MatterDock Dev` (создание — в FORK.md):
сессии и Keychain переживают пересборки. Ad-hoc (`CODE_SIGN_IDENTITY=-`)
приводит к повторному логину после каждой пересборки. Для внешнего
распространения заменить на корпоративный Developer ID.

## Тесты

```sh
swift test --package-path Packages/MatterMacKit
```

Локальные тест-серверы Mattermost (Docker) — в `Tests/Integration/Server/`,
живые тесты опциональны (`MM_LIVE_TESTS=1`), см. `CONTRIBUTING.md`.

## Отличия от upstream

- Идентичность: `com.matterdock.app`, имя MatterDock, своя иконка, изолированные
  Keychain-сервисы (`com.matterdock.app.*`);
- самообновления из GitHub выключены и убраны из UI: фид, браннер, секция
  Settings ▸ General ▸ Updates и пункт меню «Check for Updates…»; движок
  `AppUpdater` оставлен для будущего внутреннего фида (debug-аргумент
  `-MatterMacUpdateFeed`);
- CI upstream (`.github/`) удалён; версии — CalVer `0.МЕСЯЦ.РЕЛИЗ` без nightly.

## План развития

- корпоративный Developer ID + внутренний дистрибутив (возможна подпись
  `notarization` через корпоративный Apple-аккаунт);
- внутренний фид обновлений через оставленный `AppUpdater`;
- бренд: дизайнерская иконка вместо временной, светлая/тёмная иконки;
- свои фичи по мере надобности — список ведётся в задачах команды.

## Документация upstream

`SPEC.md` — спецификация реализации (архитектурные правила всё ещё в силе);
`docs/` — архитектурные заметки, решения (`docs/decisions/`), протокольные
исследования; `AGENTS.md` — правила работы в репозитории.
