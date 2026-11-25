# Kelter

Ein Wine-Launcher für macOS (Apple Silicon, macOS 27): Windows-Programme wie Steam auf dem Mac
installieren und starten – ohne virtuelle Maschine. Kelter lädt fertige Wine-Builds, legt pro App
eine eigene Bottle (WINEPREFIX) an und kümmert sich um Grafik, Controller und Logs.

**Installieren:** Anleitung in [INSTALLATION.md](INSTALLATION.md). Kurz: macOS 27, Apple Silicon,
Xcode 27, dann

```bash
git clone https://github.com/Vyp3er/Kelter.git ~/Developer/Kelter && cd ~/Developer/Kelter && scripts/install.sh
```

## Funktionen

| Bereich | Was es kann |
|---|---|
| **Katalog** | Kacheln mit Suche, 1-Klick-Installation aus JSON-Rezepten: Steam, Epic Games Launcher, GOG Galaxy, Battle.net, Ubisoft Connect, EA app. Nur offizielle Installer der Anbieter. |
| **Meine Apps** | Alle Apps mit Icon, Start/Stop, Status (läuft/beendet), CPU/RAM, Log-Verlauf, FPS-Overlay pro App. |
| **Steam-Spiele** | In der Steam-App: installierte Spiele (aus `appmanifest_*.acf`), direkt starten, als eigene App eintragen, Grafik-Ausnahme pro Spiel. |
| **Bottles** | Anlegen, löschen (Papierkorb), im Finder öffnen, „Alles beenden“. Unter „Erweitert“: Engine, Windows-Version, Grafik-Backend, Ausnahmen pro Programm, Controller-Modus, msync, WINEDEBUG, Umgebungsvariablen, Startargumente. |
| **Grafik** | DXMT (Standard), DXVK, WineD3D – pro Bottle umschaltbar, plus Ausnahmen pro Programm. |
| **Controller** | Verbundene Controller (GameController-Framework) mit Live-Test; pro Bottle SDL/macOS-Dienst/IOHID/ohne Xbox-Zuordnung; Joystick-Einstellungen der Bottle öffnen. |
| **Logs** | `Logs/<App>-<Datum>.log`, In-App-Anzeige, „Log kopieren“, automatische Hinweise auf Anti-Cheat, fehlende DLLs und Abstürze. |
| **Engines** | Wine-Engines, Laufzeit-Bibliotheken, DXMT, DXVK laden (mit SHA-256-Prüfung), mehrere parallel, eine als Standard. |

## Aufbau

```
Kelter.xcodeproj          Xcode-Projekt (Ordner „Kelter/“ wird automatisch synchronisiert)
Kelter/                   SwiftUI-App: Oberfläche + AppModel
  Assets.xcassets         App-Icon (erzeugt mit scripts/make-icon.swift)
Packages/WineKit/         Alles Wine-Spezifische, getrennt von der UI
  Sources/WineKit/
    Setup/                Rosetta
    Components/           Komponenten-Katalog, Installer, Engine-Layout
    Catalog/              App-Rezepte, Rezept-Installer, Laufzeitkomponenten
    Bottles/              Bottle, Einstellungen
    Apps/                 Meine Apps, Icons aus EXE-Dateien, Steam-Bibliothek
    Wine/                 Umgebung, Start-Planung (Grafik/Controller), Registry, Prozesse, Logs
    Resources/            components.json, prerequisites.json, Recipes/*.json
scripts/install.sh        Release-Build nach /Applications (Daten bleiben erhalten)
scripts/build.sh          Debug-Build nach build/Kelter.app
scripts/make-icon.swift   zeichnet das App-Icon neu
```

Daten unter `~/Library/Application Support/Kelter/`:

| Ordner | Inhalt |
|---|---|
| `Engines/<id>/` | Wine-Engines und Komponenten (`kelter-engine.json` + `files/`), ggf. `Varianten/` (APFS-Klone mit DXMT) |
| `Bottles/<Name>/` | WINEPREFIX + `kelter-bottle.json`, `kelter-apps.json`, `kelter-prerequisites.json`, `kelter-icons/` |
| `Catalog/` | eigene Rezepte (`*.json`), eigene Komponenten (`components.json`), Vorlagen in `Mitgeliefert/` |
| `Logs/` | ein Log pro Start |
| `Downloads/` | Zwischenablage (wird nach jeder Installation geleert) |

## Wie Kelter Wine einrichtet

