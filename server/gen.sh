#!/usr/bin/env bash
# Проверка и генерация Go-кода из proto/deltaplan/v1/net.proto → gen/deltaplan/v1/net.pb.go.
# Нужны buf и protoc-gen-go в PATH (или в ~/go/bin):
#   go install github.com/bufbuild/buf/cmd/buf@latest
#   go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$PATH:$(go env GOPATH)/bin"
buf lint
buf generate
echo "gen: ok"
