.PHONY: all app run test install clean

all: app

app:
	./scripts/build_app.sh

run: app
	open "dist/Disk Inventory.app"

test:
	swift test

install: app
	rm -rf "/Applications/Disk Inventory.app"
	cp -R "dist/Disk Inventory.app" "/Applications/Disk Inventory.app"
	@echo "Installed to /Applications/Disk Inventory.app"

clean:
	swift package clean
	rm -rf dist .build

