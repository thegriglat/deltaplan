#!/bin/sh
# Генерация Python-кода из proto/ в gen/ (контракт S1/S2 — docs/contracts/air-synth.md). Сгенерированное коммитится.
# Нужен рантайм protobuf той же или новее версии (см. шапку gen/air_synth/v1/corpus_pb2.py).
cd "$(dirname "$0")" && uvx --from grpcio-tools python -m grpc_tools.protoc -Iproto --python_out=gen --pyi_out=gen proto/air_synth/v1/corpus.proto
