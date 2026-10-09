# fonoo für macOS

Native SwiftUI/AppKit-App ab macOS 14, Bundle-ID `app.fonoo.macos`, Scheme **FonooMac**. Kein Catalyst. Dieses Repository enthält die Mac-App samt benötigten gemeinsamen Apple-Dateien, Assets, isolierten Prüfungen und Hersteller-Lizenzen. Ein zweiter iOS-Checkout ist zum Bauen nicht erforderlich.

## Bauen und prüfen

Xcode 27 und Swift auf macOS verwenden. Das bestehende Entwicklungsteam und die HIDAPI-Anbindung bleiben erhalten. Auf einem anderen Mac die eigene passende Signierung einrichten; private Schlüssel und Kontodaten gehören nicht in Git.

```sh
bash Checks/run-checks.sh
python3 Checks/customer-provisioning-checks.py
bash macos/Checks/run-device-checks.sh
./macos/build.sh
```

Die gebaute App liegt standardmäßig unter `/private/tmp/FonooMacNativeBuild/Build/Products/Debug/fonoo.app`. Bei synchronisierten Dokumentenordnern aus einer sauberen lokalen Quellkopie ohne Finder-Metadaten bauen. Intel, Notarisierung und ein echter Headset-Hörvergleich sind gesondert zu prüfen.

## Struktur und gemeinsame Dateien

- `macos/FonooMac/`: Oberfläche, Geräte-/Headset-Wahl, Gesprächsfenster und Menüleistenstatus.
- `Shared/`: die von der Mac-App verwendeten gemeinsamen Apple-Dateien; ursprüngliches Verhalten bleibt erhalten.
- `Checks/`: gemeinsame Verbindungs-, Konto-, Profil-, Präsenz- und Anrufhistorienprüfungen.
- `macos/Checks/`: Mac-Audiogeräte- und SDK-Laufzeitprüfungen.

Liblinphone 5.5.23 bleibt die einzige Telefonie-Engine. Team, Profile, Präsenz, Anrufhistorie, Weiterleitungen, Anmeldung und Audioverarbeitung bleiben erhalten. Der Kontoserver wird separat verwaltet.

Die [iOS-App](https://github.com/ivama-dev/fonoo-ios) ist die Referenz für die gemeinsamen Dateien. Mit `python3 scripts/sync-shared-from-ios.py --source ../fonoo-ios --check` lässt sich ihr Stand vergleichen. Ohne `--check` werden freigegebene Änderungen übernommen; lokal geänderte gemeinsame Dateien werden nicht überschrieben. Anschließend beide Apps bauen und ihre Prüfungen ausführen. Die Herkunft und Dateihashes stehen in `Shared/upstream.json`.

Die [Mac-Oberfläche als Referenz für Windows](macos/WINDOWS-UI-REFERENZ.md) bleibt enthalten.

## Übernahme und Lizenzen

Übernommen wurde der aktuelle Quellstand vom 9. Oktober 2026 (Build 26). Ausschließlich Projektpfade und Prüfpfade wurden an das eigene Repository angepasst. Die ursprüngliche private Git-Historie bleibt im bisherigen Repository und wird wegen des dort enthaltenen Servercodes nicht hier veröffentlicht. Eine Store-Veröffentlichung erfolgt durch die Migration nicht.

[Drittanbieter und Lizenzdateien](THIRD-PARTY-NOTICES.md). GitHub-Prüfungen verwenden synthetische Daten und benötigen keine Produktionszugänge.
