# OrangeFox для Xiaomi 17 Pro Max (`popsicle`)

Неофициальный **OrangeFox R12.0 testing для Android 16**. Проверен на одном
Xiaomi 17 Pro Max с HyperOS `OS3.0.319.0.WPBCNXM`, патчем безопасности
`2026-08-01` и штатным ядром
`6.12.23-android16-5-g75e9b1c7ae7c-abogki463945075-4k`.
Другие устройства, версии прошивки и ядра не проверены.

## Скачать

[Релиз popsicle-2026-10-19](https://github.com/x-happy-x/orangefox/releases/tag/popsicle-2026-10-19):

- [Windows-установщик — OrangeFox-popsicle-2026-10-19-minimal.zip](https://github.com/x-happy-x/orangefox/releases/download/popsicle-2026-10-19/OrangeFox-popsicle-2026-10-19-minimal.zip).
- [recovery.img](https://github.com/x-happy-x/orangefox/releases/download/popsicle-2026-10-19/recovery.img).
- [OrangeFox-R12.0_testing-Unofficial-popsicle.zip](https://github.com/x-happy-x/orangefox/releases/download/popsicle-2026-10-19/OrangeFox-R12.0_testing-Unofficial-popsicle.zip).
- [popsicle-2026-10-19-sources.zip](https://github.com/x-happy-x/orangefox/releases/download/popsicle-2026-10-19/popsicle-2026-10-19-sources.zip).
- [SHA256SUMS](https://github.com/x-happy-x/orangefox/releases/download/popsicle-2026-10-19/SHA256SUMS).

SHA256 `recovery.img`:

```text
0741d416e2f772c9ab109adbacd328f701527442feb7461a16a1c9ad1449a390
```

## Установка в Windows

Нужны разблокированный загрузчик, USB-драйвер ADB/fastboot и Windows PowerShell
5.1. ADB/fastboot уже включены в пакет. Сохраните резервную копию важных данных.

1. Скачайте **minimal.zip**, проверьте его SHA256 по `SHA256SUMS` и полностью
   распакуйте через Проводник Windows в доступную для записи папку.
2. Подключите только один Xiaomi 17 Pro Max (`popsicle`). Начать можно из
   Android, recovery или **bootloader fastboot**. В Android заранее включите
   отладку по USB и авторизуйте компьютер; fastbootd для этого установщика не подходит.
3. Запустите **flash.cmd**, прочитайте результат в окне. После успешной записи
   телефон перезагрузится в OrangeFox.

В папке видны `flash.cmd` и `recovery.img`; служебные файлы скрыты. Сохраняйте
весь распакованный пакет. Скрипт проверяет SHA256, модель, разблокировку,
текущий слот и размер раздела; записывает только `recovery` текущего слота.
Он не меняет слот, не форматирует данные и не устанавливает root.
При доступном root ADB до перехода в fastboot сохраняется копия текущего recovery
в подпапку `backups`.

Для возврата включённого в пакет проверенного TWRP покажите скрытые файлы и
запустите **restore-twrp.cmd**. Возврат затрагивает recovery; отдельно
установленный KernelSU сохраняется.

Минимальная раскладка пакета проверяется offline с распаковкой; этот IMG и
механизм записи Windows-скрипта уже проверены на телефоне. Повторная аппаратная
проверка только из-за новой раскладки не выполнялась. Отдельный OrangeFox ZIP
проверен по CRC и совпадению вложенного образа; его прошивка из recovery на
телефоне не проверялась. Образ не содержит ядра, поэтому команда
`fastboot boot recovery.img` для него не подтверждена.

## Что работает и что изменено

- Загрузка recovery, сенсор, расшифровка основного хранилища существующим PIN
  и последующая загрузка Android подтверждены на указанной прошивке.
- Исправлен запуск Secure Element при поздней готовности ADSP; после новой
  загрузки recovery файлы открылись с первой попытки.
- Учтены скруглённые края экрана, уменьшены шрифты, работает кнопка фонарика.
- Исправлено нажатие на текст в просмотрщике. Редактор nano с экранной
  клавиатурой и стрелками проверен: `Ctrl+O`, `Enter` — сохранить, `Ctrl+X` — выйти.
- Есть отдельный выбор Magisk 30.7 / KernelSU 3.3.1 LKM и переход к установленным
  модулям. Root устанавливается только по отдельному выбору и подтверждению.

**KernelSU 3.3.1 LKM** установлен и проверен загрузкой Android и статусом
**Working** официального Manager на указанном ядре. В меню модулей проверено
включение и выключение отдельной пустой тестовой записи. **Magisk проверен
только патчем файлов образов; на телефон не устанавливался.** Автоматическое
переключение между root-провайдерами не поддерживается.

Сборка экспериментальная. Дополнительный профиль `999` не подтверждён:
в журнале была ошибка его расшифровки. OTA, MTP, sideload, OTG, fastbootd,
установка сторонних ZIP/модулей и все варианты холодного старта не проверены.
**Всё на ваш страх и риск.** О проблемах пишите в
[Issues](https://github.com/x-happy-x/orangefox/issues), указав версию прошивки,
ядро, действия и сообщение об ошибке. Удаляйте из логов личные данные и серийные номера.

Подробные результаты: [проверка устройства](docs/ANDROID-3-device-test.md),
[исходная проверка](docs/ANDROID-2-device-test.md),
[root](port/root-addons/README.md), [FBE helper](port/recovery-helpers/notes.md).

## Исходники и повторная сборка

Здесь находятся рецепты порта, manifest, overlay, точные изменения исходников
и инструменты сборки. Полный AOSP checkout скачивается отдельно в Linux ext4.
Ревизии закреплены в [sources.env](port/sources.env),
[local-manifest.xml](port/local-manifest.xml) и
[locked-projects.json](port/locked-projects.json).
Обоснование адаптации и проверки: [VALIDATION](port/VALIDATION.md).
Архив `popsicle-2026-10-19-sources.zip` релиза содержит рецепты публичного тега,
полный закреплённый build manifest (404 проекта) и применённые изменения;
upstream-исходники доступны
по ревизиям этого manifest и ссылкам в рецептах.

В PowerShell 7, из клона ветки `popsicle`:

```powershell
pwsh -File .\scripts\install-wsl.ps1 -WslRoot "$env:LOCALAPPDATA\WSL"
wsl -d android-dev
```

В подготовленном WSL:

```bash
android-dev doctor
android-dev sync
BUILD_JOBS=16 android-dev build
```

Сборка сохраняет IMG/ZIP, SHA256, полный manifest и отчёты проверок в
`~/artifacts/android-dev/`. Сценарии сборки не прошивают телефон.
[Локальная среда и экспорт WSL](docs/LOCAL-ENVIRONMENT.md),
[состав публикации](docs/PUBLICATION.md).

Спасибо [OrangeFox](https://gitlab.com/OrangeFox),
[Team Win / TWRP](https://github.com/TeamWin),
[YuKongA за дерево SM8850](https://github.com/YuKongA/twrp_device_xiaomi_sm8850)
и [TWRP-Test за Android 16 recovery-компоненты](https://github.com/TWRP-Test).
Root-компоненты: [Magisk](https://github.com/topjohnwu/Magisk) и
[KernelSU](https://github.com/tiann/KernelSU);
точные upstream-релизы, исходные ревизии и SHA256 перечислены в
[releases.json](port/root-addons/releases.json).
Авторство, исходные лицензии и копии уведомлений собраны в
[THIRD-PARTY](docs/THIRD-PARTY.md) и входят в архив исходников релиза.

## English

Unofficial OrangeFox R12.0 testing for **Xiaomi 17 Pro Max (`popsicle`), Android 16**.
Tested only on HyperOS `OS3.0.319.0.WPBCNXM` with the stock kernel listed above.
Download the **minimal Windows installer** from the release, verify SHA256,
extract the entire archive using Windows Explorer and run `flash.cmd`.
An unlocked bootloader and ADB/fastboot drivers are required. Start from
authorized Android, recovery or bootloader fastboot. Keep hidden support files;
`restore-twrp.cmd` restores the bundled known-working TWRP to the current recovery slot.

Boot, touch, main-user decryption, text editing, flashlight and Android boot
were confirmed. KernelSU 3.3.1 LKM booted and Manager reported **Working**;
Magisk received file-only tests. Other firmware/kernels, profile 999 and unlisted
features remain unvalidated. **Use at your own risk; report problems in
[Issues](https://github.com/x-happy-x/orangefox/issues).** This repository contains
pinned port/build recipes, not a full AOSP checkout. See the linked device reports
for exact test scope.
