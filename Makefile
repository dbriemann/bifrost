.PHONY: all test install package clean hotkey install-hotkey
all:
	./scripts/build.sh
test:
	./scripts/test.sh
install: all
	./scripts/install.sh
package: all
	./scripts/package.sh
hotkey:
	bash scripts/build-macos-hotkey.sh
install-hotkey: hotkey
	./scripts/install-macos-hotkey.py
clean:
	rm -rf build dist
