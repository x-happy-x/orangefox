# Popsicle: checkpoint диагностики цветов

2026-10-20. Пользователь сообщает: оранжевые элементы выглядят бирюзовыми
на физическом экране, но остаются оранжевыми на скриншотах.
Это согласуется с перестановкой R/B после рендеринга, однако причина пока
не доказана. Смена темы или формата вслепую не выполнялась.

Кандидат `20261020T080341Z` собран успешно: высота статусбара 108,
maintainer `x-happy-x`, префикс SHA256 IMG `c4c8d630`.
Цветовой код не менялся; аппаратная проверка этого кандидата ожидается.

## Что установлено по исходникам

Recovery закреплён на `0f7831d3240f4c3925a0b5fd7d2c907ddf8704c2`;
дерево YuKongA — `8023035649595341e26f9b924928c0b0cd67fbd2`.
Пути `device/...`, `external/...` и `bootable/...` ниже относительны к корню
полного Android checkout. Сокращённые `minuitwrp/...` находятся внутри
`bootable/recovery/`, а отдельные `graphics*.cpp` — в его `minuitwrp/`.
Номера строк относятся к проверенному checkout с применёнными изменениями порта.

- `device/xiaomi/popsicle/BoardConfig.mk:96`: `TARGET_RECOVERY_PIXEL_FORMAT := RGBX_8888`.
  Реальный `libminuitwrp` скомпилирован с `HAS_DRM` и `RECOVERY_RGBX`, без других
  `RECOVERY_*` форматов. Это видно в
  `out/soong/build.twrp_popsicle.7.ninja:550930`.
- `bootable/recovery/minuitwrp/graphics.cpp:645–674`: overlay пробуется только
  под `MSM_BSP`, затем DRM при `HAS_DRM`, затем fbdev при неудаче предыдущего
  backend. В этой сборке `TW_TARGET_USES_QCOM_BSP` пуст и `MSM_BSP` отсутствует:
  overlay исключён, но наличие `HAS_DRM` ещё не доказывает активный DRM.
- `minuitwrp/graphics_drm.cpp:692–695` выбирает `DRM_FORMAT_XBGR8888` и
  `GGL_PIXEL_FORMAT_RGBA_8888`. Это согласованная пара:
  `external/libdrm/include/drm/drm_fourcc.h:194` определяет XBGR как
  little-endian `x:B:G:R`, то есть байты памяти `R,G,B,x`.
- `graphics_drm.cpp:722–728` вызывает только `drmModeAddFB2`; при ошибке
  возвращает null. `external/libdrm/xf86drmMode.c:281–315` передаёт этот же
  `pixel_format` в `DRM_IOCTL_MODE_ADDFB2`. Legacy `AddFB(depth=24,bpp=32)`
  и скрытой подмены XBGR на XRGB нет.
- Два framebuffer создаются одинаково (`graphics_drm.cpp:1007–1008`);
  `draw_buf` получает тот же descriptor (`:1027`). `drm_flip` только копирует
  байты (`:1150–1154`); planes получают ID этого framebuffer (`:918–920`).
  Planes выбираются первыми по `number_of_lms` (`:1100–1104`), без проверки
  списка formats; код не меняет формат в зависимости от plane.
- `minuitwrp/graphics_utils.cpp:31–106` делает скриншот через повторный GGL-render
  `gr_mem_surface` в отдельный буфер и пишет PNG RGB. Это не чтение scanout.
  `RECOVERY_RGBX` не включает PNG-перестановку каналов; `gr_color`
  (`graphics.cpp:303–317`) также не меняет R/B для RGBX.
- В fbdev есть отдельные неподтверждённые на этом устройстве ошибки выбора:
  `graphics_fbdev.cpp:212–220` сопоставляет `red.offset=8` с GGL BGRA
  (у него red offset 16), а `red.offset=24` с GGL RGBX (red offset 0).
  При offsets 0 и 16 соответствие правильное; определения находятся в
  `bootable/recovery/libpixelflinger/format.cpp:26–30`.
  Это станет релевантно только при фактическом fbdev и соответствующих bitfields.

