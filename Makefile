.PHONY: build bundle run clean

build:
	swift build
	BUILD_DIR=.build .build/checkouts/speech-swift/scripts/build_mlx_metallib.sh debug

bundle: build
	mkdir -p Edward.app/Contents/MacOS Edward.app/Contents/Resources
	cp Resources/AppIcon.icns Edward.app/Contents/Resources/AppIcon.icns
	cp Sources/Edward/Info.plist Edward.app/Contents/Info.plist
	@if ! cmp -s .build/debug/Edward Edward.app/Contents/MacOS/Edward 2>/dev/null; then \
		cp .build/debug/Edward Edward.app/Contents/MacOS/Edward; \
		cp .build/debug/mlx.metallib Edward.app/Contents/MacOS/mlx.metallib; \
		codesign --force --sign - Edward.app/Contents/MacOS/mlx.metallib; \
		codesign --force --sign - --entitlements Edward.entitlements Edward.app; \
		echo "Built Edward.app (binary changed, re-signed)"; \
	else \
		echo "Edward.app binary is up to date"; \
	fi

run: bundle
	@pkill -x Edward 2>/dev/null; sleep 0.5; open Edward.app

clean:
	swift package clean
	rm -rf Edward.app/Contents/MacOS/Edward Edward.app/Contents/MacOS/mlx.metallib
