# OrangeFox для Xiaomi 17 Pro Max

Неофициальная сборка для **popsicle, Android 16**.
Проверена на HyperOS `OS3.0.319.0.WPBCNXM`.

**[Скачать релиз](https://github.com/x-happy-x/orangefox/releases/tag/popsicle-2026-10-19)**

1. Нужен разблокированный загрузчик и USB-драйвер ADB/fastboot.
2. Скачайте minimal ZIP и полностью распакуйте через Проводник Windows.
3. Подключите телефон в **Fastboot** и запустите **flash.cmd**.
   После прошивки телефон сам загрузится в OrangeFox.

В папке видны только `flash.cmd` и `recovery.img`. Скрытые служебные файлы
тоже нужны — не удаляйте их. Для возврата TWRP покажите скрытые файлы и
запустите `restore-twrp.cmd`. Root устанавливается отдельно в меню recovery.

**Всё на ваш страх и риск. Перед прошивкой сделайте бэкап.**
О проблемах пишите в [Issues](https://github.com/x-happy-x/orangefox/issues):
укажите прошивку, что делали и какую ошибку получили.

[Проверки и ограничения](docs/PUBLICATION.md) ·
[Сборка и WSL](docs/LOCAL-ENVIRONMENT.md) ·
[Авторы и лицензии](docs/THIRD-PARTY.md)

Основа — OrangeFox/TWRP, дерево устройства — YuKongA.
