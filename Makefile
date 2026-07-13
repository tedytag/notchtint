APP = NotchTint.app

build:
	swiftc -O notchtint.swift -o notchtint
	codesign -f -s - --identifier com.notchtint notchtint

run: build
	./notchtint

# Bundle as a .app: stable identity for the Screen Recording permission,
# proper name in System Settings, Start at Login via SMAppService.
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp notchtint $(APP)/Contents/MacOS/
	cp Info.plist $(APP)/Contents/
	@if [ -f AppIcon.icns ]; then cp AppIcon.icns $(APP)/Contents/Resources/; fi
	codesign -f -s - --identifier com.notchtint.app $(APP)

# Turn a 1024x1024 icon.png into AppIcon.icns (then re-run `make app`)
icon:
	rm -rf AppIcon.iconset
	mkdir AppIcon.iconset
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s icon.png --out AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) icon.png --out AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns AppIcon.iconset -o AppIcon.icns
	rm -rf AppIcon.iconset

clean:
	rm -rf notchtint $(APP) AppIcon.iconset

.PHONY: build run app icon clean
