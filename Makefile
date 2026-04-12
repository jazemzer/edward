.PHONY: build bundle ui run run-ui clean

build:
	swift build
	BUILD_DIR=.build .build/checkouts/speech-swift/scripts/build_mlx_metallib.sh debug

# CLI app bundle
bundle: build
	mkdir -p Edward.app/Contents/MacOS Edward.app/Contents/Resources
	cp .build/debug/edward Edward.app/Contents/MacOS/edward
	cp .build/debug/mlx.metallib Edward.app/Contents/MacOS/mlx.metallib
	@echo "Built Edward.app (CLI daemon)"

# Menu bar UI app bundle
ui: build
	mkdir -p EdwardUI.app/Contents/MacOS EdwardUI.app/Contents/Resources
	cp .build/debug/EdwardUI EdwardUI.app/Contents/MacOS/EdwardUI
	cp .build/debug/mlx.metallib EdwardUI.app/Contents/MacOS/mlx.metallib
	@echo "Built EdwardUI.app (menu bar UI)"

run: bundle
	open Edward.app --args start --foreground

run-ui: ui
	open EdwardUI.app

clean:
	swift package clean
	rm -rf Edward.app/Contents/MacOS/edward Edward.app/Contents/MacOS/mlx.metallib
	rm -rf EdwardUI.app/Contents/MacOS/EdwardUI EdwardUI.app/Contents/MacOS/mlx.metallib
