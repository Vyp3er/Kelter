# Kelter installieren

Kelter startet Windows-Programme wie Steam auf dem Mac – über Wine, ohne virtuelle Maschine. Es gibt noch keine fertige Download-Version: Du baust die App einmal selbst. Das geht mit einem Befehl und dauert ein paar Minuten.

## Was du brauchst

- Einen Mac mit **Apple Silicon** und **macOS 27**
- **Xcode 27** aus dem App Store (einmal öffnen und die Zusatzkomponenten installieren lassen)
- **Speicherplatz:** etwa 1 GB für Kelter, Wine und die Bibliotheken, dazu Platz für Steam und Spiele (schnell 10–50 GB)
- **Rosetta 2:** Wine ist ein Intel-Programm. Fehlt Rosetta, bietet Kelter die Installation beim ersten Start an.

## 1. Herunterladen

Öffne die App **Terminal** und füge ein:

```bash
git clone https://github.com/Vyp3er/Kelter.git ~/Developer/Kelter
```

Ohne Git: auf **https://github.com/Vyp3er/Kelter** oben auf **Code → Download ZIP** klicken und die ZIP-Datei entpacken.

## 2. Bauen und installieren

```bash
cd ~/Developer/Kelter && scripts/install.sh
```

Das Skript baut Kelter, legt es in den Ordner **Programme** (ohne Schreibrechte dort nach `~/Applications`) und startet es. Kelter braucht keine besonderen Berechtigungen und kein Administrator-Passwort.

## 3. Der erste Start

Kelter öffnet die **Einrichtung** mit drei Schritten:

1. **Rosetta 2** – nur falls es fehlt. macOS fragt eventuell nach deinem Passwort.
2. **Wine-Engine laden** – empfohlen ist *Wine 10.0 (Sikarugir)*. Kelter lädt sie samt Bibliotheken (rund 260 MB) und prüft jede Datei per SHA-256.
3. **Test-Bottle** (optional) – ein kleines Test-Windows mit Notepad und Minesweeper.

Danach geht es in den **Katalog**: Bei **Steam** auf **Installieren** klicken. Kelter legt eine eigene Bottle an, lädt den offiziellen Steam-Installer und trägt Steam unter **Meine Apps** ein. Beim ersten Start aktualisiert sich Steam (rund 340 MB) und zeigt dann den Login. Spiele installierst du ganz normal in Steam. In Kelter erscheinen sie unter **Spiele in Steam** und lassen sich dort direkt starten.

## Wenn etwas nicht klappt

- Jede App hat ein **Log** mit **Log kopieren**. Darüber stehen Hinweise auf typische Probleme: Anti-Cheat, fehlende DLLs, Abstürze oder eine Engine, die nicht zu deinem macOS passt.
- **Schwarzes Bild oder Ruckeln in einem Spiel:** in der Steam-App bei **Spiele in Steam** → **…** → **Grafik für …** auf **DXVK** stellen.
- Spiele mit Kernel-Anti-Cheat (z. B. Valorant, viele Online-Shooter) laufen nicht. Kelter umgeht keinen Anti-Cheat und keinen Kopierschutz.
- Befehle zur Fehlersuche im Terminal stehen in der [README](README.md#fehlersuche-im-terminal).

## Neue Version installieren

```bash
cd ~/Developer/Kelter && git pull && scripts/install.sh
```

Engines, Bottles, installierte Spiele und Logs bleiben erhalten. Sie liegen unter `~/Library/Application Support/Kelter`, nicht in der App.

## Deinstallieren

1. In Kelter bei jeder Bottle auf **Alles beenden** klicken (beendet Steam und Spiele), dann Kelter beenden.
2. **Kelter** aus „Programme“ in den Papierkorb ziehen.
3. Optional auch alle Daten in den Papierkorb legen. **Damit sind auch alle Bottles, installierten Spiele und Spielstände weg**, die nicht in der Cloud gesichert sind:

   ```bash
   mv ~/Library/Application\ Support/Kelter ~/.Trash/
   ```