**Engine:** Standard ist Wine 10.0 „Sikarugir“ (Gcenx, `10.0_8`): msync + DXMT-Unterstützung.
Wine 11.0 „Sikarugir“ (`11.0_1`) startet ab macOS 27 außerhalb der Sikarugir-App keine
Windows-Prozesse (`failed to start wineboot 1`, Sikarugir-Issue #295) – Kelter markiert sie als
„läuft hier nicht“ und stellt automatisch auf eine passende Engine um. Die
Hilfsbibliotheken (FreeType, GnuTLS, SDL, MoltenVK, GStreamer) kommen als „Sikarugir-Bibliotheken“
aus der Sikarugir-Vorlage und werden über `DYLD_FALLBACK_LIBRARY_PATH` eingebunden. Aus der
Vorlage entpackt Kelter nur Bibliotheken und die DXMT/DXVK-Builds – **nicht** Apples D3DMetal.

**Grafik** (vor jedem Start geplant, Registry/DLLs nur bei Änderungen neu geschrieben):

- **DXMT:** über einen zusätzlichen DLL-Suchpfad auf `renderer/dxmt/wine` – bei Sikarugir
  `WINEDLLPATH_DXMT`, sonst `WINEDLLPATH_PREPEND` (Kelter prüft in der `ntdll.so` der Engine,
  was sie kennt). Kennt sie keins, baut Kelter DXMT in eine APFS-Klonkopie der Engine ein.
- **DXVK:** DXVK-macOS (native DLLs) in `system32`/`syswow64`, DLL-Overrides `native,builtin`.
- **WineD3D:** Wines eingebaute Übersetzung.
- **Ausnahmen pro Programm** über `HKCU\Software\Wine\AppDefaults\<exe>\DllOverrides`. In einer
  DXMT-Bottle geht nur „DXVK“, in einer DXVK-Bottle nur „WineD3D“.
- Steam: `steamwebhelper.exe` (die Oberfläche) läuft über DXVK, weil Chromium-Fenster unter DXMT
  schwarz bleiben. Spiele laufen über DXMT.

**Controller:** `HKLM\System\CurrentControlSet\Services\WineBus` („Enable SDL“, „Map Controllers“)
und SDL-Hinweise (`SDL_JOYSTICK_HIDAPI`, `SDL_JOYSTICK_MFI`, `SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS`).

**FPS-Overlay:** `MTL_HUD_ENABLED=1` (Metal Performance HUD, für DXMT und DXVK) oder `DXVK_HUD`.

**Status:** Kelter liest alle 2 s die eigenen Prozesse, behält die unter `Engines/` und ordnet sie
über `WINEPREFIX` der Bottle zu. CPU-Werte stammen aus der Differenz der CPU-Zeit.

## Eigenes Rezept anlegen

Datei `Catalog/<id>.json` anlegen (gleiche `id` ersetzt ein mitgeliefertes Rezept), dann im Menü
„Gehe zu → Katalog neu laden“ (⌘R). Vorlagen liegen in `Catalog/Mitgeliefert/`.

```json
{
  "id": "mein-launcher",
  "name": "Mein Launcher",
  "summary": "Kurzbeschreibung für die Kachel",
  "symbol": "gamecontroller.fill",
  "tint": "#336699",
  "installer": {
    "url": "https://hersteller.example/Setup.exe",
    "arguments": ["/S"],
    "interactive": false
  },
  "prerequisites": ["macos-fonts", "vcrun2022-x64"],
  "requiredComponents": ["dxvk-macos-1.10.3-async"],
  "graphicsBackend": "dxmt",
  "executableBackends": { "launcher-web.exe": "dxvk" },
  "windowsVersion": "win10",
  "executable": "C:\\Program Files\\Mein Launcher\\launcher.exe",
  "arguments": [],
  "environment": {},
  "knownIssues": ["…"]
}
```

Regeln: Installer-URL muss `https://` sein, `executable` ein Windows-Pfad. Laufzeitkomponenten:
`macos-fonts`, `vcrun2022-x64`, `vcrun2022-x86`.

## Bauen

Installieren bzw. aktualisieren (Release-Build nach „Programme“, Daten bleiben erhalten):

```bash
scripts/install.sh
```

Zum Entwickeln in Xcode `Kelter.xcodeproj` öffnen und ⌘R drücken – oder ein Debug-Build nach
`build/Kelter.app`:

```bash
scripts/build.sh --open
```

Tests der Wine-Schicht:

```bash
cd Packages/WineKit && swift test
```

## Fehlersuche im Terminal

Rosetta da?

```bash
arch -x86_64 /usr/bin/true && echo "Rosetta OK"
```

Engine-Version:

```bash
~/Library/Application\ Support/Kelter/Engines/wine-sikarugir-10.0_8/files/bin/wine --version
```

Hat der Wine-Starter der Engine Wines Speicher-Reservierung? (Zahl ≥ 1 = ja; bei 0 starten
Windows-Programme meist nicht – so wie bei Wine 11.0 Sikarugir unter macOS 27)

```bash
otool -l ~/Library/Application\ Support/Kelter/Engines/wine-sikarugir-10.0_8/files/bin/wine | grep -c WINE_RESERVE
```

Über welche Variable bindet die Engine DXMT ein? (Ausgabe `WINEDLLPATH_DXMT` = direkt, nichts = Engine-Kopie)

```bash
grep -o -a -m1 -E "WINEDLLPATH_(DXMT|PREPEND)" ~/Library/Application\ Support/Kelter/Engines/wine-sikarugir-10.0_8/files/lib/wine/x86_64-unix/ntdll.so
```

Laufende Wine-Prozesse:

```bash
pgrep -fl Kelter/Engines
```

Letztes Log, nur Fehlerzeilen:

```bash
grep -E "err:|Unhandled|not found" "$(ls -t ~/Library/Application\ Support/Kelter/Logs/*.log | head -1)"
```

Alles in einer Bottle hart beenden (Beispiel „Steam“):

```bash
WINEPREFIX=~/Library/Application\ Support/Kelter/Bottles/Steam ~/Library/Application\ Support/Kelter/Engines/wine-sikarugir-10.0_8/files/bin/wineserver -k
```

## Grenzen

- Kein Umgehen von Anti-Cheat oder Kopierschutz. Spiele mit Kernel-Anti-Cheat laufen nicht; das Log zeigt es an.
- Apples D3DMetal/Game Porting Toolkit ist nicht enthalten.
- Eigene `.exe`-Dateien per Drag & Drop: noch nicht (geplant).

## Lizenz

Kelter steht unter der [MIT-Lizenz](LICENSE). Wine, DXMT, DXVK, MoltenVK und die übrigen
Bibliotheken liefert Kelter nicht mit: Es lädt sie beim Einrichten von ihren Projekten, sie
stehen unter ihren eigenen Lizenzen (meist LGPL, MIT, Zlib). Apples D3DMetal ist nicht dabei.
