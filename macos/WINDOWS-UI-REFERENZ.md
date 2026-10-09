# Aktueller macOS-Stand als Referenz für Windows

Stand: 9. Oktober 2026. `main` enthält den aktuellen nativen macOS-Quellcode und alle vom Mac-Target verwendeten gemeinsamen Dateien unter `Shared/`. Plattformabhängiges Verhalten ist mit `#if os(macOS)` bzw. `#if os(iOS)` getrennt.

## Wo die Oberfläche definiert ist

| Bereich | Quelldatei |
| --- | --- |
| Seitenleiste, Navigation, Anmeldung, Wählen, Favoriten, Anrufliste, Kontakte, Audio-Einstellungen und große Gesprächsansicht | [`FonooMac/MacViews.swift`](FonooMac/MacViews.swift) |
| Kleines Gesprächsfenster beim Minimieren, Fensterverhalten und Gesprächsaktionen | [`FonooMac/MacMiniCallWindow.swift`](FonooMac/MacMiniCallWindow.swift) |
| Menüleistenstatus und Gesprächsaktionen außerhalb des Hauptfensters | [`FonooMac/MacCallStatusItem.swift`](FonooMac/MacCallStatusItem.swift) |
| Gemeinsamer Gesprächsstatus, Dauer und tatsächlicher Audiopegel | [`FonooMac/MacCallActivity.swift`](FonooMac/MacCallActivity.swift) |
| Gerätewahl und Mikrofonpegel | [`FonooMac/MacAudioManager.swift`](FonooMac/MacAudioManager.swift) |
| Firmenverzeichnis, Personen, Erreichbarkeit und persönliche Verfügbarkeit | [`../Shared/TeamView.swift`](../Shared/TeamView.swift) |
| Datenmodelle und API-Abgleich für das Firmenverzeichnis | [`../Shared/TeamMember.swift`](../Shared/TeamMember.swift), [`../Shared/TeamDirectory.swift`](../Shared/TeamDirectory.swift) |
| Kontozustand, Anmeldung und Cloud-Provisionierung | [`../Shared/CustomerAccount.swift`](../Shared/CustomerAccount.swift) |
| Gesprächssteuerung und Übergänge | [`../Shared/CallManager.swift`](../Shared/CallManager.swift) |

Die regulären Navigationspunkte heißen **Wählen**, **Favoriten**, **Anrufliste**, **Kontakte**, **Team** und **Konto**. Während eines Anrufs kommt **Gespräch** hinzu. Hauptfenster, kleines Gesprächsfenster und Menüleistenstatus verwenden denselben Gesprächszustand und denselben gemessenen Pegelverlauf.

fonoo-Violett ist in `MacStyle.accent` definiert: RGB `(0.43, 0.29, 0.85)`. Annahme ist grün; Auflegen und Ablehnen sind rot. Stumm und Halten erhalten eine sichtbare Auswahlmarkierung. Native Systemdarstellung, Tastaturbedienung und zugängliche Zustandsangaben gehören zum aktuellen Verhalten.

## Vorschau und Prüfung ohne Telefoniekonto

Das Xcode-Projekt liegt unter `FonooMac.xcodeproj`, Scheme **FonooMac**, Mindestversion macOS 14. Linphone ist über Swift Package Manager auf 5.5.23 festgelegt; HIDAPI-Quellcode und Lizenzen liegen unter `Vendor/hidapi/`.

```sh
./macos/build.sh
bash macos/Checks/run-device-checks.sh
```

Die Debug-App bietet isolierte Vorschauen über `--preview-call-ui` und `--preview-team-ui`. Sie verwenden synthetische Gesprächs-/Verzeichnisdaten. Weitere Bau-, Audio- und Laufzeitprüfungen sowie offene Abnahmen stehen in [`README.md`](README.md).

## Gemeinsame Profile und Telefonie

Jeder Benutzer startet mit dem Profil **Standard**, in dem alle eigenen Geräte aktiv sind. Zusätzliche Profile werden vom Benutzer benannt und enthalten die ausgewählten Geräte. Die Profilauswahl ist direkt in der Hauptoberfläche erreichbar und wird über den gemeinsamen Serverstand synchronisiert. Die Apple-Vertragsprüfungen liegen unter `Checks/DeviceProfileChecks.swift`. Die Serverimplementierung wird separat verwaltet.

Die Apple-Apps verwenden ausschließlich Liblinphone 5.5.23. Verbindungsaufbau und Wiederherstellung werden durch `SIPConnectionCoordinator` gesteuert. Die Windows-App wird separat entwickelt; ihre eigenen Änderungen müssen beim Abruf dieses Standes erhalten bleiben.

## Historischer Vergleich

Für neue Windows-Anpassungen die aktuellen Dateien von `main` und ihre gemeinsamen Schnittstellen verwenden. Die vollständige Vorgeschichte bleibt im bisherigen privaten Entwicklungsrepository erhalten.

Das Repository enthält Quellcode, Projektdateien, App-Assets, Testfixtures und Lizenzen. Build-Produkte, lokale Kontendatenbanken, Schlüsselbundinhalte, Tokens, private Schlüssel, Signierungszertifikate und Provisionierungsprofile gehören nicht zum Upload.
