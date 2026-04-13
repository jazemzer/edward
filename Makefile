.PHONY: build bundle ui run run-ui clean

build:
	swift build
	BUILD_DIR=.build .build/checkouts/speech-swift/scripts/build_mlx_metallib.sh debug

# CLI app bundle
bundle: build
	mkdir -p Edward.app/Contents/MacOS Edward.app/Contents/Resources
	cp .build/debug/edward Edward.app/Contents/MacOS/edward
	cp .build/debug/mlx.metallib Edward.app/Contents/MacOS/mlx.metallib
	cp Sources/EdwardCLI/Info.plist Edward.app/Contents/Info.plist 2>/dev/null || true
	codesign --force --sign - Edward.app/Contents/MacOS/mlx.metallib
	codesign --force --sign - Edward.app
	@echo "Built Edward.app (CLI daemon)"

# Window UI app bundle
ui: build
	mkdir -p EdwardUI.app/Contents/MacOS EdwardUI.app/Contents/Resources
	cp Resources/AppIcon.icns EdwardUI.app/Contents/Resources/AppIcon.icns
	@if ! cmp -s .build/debug/EdwardUI EdwardUI.app/Contents/MacOS/EdwardUI 2>/dev/null; then \
		cp .build/debug/EdwardUI EdwardUI.app/Contents/MacOS/EdwardUI; \
		cp .build/debug/mlx.metallib EdwardUI.app/Contents/MacOS/mlx.metallib; \
		cp Sources/EdwardUI/Info.plist EdwardUI.app/Contents/Info.plist; \
		codesign --force --sign - EdwardUI.app/Contents/MacOS/mlx.metallib; \
		codesign --force --sign - EdwardUI.app; \
		echo "Built EdwardUI.app (binary changed)"; \
	else \
		cp Sources/EdwardUI/Info.plist EdwardUI.app/Contents/Info.plist; \
		echo "EdwardUI.app is up to date (no re-sign needed)"; \
	fi

run: bundle
	open Edward.app --args start --foreground

run-ui: ui
	open EdwardUI.app

clean:
	swift package clean
	rm -rf Edward.app/Contents/MacOS/edward Edward.app/Contents/MacOS/mlx.metallib
	rm -rf EdwardUI.app/Contents/MacOS/EdwardUI EdwardUI.app/Contents/MacOS/mlx.metallib
