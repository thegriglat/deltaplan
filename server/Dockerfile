# Сервер сетевой игры Deltaplan: статический бинарник в пустом образе (~10 МБ).
#   docker build -t deltaplan-server server/
#   docker run -d --name deltaplan-server --restart unless-stopped -p 8080:8080 deltaplan-server
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /deltaplan-server ./cmd/deltaplan-server

FROM scratch
COPY --from=build /deltaplan-server /deltaplan-server
ENV DELTAPLAN_ADDR=:8080
EXPOSE 8080
USER 65534:65534
ENTRYPOINT ["/deltaplan-server"]
