.PHONY: all test install package clean
all:
	./scripts/build.sh
test:
	./scripts/test.sh
install: all
	./scripts/install.sh
package: all
	./scripts/package.sh
clean:
	rm -rf build dist
