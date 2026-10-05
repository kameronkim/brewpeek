APP := dist/BrewPeek.app
SOURCES := $(addprefix BrewPeek/,Upgrade.swift PackageRemoval.swift CleanupRecovery.swift VersionCleanup.swift DesktopVersionCleanup.swift DesktopUpdates.swift DesktopPackageRemoval.swift Desktop.swift DesktopRemoval.swift Inventory.swift InventorySizes.swift InventoryStore.swift)
WEB_FILES := $(addprefix BrewPeek/Web/,index.html styles.css inventory.js inventory-ui.js updates.js)
RESOURCES := BrewPeek/Resources

.PHONY: build
build:
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources" .build/module-cache
	swiftc -Osize -module-cache-path .build/module-cache $(SOURCES) -o "$(APP)/Contents/MacOS/BrewPeek"
	swiftc -Osize -parse-as-library -module-cache-path .build/module-cache BrewPeek/Askpass.swift -o "$(APP)/Contents/MacOS/BrewPeekAskpass"
	cp $(RESOURCES)/Info.plist "$(APP)/Contents/Info.plist"
	xcrun actool $(RESOURCES)/Assets.xcassets --compile "$(APP)/Contents/Resources" --platform macosx --minimum-deployment-target 12.0 --app-icon AppIcon --output-partial-info-plist .build/icon-info.plist
	/usr/libexec/PlistBuddy -c "Merge .build/icon-info.plist" "$(APP)/Contents/Info.plist"
	cp $(WEB_FILES) "$(APP)/Contents/Resources/"
	cp -R $(RESOURCES)/*.lproj "$(APP)/Contents/Resources/"
	xcrun strip -x "$(APP)/Contents/MacOS/BrewPeek"
	xcrun strip -x "$(APP)/Contents/MacOS/BrewPeekAskpass"
	codesign --force --sign - "$(APP)"
	codesign --verify --deep --strict "$(APP)"
