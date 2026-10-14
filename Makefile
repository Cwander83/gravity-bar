.PHONY: all build release test app install run clean

all: build

build:
	swift build

release:
	swift build -c release

test:
	swift run GravityBar --test

app:
	./scripts/build_app.sh

install:
	./scripts/build_app.sh --install

run:
	swift run GravityBar

clean:
	swift package clean
	rm -rf dist .build
