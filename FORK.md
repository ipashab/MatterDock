# MatterDock — форк MatterMac

Собственный macOS-клиент Mattermost, отделённый от upstream.

## Происхождение

Форк создан 21.10.2026 из репозитория `dfrnoch/MatterMac` (состояние main,
125 коммитов, последний от 06.10.2026). Лицензия MIT сохранена полностью,
авторские права — в LICENSE. Исходный репозиторий как remote отвязан:
обновления upstream не подтягиваются, развитие идёт самостоятельно.

Перед форком весь исходный код (324 Swift-файла) прошёл аудит на утечки:
телеметрия отсутствует, креды не покидают scope настроенного сервера,
единственный внешний адрес — GitHub API для проверок обновлений (в форке
выключено, см. ниже).

## Что изменено относительно upstream

Идентичность продукта (файлы: xcconfig, Info.plist, UpdateSupport.swift):

| Было | Стало |
|---|---|
| `dev.frnoch.mattermac` (bundle id) | `com.matterdock.app` |
| `dev.frnoch.mattermac.UpdateInstaller` | `com.matterdock.app.UpdateInstaller` |
| `org.mattermac.MatterMac.*` (Keychain-сервисы, кэш-директории) | `com.matterdock.app.*` |
| Team ID `ZJ37A69485` (подпись автора) | пусто — подпись чужого разработчика |
| `MatterMac` (имя приложения, окно, Dock) | `MatterDock` |

Независимость от чужой поставки обновлений:

- `LocalSettings.checksForUpdates` — дефолт `false`: приложение не обращается
  к GitHub за релизами;
- фид обновлений указывает на `ipashab/MatterDock` (заглушка);
- `UpdateSupport.teamIdentifier` пуст — криптографическое требование подписи
  не выполнимо, самовостановление из чужого фида невозможно в принципе;
- каталог `.github/` (CI/CD автора) удалён.

Обновления продукта — пересборка из исходников этой ветки.

Внутренние имена модулей (`MatterMacKit`, `MatterMacUI`, ...) и ключи
локализации сохранены: переименование — отдельная задача, правок ради
косметики риск не оправдан.

## Доработки 21.10.2026 (после создания форка)

- UI самообновлений удалён: секция Settings ▸ General ▸ Updates
  (`UpdateSettingsSection`), баннер готовности в главном окне (`UpdateBanner`),
  пункт меню «Check for Updates…». Файл `UpdateViews.swift` удалён как
  ставший неиспользуемым; движок `AppUpdater` и протокол фида оставлены —
  они пригодятся для внутреннего фида обновлений (debug-аргумент
  `-MatterMacUpdateFeed`);
- `About MatterMac` переименован в `About MatterDock`;
- иконка приложения заменена: тёмный сине-графитовый градиент + белый диалог
  с тремя точками (`bubble.svg` + новый `icon.json`); ночная иконка
  `AppIconNightly` удалена;
- версионирование — CalVer `0.МЕСЯЦ.РЕЛИЗ`, `MARKETING_VERSION = 0.1.0`,
  nightly-концепция убрана из конфигурации;
- README переписан под MatterDock;
- тест дефолтов `LocalSettingsPersistenceTests` синхронизирован с выключенными
  самообновлениями (`checksForUpdates == false`).

## Сборка (стабильная подпись, сессии переживают пересборки)

Ad-hoc подпись уникальна для каждой сборки, из-за чего macOS Keychain считает
каждую пересборку «другим приложением» и не даёт доступ к сохранённым аккаунтам
— приходилось логиниться заново. Решение: локальный самоподписанный
сертификат подписи кода `MatterDock Dev` (создан один раз, доверен для codeSign).

Сборка с сохранением сессий:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMac \
  -configuration Debug -derivedDataPath build build \
  CODE_SIGN_IDENTITY="MatterDock Dev" DEVELOPMENT_TEAM= OTHER_CODE_SIGN_FLAGS=
