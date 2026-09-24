APP := BrewPeek.app
SOURCES := Desktop.swift DesktopRemoval.swift Inventory.swift InventoryStore.swift

.PHONY: build
build:
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" .build/module-cache
	swiftc -Osize -module-cache-path .build/module-cache $(SOURCES) -o "$(APP)/Contents/MacOS/BrewPeek"
	cp resources/Info.plist "$(APP)/Contents/Info.plist"
	xcrun actool resources/Assets.xcassets --compile "$(APP)/Contents/Resources" --platform macosx --minimum-deployment-target 12.0 --app-icon AppIcon --output-partial-info-plist .build/icon-info.plist
	/usr/libexec/PlistBuddy -c "Merge .build/icon-info.plist" "$(APP)/Contents/Info.plist"
	cp index.html "$(APP)/Contents/Resources/"
	xcrun strip -x "$(APP)/Contents/MacOS/BrewPeek"
	codesign --force --sign - "$(APP)"
	codesign --verify --deep --strict "$(APP)"
