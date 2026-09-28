BINARY := deltaplan-server
CMD := ./cmd/deltaplan-server
BIN_DIR := bin

# Статическая сборка: без CGO, без отладочной информации, без абсолютных путей.
LDFLAGS := -s -w
GOFLAGS := -trimpath

.PHONY: build build-linux build-arm64 test lint gen run clean

build:
	CGO_ENABLED=0 go build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o $(BIN_DIR)/$(BINARY) $(CMD)

build-linux:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o $(BIN_DIR)/$(BINARY)-linux-amd64 $(CMD)

build-arm64:
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o $(BIN_DIR)/$(BINARY)-linux-arm64 $(CMD)

test:
	go test -race ./...

lint:
	go vet ./...
	@if command -v staticcheck >/dev/null 2>&1; then \
		staticcheck ./...; \
	elif [ -x "$$HOME/go/bin/staticcheck" ]; then \
		"$$HOME/go/bin/staticcheck" ./...; \
	else \
		echo "staticcheck не найден (см. README: go install honnef.co/go/tools/cmd/staticcheck@latest)"; \
		exit 1; \
	fi

gen:
	./gen.sh

run: build
	DELTAPLAN_ADDR=127.0.0.1:8080 ./$(BIN_DIR)/$(BINARY)

clean:
	rm -rf $(BIN_DIR)
