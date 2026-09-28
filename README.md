# Omarchy Clock mit Nextcloud-Kalender und Aufgaben

Lokaler Fork des Omarchy-Widgets `omarchy.clock`. In der Leiste heißt er
`steven.clock`. Die Kalenderansicht zeigt Termine aus Nextcloud
über CalDAV und erlaubt Erstellen, Bearbeiten und Löschen. Der Reiter
**Aufgaben** zeigt die Nextcloud-Aufgabenlisten desselben Kontos.

## Verbindung einrichten

1. In Nextcloud **Kalender** öffnen und die persönliche CalDAV-Adresse des
   gewünschten Kalenders kopieren. Unter **Persönliche Einstellungen → Sicherheit**
   ein eigenes App-Passwort für dieses Widget erstellen.
2. Auf die Uhr in der Omarchy-Leiste klicken, **Konten** und dann
   **Kalender hinzufügen** wählen.
3. Namen, Nextcloud-Benutzernamen, CalDAV-Adresse und App-Passwort eingeben.
   Das App-Passwort gehört nur in das Widget, nicht in ein Terminal oder den Chat.

Beim Wechsel in ein anderes Fenster schließt sich das Popup. Die Formularfelder
bleiben erhalten; ein erneuter Klick auf die Uhr öffnet sie wieder. **Abbrechen**
verwirft das App-Passwort.

Für weitere Kalender denselben Ablauf wiederholen. Jedes Konto verwaltet eine
CalDAV-Kalenderadresse. Die Oberfläche prüft die Verbindung vor dem Speichern.
Aufgabenlisten werden danach automatisch aus dem Nextcloud-Konto gefunden;
du brauchst für sie weder eine weitere Adresse noch ein weiteres Passwort.
Über dem Monatsraster wechseln Mausrad und Zwei-Finger-Scrollen auf dem Touchpad
zwischen den Monaten; die Pfeile unter dem Raster funktionieren ebenfalls.

## Aufgaben

Im Reiter **Aufgaben** erscheinen offene Aufgaben aus allen erreichbaren
Nextcloud-Aufgabenlisten. **Erledigte anzeigen** blendet abgeschlossene Aufgaben
ein. Das Kästchen neben einer Aufgabe schließt sie ab oder öffnet sie erneut;
ein Klick auf den Text öffnet Titel, Beschreibung und Fälligkeit zur Bearbeitung.
Über **+** wird eine Aufgabe angelegt. Die Aufgabenliste kann dabei gewählt
werden; als Fälligkeit ist der im Kalender markierte Tag vorbelegt und kann
geändert oder geleert werden. **Löschen** erfordert eine Bestätigung.

Die Aufgaben werden beim Öffnen des Reiters und bei geöffnetem Popup alle fünf
Minuten aktualisiert. Änderungen werden direkt nach Nextcloud geschrieben.
Bei Serienaufgaben gelten Bearbeiten und Löschen für die ganze Serie.

[Nextcloud-Dokumentation zu App-Passwörtern](https://docs.nextcloud.com/server/stable/user_manual/en/session_management.html)

## Lokale Installation

`./install-local.sh` installiert die Python-Abhängigkeiten unter
`~/.local/share/omarchy-clock/venv`, verbindet dieses Projekt mit Omarchys
Plugin-Verzeichnis und aktiviert `steven.clock`. Die Quelldateien bleiben in
diesem Projektordner.

Kontoname, Benutzername und Kalenderadresse liegen in
`~/.local/share/omarchy-clock/accounts.json` mit Dateirechten `0600`.
Passwörter liegen ausschließlich im lokalen Secret-Service-Schlüsselbund.
Das Plugin überträgt Daten nur per HTTPS mit Zertifikatsprüfung.

Termine werden beim Öffnen, beim Monatswechsel und bei geöffnetem Popup alle
fünf Minuten geladen. Änderungen werden sofort auf den CalDAV-Server
geschrieben. Bei Serienterminen gelten Bearbeiten
und Löschen für die gesamte Serie; einzelne Vorkommen können nicht gesondert
geändert werden. Neue Serien können derzeit nicht angelegt werden.

Der Fork basiert auf Omarchys eingebautem Clock-Plugin unter
`/usr/share/omarchy/shell/plugins/panels/clock/`. Dateien unter
`/usr/share/omarchy/` werden nicht verändert.
