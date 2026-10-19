# android-dev

Отдельный WSL2-дистрибутив для сборки Android recovery и экспериментального
порта OrangeFox для **Xiaomi 17 Pro Max (`popsicle`), Android 16**.

- Имя WSL: `android-dev`.
- Диск дистрибутива: `R:\vm\wsl\android-dev\ext4.vhdx`.
- ОС: Ubuntu 24.04 LTS, пользователь `android`.
- Исходники сборки внутри Linux: `/home/android/OrangeFox`.
- Сценарии и порт внутри Linux: `/home/android/android-dev`.
- Репозиторий сценариев в Windows: `P:\services\android-dev`.
- Задача: `ANDROID-1`.

Сборка выполняется на ext4 внутри WSL. Общие настройки WSL Windows и другие
дистрибутивы сценарий установки не меняет.

## Готовая сборка от 19 октября 2026

OrangeFox `R12.0_testing-Unofficial-popsicle` собран из закреплённых исходников
Android 16. Успешный запуск `mka recoveryimage` занял 7 минут 23 секунды на
16 потоках. Образ имеет размер 100 MiB, заголовок v4 и LZ4 ramdisk без ядра,
как опубликованный автором TWRP для этого дерева.

Проверены структура ramdisk, AVB hash descriptor, SHA256 образов, CRC ZIP и
совпадение вложенного `recovery.img`. Все 27 выбранных файлов fstab/init,
вариантов оборудования и ueventd побайтно совпали с авторским TWRP.
Загрузка и расшифровка на телефоне пользователя **не проверялись**.

Артефакты и отчёты:

- Windows: `R:\vm\wsl\android-dev-artifacts\20261019T152705Z\`.
- WSL: `/home/android/artifacts/android-dev/20261019T152705Z/`.
- Файлы: `recovery.img`, `OrangeFox-R12.0_testing-Unofficial-popsicle.img`,
  `OrangeFox-R12.0_testing-Unofficial-popsicle.zip` и `SHA256SUMS`.
- Подробности: `image-structure.json`, `device-files-compare.json`, `avb-*.txt`,
  полный `manifest.xml`, патчи, версии пакетов и журнал сборки.

## Установка с нуля

В PowerShell 7:

```powershell
& P:\services\android-dev\scripts\install-wsl.ps1
wsl -d android-dev
```

Установщик скачивает официальный Ubuntu WSL rootfs, проверяет закреплённый
SHA256, импортирует WSL2 в заданный каталог, ставит пакеты для сборки и копирует
сценарии в Linux. При совпадении имени существующего WSL или каталога установка
останавливается; существующие данные не заменяются.

В дистрибутиве доступны Git/Git LFS, Repo, GCC/G++, Java 17, Python 3, ccache,
ADB/fastboot, инструменты сжатия и проверки shell-скриптов. Пароль пользователю
не задаётся, административные команды доступны через `sudo`.

## Работа

Внутри WSL:

```bash
android-dev doctor
android-dev sync
BUILD_JOBS=16 android-dev build
```

Первое получение исходников и первая сборка требуют много места и времени.
Исходники следует оставлять на Linux ext4. Для ccache выделено до 30 GiB.
Параметры порта и точные ревизии описаны в каталоге `port/`.

После сетевого сбоя повторите `android-dev sync`: уже полученные Git-объекты
переиспользуются. Параллелизм загрузки задаётся через `SYNC_JOBS`, сборки — через
`BUILD_JOBS`; без этих переменных используются четыре процесса.

Результаты сборки с контрольными суммами, полным manifest и отчётами проверки
сохраняются в `/home/android/artifacts/android-dev/<UTC-дата>/`, журналы —
в `/home/android/logs/android-dev/`. Перед сборкой сценарий проверяет ревизии
исходников и точный состав изменений порта.

## Экспорт и восстановление

После завершения сборки в PowerShell:

```powershell
& P:\services\android-dev\scripts\export-wsl.ps1
```

Будут созданы `R:\vm\wsl\android-dev.tar` и файл SHA256. Экспорт останавливает
только `android-dev`. Архив содержит установленную среду и все файлы её Linux
диска на момент экспорта, включая полученные исходники и результаты сборки.

Восстановление под новым именем:

```powershell
wsl --import android-dev-restored R:\vm\wsl\android-dev-restored R:\vm\wsl\android-dev.tar --version 2
wsl -d android-dev-restored
```

## Проверка на устройстве

Сценарии не прошивают телефон. Успех компиляции подтверждает создание образа,
но загрузку, сенсор, расшифровку `/data` с действующим PIN, MTP/ADB и последующую
загрузку Android необходимо проверять на реальном `popsicle`. До такой проверки
порт считается экспериментальным. Результаты фактических проверок будут
сохранены отдельно; непроверенные возможности не следует считать рабочими.
