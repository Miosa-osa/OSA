.PHONY: build clean vet

BIN := osa

build:
	go build -o $(BIN) .

clean:
	rm -f $(BIN)

vet:
	go vet ./...

all: vet build