Первоначальная проверка RGBX/fourcc не выявила статической ошибки этой пары.
Последующая аппаратная диагностика подтвердила DRM, а аудит SPR обнаружил
отдельное расхождение с деревом устройства и TWRP, описанное ниже.

## Read-only проверка, когда телефон будет подключён

Выполнить этот shell через обычный ADB recovery. Команды не отправлялись
на телефон при подготовке checkpoint. Они читают только свойства дисплея,
отфильтрованный graphics log и display sysfs/debugfs; RPC не используется.

```sh
for p in ro.product.device ro.boot.hardware.sku ro.hardware vendor.display.enable_spr vendor.display.enable_spr_bypass ro.boot.display_ap_spr; do
    printf '%s=' "$p"; getprop "$p"
done
if [ -r /tmp/recovery.log ]; then
    grep -E 'Using (overlay|drm|fbdev) graphics\.|setting (DRM_FORMAT|GGL_PIXEL_FORMAT)|setting up .*bypass|fb0 reports|vi\.(bits_per_pixel|red\.offset|green\.offset|blue\.offset)|width: [0-9]+, height:|number of lms|cannot find/open a drm device|drmModeAddFB2 failed|DRM_IOCTL_MODE_CREATE_DUMB failed' /tmp/recovery.log
fi
for d in /sys/kernel/debug/dri/[0-9]*; do
    if [ -r "$d/state" ]; then
        printf '\nDRM %s\n' "$d/state"
        grep -E '^[[:space:]]*(plane\[|crtc\[|connector\[|crtc=|fb=|format=|modifier=|size=|pitch=|offset=|mode:|active=|enable=)' "$d/state"
    fi
done
for n in bits_per_pixel virtual_size stride mode modes; do
    f=/sys/class/graphics/fb0/$n
    if [ -r "$f" ]; then printf '\nFB0 %s\n' "$n"; cat "$f"; fi
done
```

Offsets/lengths R/G/B уже печатаются в recovery.log после `FBIOGET_VSCREENINFO`.
Стандартных sysfs-файлов fb0 с этими offsets нет; дополнительный ioctl helper
не вводился. Если debugfs недоступен, отметить это, не считать отсутствие
вывода доказательством fbdev.

## Модель семи цветов без устройства

Проверена на хосте без записи файлов: собрать little-endian 32-битное значение
из байтов `[R,G,B,255]`. Для XBGR извлечь R/G/B из битов 0/8/16;
для XRGB — из битов 16/8/0. Набор: orange `#FF8000`, red, green, blue,
white, black и gray `#606060`.

Все семь цветов сохраняются при RGBA-байтах + XBGR. Интерпретация тех же байтов
как XRGB меняет только R/B: orange становится `#0080FF`, red и blue меняются
местами, green/white/black/gray остаются прежними. Модель подтверждает различие
двух интерпретаций, но не измеряет фактический формат или цвета панели.

Модель не является основанием менять RGBX. После подтверждения активного DRM
выбран узкий перенос SPR-паритета ниже, без изменения 27 файлов устройства.

## Подтверждённый runtime и SPR-паритет

2026-10-20 телефон подключён. В логе установленной OrangeFox:

- `width: 1200, height: 2608`;
- оба буфера — `DRM_FORMAT_XBGR8888` + `GGL_PIXEL_FORMAT_RGBA_8888`;
- `number of lms in topology 2`, успешный atomic commit, `Using drm graphics.`;
- свойства `vendor.display.enable_spr=1`, `vendor.display.enable_spr_bypass=1`,
  `ro.boot.display_ap_spr=0`. DRM debugfs state и fb0 attributes не дали вывода.

Закреплённый `odm/bin/variant-script.sh:53–62` именно для popsicle устанавливает
обе SPR properties в 1. Исходный OrangeFox читает только `enable_spr` и создаёт
SPR blobs с `flags=0`; требуемый bypass игнорируется. Кроме того, исходные
V1/V2 structs не инициализированы целиком: незаписанные поля передаются ядру,
включая V2 `cfg18_en`/`cfg18`.

В исследованном TWRP-Test snapshot
`0315dbb53c47a0532546b7056f6af71b4dc0ddab`, файл
`twrpminui/graphics_drm.cpp`, уже есть:

