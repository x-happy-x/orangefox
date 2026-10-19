**OrangeFox R12.0 testing для Xiaomi 17 Pro Max (`popsicle`), Android 16.**
Проверен на HyperOS `OS3.0.319.0.WPBCNXM`, штатное ядро 6.12.23.

1. Скачайте [minimal ZIP](https://github.com/x-happy-x/orangefox/releases/download/popsicle-2026-10-19/OrangeFox-popsicle-2026-10-19-minimal.zip), сверьте `SHA256SUMS`, полностью распакуйте через Проводник Windows.
2. Нужны разблокированный загрузчик, Windows PowerShell 5.1 и USB-драйвер ADB/fastboot. Инструменты включены.
3. Подключите один `popsicle` в **bootloader fastboot**; можно начать из recovery или Android с авторизованной USB-отладкой. Fastbootd не подходит.
4. Запустите **flash.cmd**. Записывается только recovery текущего слота, затем загружается OrangeFox. Root автоматически не устанавливается.

Видны `flash.cmd` и `recovery.img`; скрытые служебные файлы не удаляйте.
Возврат проверенного TWRP: покажите скрытые файлы и запустите **restore-twrp.cmd**. KernelSU при этом сохраняется.

Подтверждены сенсор, основное хранилище с PIN, фонарик, nano и возврат в Android.
KernelSU 3.3.1 LKM — **Working**; Magisk проверен только на файлах.
Другие прошивки/ядра, профиль `999` и сторонние модули не проверены.
IMG и механизм записи проверены на телефоне; минимальная раскладка — offline.

**Всё на ваш страх и риск. Сохраните резервную копию важных данных.**
О проблемах пишите в [Issues](https://github.com/x-happy-x/orangefox/issues): прошивка, ядро, шаги, ошибка; без личных данных в логах.
[Полная инструкция, исходники и проверки](https://github.com/x-happy-x/orangefox/tree/popsicle).
