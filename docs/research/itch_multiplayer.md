# Сетевая игра «через itch.io»: что даёт itch и какие есть альтернативы

Дата: 01.10.2026. Контекст: семья и друзья (2–10 человек), голос внешний, свой сервер на Go уже есть (`server/`, `docs/net_protocol.md`, `docs/plan/multiplayer.md`).

## Короткий ответ

**Нет, сетевой игры «через itch.io» не бывает: itch не даёт ни подбора игроков, ни лобби, ни relay, ни хостинга серверов, ни друзей.** Даёт только одно полезное: при запуске из itch app игра получает временный API-ключ, по которому можно узнать, какой itch-аккаунт играет (и, например, купил ли игру). Это идентификация, а не сеть.

## 1. Что даёт itch.io

| Возможность | Есть? | Источник |
|---|---|---|
| Хостинг игровых серверов | Нет. Пользователи форума прямо пишут «itch не может сам хостить сервер для онлайн-игры»; ответа от сотрудников itch в теме нет | [форум: Hosting Online Games on Itch](https://itch.io/t/2737974/hosting-online-games-on-itch) |
| Matchmaking, лобби, relay/TURN | В документации itch не найдено. Раздел для разработчиков itch app описывает только дистрибуцию (сборки, обновления, манифест) | [itch app: Integrating](https://itch.io/docs/itch/integrating/); [API overview](https://itch.io/docs/api/overview) |
| Друзья / социальный граф | В документации API не найдено (есть профиль, купленные ключи, скачивания) | [Server-side API](https://itch.io/docs/api/serverside) |
| Идентификация игрока | Да, но только при запуске из itch app: манифест с `scope: profile:me` -> переменные окружения `ITCHIO_API_KEY` (ключ на игру и сессию, временный) и `ITCHIO_API_KEY_EXPIRES_AT`; единственный доступный scope — `profile:me`, т.е. доступ к `https://api.itch.io/profile` | [Manifest actions: API key](https://itch.io/docs/itch/integrating/manifest-actions.html) |
| Что с этим можно сделать | «Знать наверняка, какой аккаунт играет», получить имя/аватар, доказательство покупки; в доке прямо приведён пример — пускать на онлайн-серверы только купивших | [Integrating: API](https://itch.io/docs/itch/integrating/api/) |
| Проверка владения игрой с сервера | `GET /games/{id}/ownership` — только с токеном OAuth-приложения; `download_keys`, `purchases` — с ключом разработчика | [Server-side API](https://itch.io/docs/api/serverside) |

Нюансы для нас:
- Ключ есть только при запуске из itch app (не при скачивании zip/через браузер и не при запуске бинарника руками). Для сборок Linux/Windows через butler нужен манифест `.itch.toml` с action и scope. Это не проверялось на нашей сборке.
- Ключ даёт игре только `GET /profile` своего пользователя. Другого игрока по нему не найти, друзей и комнат нет. Серверу для проверки личности ключ пришлось бы отправлять самим на `api.itch.io/profile` (так сервер узнаёт имя без паролей). Нашей аудитории (несколько человек, код зоны диктуют голосом) это не нужно, а зависимость от itch app вредит.
- Игры, у которых «сетевая» часть на itch, всегда берут внешнюю инфраструктуру (UGS, свой сервер и т.п.); на самом itch есть только каталог сторонних инструментов ([itch.io/tools: multiplayer-server](https://itch.io/tools/free/multiplayer-server)), но это не сервис itch.

## 2. Альтернативы без/с минимальным своим сервером

Условные обозначения: «сервер» — нужен ли свой постоянный сервер/VPS.

| Вариант | Свой сервер | NAT | Сложность внедрения | Лицензия / цена | Win + Linux | Источник |
|---|---|---|---|---|---|---|
| **Наш текущий relay на Go** (WebSocket-ретранслятор, код зоны) | Да, один маленький (Docker, статический бинарник) | Нет проблемы: клиенты ходят на сервер сами | Уже сделано | Своё; цена = VPS | Да (клиент Godot; сервер — Linux/Docker) | [server/README.md](../../server/README.md), [multiplayer.md](../plan/multiplayer.md) |
| **WebRTC + сигнальный сервер + STUN/TURN** (`WebRTCMultiplayerPeer`) | Сигнальный — да (лёгкий WebSocket), игровой трафик p2p | STUN решает часть NAT; для остального нужен TURN (бесплатные: Google STUN `stun.l.google.com:19302`; Open Relay от Metered — 20 ГБ TURN/мес на бесплатном плане) | Средняя-высокая: на нативных платформах нужен плагин `webrtc-native` (GDExtension); сигналинг и ICE писать самим; полная сетка p2p для 10 пилотов с нашей логикой «ведущего» — переделка | webrtc-native — MIT; STUN бесплатно; Open Relay — бесплатный лимит (условия сервиса могут меняться) | Да: Windows, Linux, macOS, Android, iOS (Godot 4.1+) | [Godot WebRTC](https://docs.godotengine.org/en/stable/tutorials/networking/webrtc.html), [webrtc-native](https://github.com/godotengine/webrtc-native), [Metered Open Relay](https://www.metered.ca/tools/openrelay/), [список STUN Google](https://dev.to/alakkadshaw/google-stun-server-list-21n4) |
| **Epic Online Services** (плагин EOSG) | Нет (Epic держит P2P-relay и лобби) | Встроенные hole-punching и relay | Средняя: аккаунт разработчика Epic, регистрация продукта (Product/Sandbox/Deployment/Client ID и Secret), принять условия EOS, политика приватности, `EOSGMultiplayerPeer` под Godot high-level API; наш протокол пришлось бы переложить на него | EOSG — MIT, Godot 4.2+; сам EOS бесплатен, без роялти и платы за хостинг (по данным Edgegap/Epic) | Да: Windows x64, Linux x64/arm64, macOS, Android, iOS | [EOSG](https://github.com/3ddelano/epic-online-services-godot), [EOS: бесплатно, relay](https://edgegap.com/comparison/edgegap-vs-epic-online-services-eos), [EOS overview](https://dev.epicgames.com/docs/epic-online-services/eos-overview) |
| **netfox + noray** | Да — свой noray (Bun/Docker, TCP 8890 и UDP 49152–51200 под relay); есть публичный «для прототипов» без гарантий (`tomfol.io:8890`) | NAT punchthrough, при неудаче relay (только UDP) | Средняя: ENet-кошелёк + `netfox.noray`; всё равно свой сервер, т.е. не проще нашего | MIT; Godot 4.x | Да (Godot-клиент; noray — Bun, есть Docker) | [netfox](https://github.com/foxssake/netfox), [noray](https://github.com/foxssake/noray) |
| **ENet + проброс портов** (UPnP/ручной) | Нет; один из пилотов — хост (но наша «зона» сейчас на сервере) | Нужен проброс UDP-порта на роутере хоста; UPnP есть в Godot, но не все роутеры поддерживают, порты могут пропадать; CGNAT/двойной NAT не пройти | Низкая технически, высокая для семьи (настройка роутера) | Встроено в Godot | Да | [Godot: UPNP](https://docs.godotengine.org/en/stable/classes/class_upnp.html) |
| **Tailscale** («LAN через интернет») | Нет (свои серверы координации у Tailscale; прямые p2p-соединения) | Решает сам | Низкая для кода (ничего не менять: хост слушает ENet/наш сервер на tailnet-IP), но каждый игрок ставит и входит в Tailscale | Personal — бесплатно, до 6 пользователей (по условиям на дату проверки) | Да (клиенты Win/Linux; не проверялось отдельно) | [Tailscale pricing](https://tailscale.com/pricing) |
| **ZeroTier** | Нет (корни ZeroTier) | Решает сам | Как у Tailscale: ставить клиент и вводить ID сети | Personal — бесплатно: 10 устройств, 1 сеть | Win/Linux — по общему знанию, на странице цен не подтверждено | [ZeroTier pricing](https://www.zerotier.com/pricing/) |
| **Radmin VPN** | Нет | Решает сам | Как выше | Бесплатен, без лимита пользователей | **Только Windows** — для Linux-пилотов не годится | [Radmin VPN](https://www.radmin-vpn.com/) |

## 3. Соотношение с нашим сервером и рекомендация

Что у нас сейчас: один ретранслятор на Go (WebSocket + protobuf), код зоны из 4 цифр, ведущий — первый подключившийся, без авторизации, всё в памяти, Docker на VPS; сервер не считает физику, только пересылает. Игроки вводят `IP:порт` и код ([multiplayer.md](../plan/multiplayer.md), [server/README.md](../../server/README.md)).

Единственная реальная слабость для семьи — нужен VPS с открытым портом (и адрес, который надо дать игрокам). Остальные варианты избавляют от VPS ценой другой сложности:
- WebRTC/noray/EOS не снимают нужды в серверной части совсем (WebRTC — сигналинг; noray — свой сервер) или требуют переписать сетевой слой (EOS, WebRTC) ради экономии одного маленького сервера.
- ENet + проброс портов перекладывает техническую работу на пилотов-хостов — хуже для людей, не любящих роутеры.
- VPN (Tailscale/ZeroTier) не требуют менять игру, но требуют, чтобы каждый поставил клиент; хост может запустить тот же `deltaplan-server` на своём ПК, VPS не нужен.

**Рекомендация.**
1. «Через itch.io» делать нечего: itch сеть не предоставляет. `ITCHIO_API_KEY` для нас бесполезен (аудитория крошечная, аккаунты не нужны, ключ работает только при запуске из itch app).
2. Оставить текущий сервер как основной путь: он уже сделан, не зависит от NAT и ничего не требует от гостей кроме кода. Если VPS нет или не хочется — запускать `deltaplan-server` на ПК одного из пилотов (сервер — один статический бинарник) поверх **Tailscale** (бесплатно до 6 пользователей) или ZeroTier (до 10 устройств); игре адрес сервера уже вводится вручную, код менять не придётся.
3. Рассматривать **Epic Online Services** только если захочется «без сервера и без VPN вообще»: это единственный из вариантов, где Epic берёт на себя relay и NAT бесплатно, но потребует аккаунт разработчика, регистрацию продукта и переписывание сетевого слоя под `EOSGMultiplayerPeer`; для 2–10 человек это не окупается.
4. Не делать: WebRTC (много своей работы, чтобы всё равно держать сигнальный сервер), Radmin VPN (только Windows).

## Что не проверено

- Условия использования EOS (страница документации не загрузилась; про бесплатность — заявление Edgegap/Epic-страниц из поиска).
- Актуальность бесплатных лимитов Tailscale/ZeroTier/Metered (взято со страниц на дату 01.10.2026).
- Работа `ITCHIO_API_KEY` с нашими сборками и манифестом `.itch.toml` не проверялась.
- Поддержка Linux у ZeroTier и Tailscale на страницах цен не указана.
