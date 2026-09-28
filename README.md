# Omarchy Clock mit IONOS-Kalender

Lokaler Fork des Omarchy-Widgets `omarchy.clock`. In der Leiste heißt er
`steven.clock`. Die Kalenderansicht zeigt Termine aus IONOS Mail Business
über CalDAV und erlaubt Erstellen, Bearbeiten und Löschen.

## Verbindung einrichten

1. In IONOS Webmail **Kalender** öffnen. Beim gewünschten Kalender über die
   drei Punkte **Eigenschaften** öffnen und die CalDAV-Adresse kopieren.
2. Auf die Uhr in der Omarchy-Leiste klicken, **Konten** und dann
   **Kalender hinzufügen** wählen.
3. Namen, vollständige IONOS-E-Mail-Adresse, CalDAV-Adresse und Passwort
   eingeben. Bei aktivierter Zwei-Schritt-Anmeldung ein IONOS-App-Passwort
   verwenden.

Für weitere Kalender denselben Ablauf wiederholen. Jedes Konto verwaltet eine
CalDAV-Kalenderadresse. Die Oberfläche prüft die Verbindung vor dem Speichern.

[IONOS-Anleitung zur CalDAV-Adresse](https://www.ionos.com/help/email/managing-mail-business/syncing-mail-business-calendar-with-mac-os-x/)

## Lokale Installation

`./install-local.sh` installiert die Python-Abhängigkeiten unter
`~/.local/share/omarchy-clock/venv`, verbindet dieses Projekt mit Omarchys
Plugin-Verzeichnis und aktiviert `steven.clock`. Die Quelldateien bleiben in
diesem Projektordner.

Kontoname, E-Mail-Adresse und Kalenderadresse liegen in
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
