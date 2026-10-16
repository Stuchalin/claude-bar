# The active toolchain is Command Line Tools (Xcode's license is not accepted on this Mac, so
# DEVELOPER_DIR=/Applications/Xcode.app/... fails). CLT ships Swift Testing outside the default
# search paths: plain `swift test` fails with "no such module 'Testing'", so the framework
# directory is passed explicitly. Under a full Xcode toolchain run `make test TEST_FLAGS=`.
CLT_DEV := /Library/Developer/CommandLineTools/Library/Developer
TEST_FLAGS ?= -Xswiftc -F -Xswiftc $(CLT_DEV)/Frameworks \
	-Xlinker -F -Xlinker $(CLT_DEV)/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT_DEV)/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT_DEV)/usr/lib

.PHONY: build test app install

build:
	swift build

test:
	swift test $(TEST_FLAGS)

app:
	Scripts/package_app.sh

install:
	Scripts/package_app.sh install
