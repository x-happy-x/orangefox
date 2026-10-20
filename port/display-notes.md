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

Прямой статической причины инверсии цветов для текущей RGBX/DRM пары не найдено.
Пока нельзя выбирать между fbdev bitfields и особенностью физического
DRM/драйверного/panel pipeline.

## Read-only проверка, когда телефон будет подключён

Выполнить этот shell через обычный ADB recovery. Команды не отправлялись
на телефон при подготовке checkpoint. Они читают только свойства дисплея,
отфильтрованный graphics log и display sysfs/debugfs; RPC не используется.

```sh
for p in ro.product.device ro.boot.hardware.sku ro.hardware vendor.display.enable_spr; do
    printf '%s=' "$p"; getprop "$p"
done
if [ -r /tmp/recovery.log ]; then
    grep -E 'Using (overlay|drm|fbdev) graphics\.|setting (DRM_FORMAT|GGL_PIXEL_FORMAT)|fb0 reports|vi\.(bits_per_pixel|red\.offset|green\.offset|blue\.offset)|width: [0-9]+, height:|number of lms|cannot find/open a drm device|drmModeAddFB2 failed|DRM_IOCTL_MODE_CREATE_DUMB failed' /tmp/recovery.log
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

Следующий шаг — установить активный backend и фактические framebuffer bitfields/
fourcc по данным выше и сопоставить физические цвета со скриншотом. До этого
изменения цветового pipeline и 27 исходных файлов устройства не требуются.
