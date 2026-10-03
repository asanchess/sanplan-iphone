# SanPlan: сборка и установка с Windows

Личный Mac не нужен для управления сборкой. Сам iPhone-бинарник требует Xcode и iOS SDK: они работают на macOS, поэтому Windows запускает облачную сборку GitHub Actions. Swift для Windows не содержит SwiftUI, UIKit или AlarmKit для iPhone.

## Текущее состояние

Подготовлены проект, тесты и workflow `.github/workflows/iphone-build.yml`. Реальная компиляция и установка на iPhone ещё не подтверждены. Структурная проверка Windows не заменяет Xcode.

Workflow запускается вручную, использует стандартный `macos-26`, имеет предел 20 минут, собирает устройство без подписи, затем запускает XCTest на доступном iOS 26 симуляторе. Артефакт `SanPlan-iPhone` содержит `SanPlan-unsigned.ipa`, SHA256 и журналы. Артефакт хранится 1 день. Неуспешный тест означает незавершённую проверку, даже если IPA уже создан.

## Бесплатная облачная сборка

1. Из корня SanPlan выполнить `powershell -File scripts/prepare-iphone-cloud.ps1`. Получится отдельная папка только с нативным проектом. Веб-сайт, конфигурация облака, ключи и личные планы туда не копируются.
2. После разрешения владельца опубликовать эту папку в отдельном GitHub-репозитории. Публичная публикация исходников требует отдельного решения владельца. Стандартные runners публичных репозиториев бесплатны. Для частного репозитория сначала проверить остаток бесплатного лимита и бюджет с остановкой расходов: платные вызовы не разрешены.
3. В GitHub открыть **Actions → Build SanPlan iPhone → Run workflow**. Из Windows можно выполнить `gh workflow run iphone-build.yml --repo OWNER/REPO`.
4. Следить: `gh run list --repo OWNER/REPO`. Скачать успешный запуск: `gh run download RUN_ID --repo OWNER/REPO --name SanPlan-iPhone --dir outputs/iphone-build-RUN_ID`.
5. Проверить `RESULT.txt`, оба журнала и SHA256. Файл IPA ещё не подписан и не установится обычным открытием в Safari.

## Установка на iPhone через Windows

1. Установить AltServer по официальной инструкции ниже. Ему требуются iTunes и iCloud из источника Apple; не заменять существующие установки без проверки совместимости.
2. Подключить разблокированный iPhone по USB, подтвердить доверие компьютеру, включить Wi-Fi sync в iTunes.
3. В значке AltServer выбрать **Install AltStore → свой iPhone**. Apple ID и пароль вводить лично в AltServer; не передавать их Codex и не добавлять в GitHub.
4. В iPhone доверить профилю в **Настройки → Основные → VPN и управление устройством**. Включить **Конфиденциальность и безопасность → Режим разработчика**, подтвердить перезагрузку.
5. Передать IPA на iPhone, открыть AltStore, **My Apps → +**, выбрать IPA. AltStore подписывает приложение вашим бесплатным аккаунтом. Успешность установки именно SanPlan пока не проверена.
6. Бесплатная подпись требует обновления каждые 7 дней; держать AltServer доступным для обновления. Постоянная установка без обслуживания бесплатно не обещается.
7. В SanPlan войти, разрешить будильники, выбрать **Проверка через минуту**, заблокировать экран. Только после этого подтверждать звук на реальном iPhone. Не скрывать приложение и не включать требование Face ID для него.

Это системный будильник AlarmKit, а не телефонный звонок или FaceTime. Изменения планов синхронизируются при открытии приложения и кнопкой обновления.

Источники: [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions), [macOS 26 runners](https://github.com/actions/runner-images), [AltStore Windows](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows), [Apple account limitations](https://developer.apple.com/help/account/basics/about-your-developer-account).