```

Все сборки с этой идентичностью имеют одинаковый designated requirement —
Keychain пускает их к сохранённым токенам, логин сохраняется между пересборками.
Первая сборка после перехода с ad-hoc потребует последний вход заново (старая
запись была привязана к ad-hoc подписи и недоступна новой).

Если `security find-identity -v -p codesigning` на новой машине пуст —
создать сертификат заново:

```sh
openssl req -newkey rsa:2048 -nodes -keyout dev.key -x509 -days 7300 \
  -out dev.pem -subj "/CN=MatterDock Dev/O=MatterDock" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
security import dev.key -k ~/Library/Keychains/login.keychain-db
security import dev.pem -k ~/Library/Keychains/login.keychain-db
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db dev.pem
```

## Сайдбар (21.10.2026)

Каналы с новыми сообщениями (незамьюченные или с упоминаниями) по умолчанию
поднимаются в группу Unreads вверху сайдбара — как в официальном клиенте
(решение `docs/decisions/0038`). Тумблер в меню View остаётся.

## Совместимость с корпоративным сервером (Time Messenger)

Корпоративный деплой — Time Messenger v6.352.7 (ядро Mattermost 7.8) — отдаёт
бинарные тела в zstd: соседний nginx кеширует варианты ответа по URL, игнорируя
`Vary: Accept-Encoding`, и закешированный zstd-вариант выдаётся при любых
заголовках, а URLSession не декодирует zstd и не может отправить запрос
без `Accept-Encoding`. Обход: при обнаруженном `Content-Encoding: zstd` запрос
повторяется сырым HTTP/1.1 через `NWConnection` — без `Accept-Encoding`, с
уникальным параметром `zcb` (гарантированный промах кеша вариантов) и
раскодировкой chunked-кадров, которыми этот сервер отвечает всегда
(решение `docs/decisions/0039`).

## Русский язык

Выбор языка в Settings ▸ General (System / English / Русский). Перевод живёт
в каталоге приложения (`Localizable.xcstrings`), извлечение ключей —
`scripts/extract_localizable_keys.py`, верификация —
`scripts/verify_localizable_keys.py` (решение
`docs/decisions/0040`). Смена применяется после перезапуска.

## Рендеринг markdown (21.10.2026)

Исправлен дефект upstream: у оформленных блоков (`NSTextBlock` — код-блоки, цитаты,
горизонтальные разделители, вложения) ширина контента по умолчанию равна нулю, поэтому
TextKit выдавал блоку нулевой прямоугольник рисования и `drawBackground` не рисовал
ничего — код отображался моноширинным текстом без рамки, цитаты без полосы. Правка в
`TimelineTextBlock`: `rectForLayout` растягивает контент на всю предложенную ширину
с вычетом собственных правых отступов (вложенность сохраняется). Регресс —
`decoratedBlocksSpanTheFullContainerWidth`.

## Обновления продукта

Пересборка из исходников этой ветки: pull отсутствует (remote удалён),
обновления из чужого GitHub-фида криптографически невозможны (пустой
`teamIdentifier` делает требование подписи невыполнимым).

## Треды (21.10.2026)

Свёрнутые треды включены всегда (решение `docs/decisions/0037`): в основном
таймлайне канала — только корневые сообщения со счётчиком «N replies», ответы —
исключительно в панели обсуждения справа, как в официальном клиенте. Конфиг
сервера, preference и тумблер в Settings больше не влияют (тумблер удалён).
Заголовок панели — `Thread · <имя канала>`.

## Сборка

Требуется Xcode 27 (Swift 6.4), macOS 14+.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -workspace MatterMac.xcworkspace -scheme MatterMac \
  -configuration Debug -derivedDataPath build build \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= OTHER_CODE_SIGN_FLAGS=
open build/Build/Products/Debug/MatterDock.app
```

Ad-hoc подпись — штатный режим CI upstream для сборок без сертификата.
Для внутреннего распространения заменить на корпоративный Developer ID.

## Тесты

```sh
swift test --package-path Packages/MatterMacKit
```
