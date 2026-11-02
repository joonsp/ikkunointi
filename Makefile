.PHONY: all app test run install icon clean

all: app

app:
	./scripts/build.sh

test:
	swift test

run: app
	-pkill -x Ikkunointi; sleep 0.5
	open build/Ikkunointi.app

icon:
	swift scripts/make-icon.swift .

install: app
	-pkill -x Ikkunointi; sleep 0.5
	mkdir -p $(HOME)/Applications $(HOME)/.local/bin
	rm -rf $(HOME)/Applications/Ikkunointi.app
	cp -R build/Ikkunointi.app $(HOME)/Applications/
	ln -sf $(HOME)/Applications/Ikkunointi.app/Contents/MacOS/ikkunointictl $(HOME)/.local/bin/ikkunointictl
	open $(HOME)/Applications/Ikkunointi.app

clean:
	rm -rf .build build
