# Заявка

Система внутренних обращений организации: IT, ремонт оборудования и хозяйственные вопросы. Сотрудники подают заявки, исполнители обрабатывают их, администратор назначает ответственных и отслеживает результаты.

## Возможности

- Мобильное приложение на Flutter для Android и iOS.
- Реестр с поиском, фильтрами по статусу, категории и исполнителю, экспортом CSV.
- Карточка заявки со сроком, результатом выполнения и историей изменений.
- Дашборд: статусы, категории, просрочки и среднее время выполнения за выбранный период создания заявок.
- Подсказка категории по тексту с помощью TF-IDF и логистической регрессии.
- Вход через Keycloak; распределённые трейсы и централизованные логи в ELK.

## Роли и работа с заявкой

| Роль | Возможности |
| --- | --- |
| Сотрудник | Создаёт заявки и просматривает свои обращения. |
| Исполнитель | Также видит назначенные ему заявки, принимает их в работу и завершает с описанием результата. |
| Администратор | Видит все заявки, подтверждает категории, назначает исполнителей и сроки, открывает аналитику и запускает обучение модели. |

Заявка проходит статусы «Новая» → «В работе» → «Выполнена». Для начала работы нужен назначенный исполнитель, для завершения — результат. Изменения сохраняются с автором и временем. Учётными записями и ролями администратор управляет через Keycloak.

Просроченной считается невыполненная заявка с истёкшим сроком. Среднее время рассчитывается от создания до завершения для выполненных заявок выбранного периода. Аналитика получает события через Kafka, поэтому может отставать от реестра; на дашборде показано время её обновления.

Категория всегда доступна для ручного выбора. Для обучения нужны завершённые заявки с подтверждённой администратором категорией: минимум две категории и три примера каждой. Macro-F1 рассчитывается на отдельной проверочной выборке; затем модель обучается на всех примерах. Данные обрабатываются внутри серверной инфраструктуры.

## Стек

| Часть | Технологии |
| --- | --- |
| Клиент | Dart, Flutter, AppAuth, защищённое хранилище токенов на устройстве. |
| Сервисы `tickets`, `analytics`, `classification` | Python, FastAPI, SQLAlchemy, PostgreSQL, scikit-learn. |
| Вход и права | Keycloak, OpenID Connect, Authorization Code + PKCE, JWT. |
| Асинхронный обмен | Kafka KRaft, transactional outbox, группы потребителей. |
| Шлюз | Nginx с маршрутизацией и балансировкой экземпляров. |
| Телеметрия | OpenTelemetry SDK, OTel Collector Contrib, Elasticsearch, Logstash, Kibana. |

Схема взаимодействия, владение данными и доставка событий описаны в [архитектуре](docs/architecture.md).

## Запуск

Нужны Docker с Compose и Flutter 3.47+ с Dart 3.13+. Команды выполняются из корня репозитория. Локальный профиль использует HTTP и пароли из `.env`; для внешнего размещения настройте HTTPS на входном прокси, публичный адрес Keycloak и собственные секреты. `DB_PASSWORD` в этом профиле должен состоять из букв, цифр и дефисов.

Скопируйте настройки и создайте общую сеть один раз:

```sh
cp .env.example .env
docker network create zayavka
```

Каждый компонент имеет отдельный Compose-проект. Запустите необходимые инфраструктурные компоненты:

```sh
docker compose --env-file .env -f src/infrastructure/keycloak/compose.yaml up -d
docker compose --env-file .env -f src/infrastructure/kafka/compose.yaml up -d
docker compose --env-file .env -f src/infrastructure/elasticsearch/compose.yaml up -d
docker compose --env-file .env -f src/infrastructure/logstash/compose.yaml up -d
docker compose --env-file .env -f src/infrastructure/kibana/compose.yaml up -d
docker compose --env-file .env -f src/infrastructure/otel/compose.yaml up -d
docker compose --env-file .env -f src/infrastructure/nginx/compose.yaml up -d
```

Соберите и разверните прикладные сервисы независимо:

```sh
docker compose --env-file .env -f src/tickets/compose.yaml up --build -d
docker compose --env-file .env -f src/analytics/compose.yaml up --build -d
docker compose --env-file .env -f src/classification/compose.yaml up --build -d
```

В базе Keycloak при первом запуске создаются пользователи `admin`, `employee`, `executor`. Их пароли задаются переменными `APP_ADMIN_PASSWORD`, `APP_EMPLOYEE_PASSWORD`, `APP_EXECUTOR_PASSWORD`. Управление пользователями: `http://localhost:8080/admin/`, учётная запись `keycloak-admin`, пароль `KEYCLOAK_ADMIN_PASSWORD`. Импорт realm выполняется только для новой базы; последующее изменение `.env` не меняет существующие учётные записи.

Установите зависимости клиента:

```sh
flutter pub get
```

Для Android-эмулятора перенаправьте порт сервера и выберите устройство:

```sh
adb reverse tcp:8080 tcp:8080
flutter run -d <device-id> -t src/client/main.dart
```

Для сборки Android debug APK: `flutter build apk --debug -t src/client/main.dart`. Файл появится в `build/app/outputs/flutter-apk/app-debug.apk`.

iOS собирается на macOS с Xcode: `flutter run -d <device-id> -t src/client/main.dart`. Платформы используют единый OIDC redirect URI `com.example.zayavka:/oauthredirect`.

Для физического устройства задайте доступный ему адрес в `PUBLIC_URL` и пересоздайте контейнеры Keycloak и API. Передайте клиенту тот же адрес:

```sh
flutter run -d <device-id> -t src/client/main.dart --dart-define=API_URL=http://<server-ip>:8080 --dart-define=AUTH_ISSUER=http://<server-ip>:8080/realms/zayavka
```

API доступно на `http://localhost:8080`: `/api/docs`, `/analytics/docs`, `/classification/docs`. Kibana — `http://localhost:5601`: создайте представления данных `application-logs-*` и `traces-*.otel-*` с полем времени `@timestamp`. Идентификатор трассы хранится в `trace.id` у логов и `trace_id` у трейсов. API проверяет роль и доступ к конкретной заявке на сервере.

Экземпляры сервисов масштабируются отдельно:

```sh
docker compose --env-file .env -f src/tickets/compose.yaml up -d --scale tickets=2
docker compose --env-file .env -f src/analytics/compose.yaml up -d --scale analytics=3
docker compose --env-file .env -f src/classification/compose.yaml up -d --scale classification=2
```

Три партиции `ticket.events` допускают до трёх активных потребителей группы `analytics`. Один брокер не обеспечивает отказоустойчивость. Для нескольких хостов требуются доступные сетевые адреса зависимостей и общее хранилище моделей либо доставка модели каждому экземпляру классификатора.
