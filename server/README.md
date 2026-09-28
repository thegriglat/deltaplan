# Deltaplan — сервер сетевой игры

Ретранслятор для полётов нескольких пилотов в одном небе. Сам не считает
атмосферу и физику полёта — только выдаёт и проверяет коды зон, определяет
ведущего (первый подключившийся) и пересылает сообщения (`PilotState`,
`ZoneState` и т. п.) между клиентами одной зоны. Без авторизации, всё
состояние в памяти. Контракт сообщений — `server/proto/deltaplan/v1/net.proto`
(человеческое описание — `docs/net_protocol.md`).

## Локальный запуск

```bash
cd server
make run          # соберёт и запустит на 127.0.0.1:8080
```

Проверка:

```bash
curl -i http://127.0.0.1:8080/healthz    # 200
curl http://127.0.0.1:8080/v1/status     # JSON: зоны и участники
```

Адрес и версия игры настраиваются флагами или переменными окружения:

| Флаг | Переменная окружения | По умолчанию |
|---|---|---|
| `-addr` | `DELTAPLAN_ADDR` | `:8080` |
| `-game-version` | `DELTAPLAN_GAME_VERSION` | (не проверяется) |

## Сборка

```bash
make build         # bin/deltaplan-server — под текущую ОС/архитектуру
make build-linux    # bin/deltaplan-server-linux-amd64 — статический бинарник для VPS
make build-arm64     # bin/deltaplan-server-linux-arm64 (если VPS на ARM)
```

Бинарник статический (`CGO_ENABLED=0`), без отладочной информации и локальных
путей (`-trimpath`, `-ldflags "-s -w"`) — на VPS не нужен ни Go, ни какие-либо
библиотеки. Проверить: `file bin/deltaplan-server-linux-amd64` должен показать
`statically linked`.

```bash
make test    # go test ./... -race
make lint    # go vet + staticcheck
```

## Развёртывание на чистом VPS (≤ 10 минут)

Предполагается Linux с systemd и правами sudo по SSH (Debian/Ubuntu; для
другого дистрибутива команды `ufw`/`apt` заменить на аналоги).

1. **Собрать бинарник локально** (кросс-компиляция, Go на VPS не нужен):
   ```bash
   cd server
   make build-linux
   ```

2. **Скопировать на сервер**:
   ```bash
   scp bin/deltaplan-server-linux-amd64 user@VPS_IP:/tmp/deltaplan-server
   ssh user@VPS_IP sudo install -m 755 /tmp/deltaplan-server /usr/local/bin/deltaplan-server
   ```

3. **Файл окружения** (необязателен — без него используются значения по
   умолчанию: `:8080`, версия не проверяется):
   ```bash
   scp deploy/deltaplan-server.env.example user@VPS_IP:/tmp/deltaplan-server.env
   ssh user@VPS_IP sudo install -m 640 /tmp/deltaplan-server.env /etc/default/deltaplan-server
   ssh user@VPS_IP sudo vi /etc/default/deltaplan-server   # при необходимости поправить
   ```

4. **Установить systemd-юнит**:
   ```bash
   scp deploy/deltaplan-server.service user@VPS_IP:/tmp/
   ssh user@VPS_IP sudo install -m 644 /tmp/deltaplan-server.service /etc/systemd/system/
   ssh user@VPS_IP sudo systemctl daemon-reload
   ssh user@VPS_IP sudo systemctl enable --now deltaplan-server
   ```
   `WantedBy=multi-user.target` + `enable` — сервер поднимется сам после
   перезагрузки VPS. `DynamicUser=yes` — отдельного системного пользователя
   заводить не нужно, systemd создаёт временного на время работы сервиса.

5. **Открыть порт в файрволе** (если используется ufw):
   ```bash
   ssh user@VPS_IP sudo ufw allow 8080/tcp
   ```
   (замените `8080` на порт из `DELTAPLAN_ADDR`, если меняли).

6. **Проверить**:
   ```bash
   curl -i http://VPS_IP:8080/healthz          # ожидается 200
   curl http://VPS_IP:8080/v1/status           # JSON: зоны и участники
   ssh user@VPS_IP sudo journalctl -u deltaplan-server -f   # логи в реальном времени
   ```

Игроки вводят в игре (экран «Сетевая игра» → поле «Сервер»): `VPS_IP:8080`
(или доменное имя, если оно есть, вместо IP).

## Обновление версии на VPS

```bash
cd server
make build-linux
scp bin/deltaplan-server-linux-amd64 user@VPS_IP:/tmp/deltaplan-server
ssh user@VPS_IP sudo install -m 755 /tmp/deltaplan-server /usr/local/bin/deltaplan-server
ssh user@VPS_IP sudo systemctl restart deltaplan-server
```
Активные зоны при перезапуске теряются (всё состояние в памяти) — предупредите
игроков заранее либо обновляйте, когда никто не летает.

## Регенерация кода из proto

Контракт (`proto/deltaplan/v1/net.proto`) — источник правды; Go-код в `gen/`
генерируется, руками не редактируется:

```bash
# один раз: инструменты в ~/go/bin
go install github.com/bufbuild/buf/cmd/buf@latest
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest

cd server
./gen.sh   # или: make gen
```

## Диагностика

- `curl http://IP:порт/v1/status` — список активных зон и участников (для
  отладки, без авторизации — не публиковать порт `/v1/status` шире, чем нужно
  доверенным игрокам).
- `journalctl -u deltaplan-server -f` — логи сервера (stdout сервиса).
- `systemctl status deltaplan-server` — состояние сервиса.
