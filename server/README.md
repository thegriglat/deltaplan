# Deltaplan — сервер сетевой игры

Ретранслятор для полётов нескольких пилотов в одном небе. Сам не считает
атмосферу и физику полёта — только выдаёт и проверяет коды зон, определяет
ведущего (первый подключившийся) и пересылает сообщения (`PilotState`,
`ZoneState` и т. п.) между клиентами одной зоны. Без авторизации, всё
состояние в памяти. Контракт сообщений — `server/proto/deltaplan/v1/net.proto`
(человеческое описание — `docs/guide/net-protocol.md`).

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

## Развёртывание на VPS (Docker)

На VPS нужен только Docker. Скопировать папку `server/` (или всю репу) и:

```bash
docker build -t deltaplan-server server/
docker run -d --name deltaplan-server --restart unless-stopped -p 8080:8080 deltaplan-server
```

`--restart unless-stopped` — сервер поднимается сам после перезагрузки VPS.
Проверить: `curl -i http://VPS_IP:8080/healthz` (200), `curl http://VPS_IP:8080/v1/status`
(зоны и участники), логи — `docker logs -f deltaplan-server`. Если включён файрвол —
открыть порт 8080/tcp.

Другой порт: `-p 9000:8080` (снаружи 9000). Проверка версии игры (в зоны пускать
только эту версию): `-e DELTAPLAN_GAME_VERSION=0.8.0`.

Игроки вводят в игре (экран «Сетевая игра» → поле «Сервер»): `VPS_IP:8080`.

## Обновление

```bash
docker build -t deltaplan-server server/
docker rm -f deltaplan-server
docker run -d --name deltaplan-server --restart unless-stopped -p 8080:8080 deltaplan-server
```
Активные зоны при перезапуске теряются (всё в памяти) — обновлять, когда никто не летает.

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
- `docker logs -f deltaplan-server` — логи сервера.
- `docker ps` — работает ли контейнер.