- `SPR_FLAG_BYPASS (1 << 0)` (:88) и сохранённый `spr_bypass` (:260);
- zero-init обоих structs (:458, :498);
- `flags = spr_bypass ? SPR_FLAG_BYPASS : 0` (:463, :503);
- чтение `vendor.display.enable_spr_bypass` (:1238);
- диагностика `setting up <SPR property>, bypass <value>` (:1493).

`display-source-edits.json` переносит только эти восемь точных изменений в
OrangeFox. Исходный Git blob `minuitwrp/graphics_drm.cpp`:
`0cc80f5cb0c00368556174c35dac0dbfe54ec6f9`.
SHA256 файла после изменений:
`34b492c81cfa3ef199191c20b595c064f10212b195f2a76664c23df7110dcbd1`.
Перенос не меняет RGBX, GGL, fourcc, тему, kernel/crypto или исходные файлы
устройства. Другие изменения TWRP modeset/damage/RGBW не переносились.

Host-проверка:

```sh
python3 port/test-display-spr.py --source-dir /home/android/OrangeFox
```

Тест читает закреплённый Git blob, применяет фрагмент в памяти, извлекает реальные
SPR structs/maps/builders и две строки чтения свойств. Изолированный C++ harness
подменяет только property API и `drmModeCreatePropertyBlob`; DRM-устройство
не открывается. Временные исходники и бинарники удаляются после проверки.

PASS: V1/V2 с bypass 0/1, defaults при отсутствии properties, нулевые
неиспользуемые поля, прежние массивы конфигурации, повторяемый полный payload,
ошибки kernel blob и неизвестное имя SPR property. Два отрицательных контроля
действительно отклоняются: возврат `flags=0` и снятие zero-init. Компиляция с
`-ftrivial-auto-var-init=pattern` делает второй дефект воспроизводимым;
используются `gnu++20` и `-fno-exceptions`.

Физическое исправление цветов пока не подтверждено. После сборки необходимо
увидеть в логе именно `setting up ..., bypass 1` (значение, прочитанное при
инициализации, а не только поздний `getprop`), затем сравнить физические цвета
и PNG. До этой проверки перенос описывается как устранение подтверждённого
расхождения SPR, а не доказанное исправление бирюзового цвета.

## Контроль упаковки после первой пересборки SPR

Сборка `20261020T082045Z` скомпилировала новую `libminuitwrp.so`, но контроль
перед прошивкой обнаружил старую библиотеку в recovery ramdisk. **Этот образ
не прошивался.** Сравнение трёх уровней — собранный ELF в `system/lib64`,
staging в `recovery/root/system/lib64` и библиотека внутри IMG — не позволило
принять успешную компиляцию за доставку нового кода на устройство.

Причина: `bootable/recovery/prebuilt/Android.mk:443–461` оформляет
`relink_libraries` как `PHONY_PACKAGE`. Библиотеки указаны в
`LOCAL_REQUIRED_MODULES`, а копирование — в `LOCAL_POST_INSTALL_CMD`.
В полученном Ninja изменяемые `.so` являются только order-only dependencies
после `||`; они не инвалидируют timestamp копирования. Поэтому новый ELF
от 2026-10-20 сосуществовал со staging-библиотекой и stamp от 2026-10-19.
`prebuilt/relink.sh` при выполнении копирует файл без пропуска existing target;
проблема именно в том, что copy-rule повторно не запускался.

Builder устраняет stale staging через инвалидацию соответствующих сгенерированных
relink timestamps перед штатным `mka`, а не ручную подмену библиотеки в IMG.
В частности, библиотечный built stamp находится в
`out/target/product/popsicle/obj/FAKE/relink_libraries_intermediates/relink_libraries-timestamp`.
Итоговый образ должен пройти сравнение `libminuitwrp.so` с новым собранным ELF
и наличие строк `vendor.display.enable_spr_bypass` / `setting up %s, bypass %u`.
Повторная сборка и аппаратная проверка после исправления упаковки фиксируются
отдельно; не использовать `20261020T082045Z` как проверенный SPR-образ.
