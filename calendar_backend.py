"""Local JSON-lines bridge between the Omarchy widget and IONOS CalDAV.

Passwords only travel over stdin and are stored in the desktop Secret Service.
The metadata file contains account names, email addresses and calendar URLs.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import uuid
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from urllib.parse import unquote, urlsplit

import caldav
from icalendar import Calendar as ICalendar
from icalendar import Event as IEvent


APP = "omarchy-clock"
DATA_DIR = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / APP
ACCOUNTS_FILE = DATA_DIR / "accounts.json"


class CalendarError(Exception):
    pass


def accounts() -> list[dict]:
    if not ACCOUNTS_FILE.exists():
        return []
    try:
        value = json.loads(ACCOUNTS_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise CalendarError("Die gespeicherten Konten konnten nicht gelesen werden.") from exc
    if not isinstance(value, list):
        raise CalendarError("Die gespeicherten Konten sind ungültig.")
    return value


def write_accounts(value: list[dict]) -> None:
    DATA_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(DATA_DIR, 0o700)
    fd, name = tempfile.mkstemp(prefix="accounts.", dir=DATA_DIR, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, 0o600)
        os.replace(name, ACCOUNTS_FILE)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def secret(action: str, account_id: str, value: str | None = None) -> str:
    args = ["secret-tool", action]
    if action == "store":
        args += ["--label=Omarchy Kalender"]
    args += ["application", APP, "account", account_id]
    try:
        result = subprocess.run(
            args,
            input=value if action == "store" else None,
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise CalendarError("Der lokale Schlüsselbund ist nicht verfügbar.") from exc
    if action == "lookup":
        return result.stdout.rstrip("\n") if result.returncode == 0 else ""
    if result.returncode != 0:
        raise CalendarError("Der lokale Schlüsselbund konnte nicht geändert werden.")
    return ""


def required_text(data: dict, field: str, label: str, limit: int) -> str:
    value = str(data.get(field, "")).strip()
    if not value or len(value) > limit:
        raise CalendarError(f"Bitte {label} angeben (maximal {limit} Zeichen).")
    return value


def calendar_url(raw: str) -> str:
    url = raw.strip()
    parsed = urlsplit(url)
    if (
        parsed.scheme.lower() != "https"
        or not parsed.hostname
        or "." not in parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
    ):
        raise CalendarError("Bitte eine vollständige HTTPS-CalDAV-Adresse ohne Zugangsdaten angeben.")
    return url.rstrip("/") + "/"


def account_for(account_id: str) -> dict:
    for item in accounts():
        if item["id"] == account_id:
            return item
    raise CalendarError("Das Kalenderkonto wurde nicht gefunden.")


def open_calendar(account: dict, password: str | None = None):
    password = password if password is not None else secret("lookup", account["id"])
    if not password:
        raise CalendarError("Für dieses Konto fehlt das Passwort im lokalen Schlüsselbund.")
    client = caldav.DAVClient(
        url=account["url"],
        username=account["username"],
        password=password,
        timeout=15,
        require_tls=True,
        ssl_verify_cert=True,
    )
    return client, caldav.Calendar(client=client, url=account["url"])


def validate_resource_url(account: dict, raw: str) -> str:
    base = urlsplit(account["url"])
    resource = urlsplit(str(raw))
    if (
        resource.scheme.lower() != "https"
        or resource.netloc.lower() != base.netloc.lower()
        or not unquote(resource.path).startswith(unquote(base.path.rstrip("/") + "/"))
        or resource.query
        or resource.fragment
    ):
        raise CalendarError("Die Terminadresse gehört nicht zu diesem Kalender.")
    return str(raw)


def local_value(value: date | datetime) -> str:
    if isinstance(value, datetime):
        return value.astimezone().isoformat(timespec="minutes") if value.tzinfo else value.isoformat(timespec="minutes")
    return value.isoformat()


def event_times(component) -> tuple[date | datetime, date | datetime, bool]:
    start = component.decoded("DTSTART")
    if "DTEND" in component:
        end = component.decoded("DTEND")
    elif "DURATION" in component:
        end = start + component.decoded("DURATION")
    else:
        end = start + timedelta(days=1) if not isinstance(start, datetime) else start
    return start, end, not isinstance(start, datetime)


def day_keys(start: date | datetime, end: date | datetime, all_day: bool) -> list[str]:
    if isinstance(start, datetime):
        start_day = start.astimezone().date() if start.tzinfo else start.date()
        end_local = end.astimezone() if isinstance(end, datetime) and end.tzinfo else end
        end_day = end_local.date() if isinstance(end_local, datetime) else end_local
        if isinstance(end_local, datetime) and end_local.time() == time.min and end_local > start:
            end_day -= timedelta(days=1)
    else:
        start_day = start
        end_day = end - timedelta(days=1) if all_day and end > start else end
    count = max(1, min(366, (end_day - start_day).days + 1))
    return [(start_day + timedelta(days=i)).isoformat() for i in range(count)]


def normalized_event(obj, account: dict) -> dict:
    component = obj.icalendar_component
    start, end, all_day = event_times(component)
    return {
        "accountId": account["id"],
        "accountName": account["name"],
        "resourceUrl": str(obj.url),
        "etag": obj.etag or "",
        "title": str(component.get("SUMMARY", "Ohne Titel")),
        "location": str(component.get("LOCATION", "")),
        "start": local_value(start),
        "end": local_value(end),
        "allDay": all_day,
        "recurring": "RRULE" in component or "RECURRENCE-ID" in component,
        "days": day_keys(start, end, all_day),
    }


def month_window(data: dict) -> tuple[datetime, datetime]:
    try:
        year = int(data["year"])
        month = int(data["month"])
        start = datetime(year, month, 1).astimezone()
        end = (datetime(year + 1, 1, 1) if month == 12 else datetime(year, month + 1, 1)).astimezone()
    except (KeyError, TypeError, ValueError, OverflowError) as exc:
        raise CalendarError("Ungültiger Kalendermonat.") from exc
    return start, end


def list_events(data: dict) -> dict:
    start, end = month_window(data)
    found: list[dict] = []
    errors: list[dict] = []
    for account in accounts():
        try:
            client, calendar = open_calendar(account)
            with client:
                objects = calendar.search(start=start, end=end, event=True, expand=True)
                for obj in objects:
                    try:
                        found.append(normalized_event(obj, account))
                    except (ValueError, KeyError, AttributeError):
                        continue
        except Exception as exc:
            errors.append({"accountId": account["id"], "name": account["name"], "message": public_error(exc)})
    found.sort(key=lambda item: (item["start"][:10], not item["allDay"], item["start"], item["title"].lower()))
    return {"events": found, "errors": errors, "year": start.year, "month": start.month}


def master_event(obj):
    instance = obj.icalendar_instance
    if instance is None:
        raise CalendarError("Dieser Termin enthält keine Kalendereinträge.")
    events = [part for part in instance.subcomponents if part.name == "VEVENT"]
    for part in events:
        if "RECURRENCE-ID" not in part:
            return part
    if events:
        return events[0]
    raise CalendarError("Dieser Kalendereintrag ist kein Termin.")


def load_event(data: dict) -> dict:
    account = account_for(str(data.get("accountId", "")))
    url = validate_resource_url(account, str(data.get("resourceUrl", "")))
    client, calendar = open_calendar(account)
    with client:
        obj = calendar.event_by_url(url)
        component = master_event(obj)
        start, end, all_day = event_times(component)
        return {
            "accountId": account["id"],
            "accountName": account["name"],
            "resourceUrl": url,
            "etag": obj.etag or "",
            "title": str(component.get("SUMMARY", "")),
            "location": str(component.get("LOCATION", "")),
            "description": str(component.get("DESCRIPTION", "")),
            "start": local_value(start),
            "end": local_value(end),
            "allDay": all_day,
            "recurring": "RRULE" in component or any("RECURRENCE-ID" in p for p in obj.icalendar_instance.subcomponents),
        }


def parse_event_fields(data: dict) -> dict:
    title = required_text(data, "title", "einen Titel", 255)
    location = str(data.get("location", "")).strip()
    description = str(data.get("description", "")).strip()
    if len(location) > 1024 or len(description) > 8192:
        raise CalendarError("Ort oder Beschreibung ist zu lang.")
    all_day = data.get("allDay") is True
    try:
        if all_day:
            start = date.fromisoformat(str(data["start"]))
            end_inclusive = date.fromisoformat(str(data["end"]))
            end = end_inclusive + timedelta(days=1)
        else:
            start = datetime.fromisoformat(str(data["start"]))
            end = datetime.fromisoformat(str(data["end"]))
            if start.tzinfo is None:
                start = start.astimezone()
            if end.tzinfo is None:
                end = end.astimezone()
        if end <= start:
            raise ValueError("end before start")
    except (KeyError, TypeError, ValueError, OverflowError) as exc:
        raise CalendarError("Beginn und Ende des Termins sind ungültig.") from exc
    return {"title": title, "location": location, "description": description, "start": start, "end": end, "all_day": all_day}


def apply_fields(component, fields: dict) -> None:
    for key in ("SUMMARY", "LOCATION", "DESCRIPTION", "DTSTART", "DTEND", "DURATION"):
        component.pop(key, None)
    component.add("summary", fields["title"])
    if fields["location"]:
        component.add("location", fields["location"])
    if fields["description"]:
        component.add("description", fields["description"])
    component.add("dtstart", fields["start"])
    component.add("dtend", fields["end"])
    component.pop("LAST-MODIFIED", None)
    component.add("last-modified", datetime.now(timezone.utc))


def save_event(data: dict) -> dict:
    account = account_for(str(data.get("accountId", "")))
    fields = parse_event_fields(data)
    client, calendar = open_calendar(account)
    with client:
        if data.get("resourceUrl"):
            url = validate_resource_url(account, str(data["resourceUrl"]))
            obj = calendar.event_by_url(url)
            expected = str(data.get("etag", ""))
            if expected and obj.etag != expected:
                raise CalendarError("Der Termin wurde inzwischen geändert. Bitte neu laden.")
            component = master_event(obj)
            apply_fields(component, fields)
            obj.data = obj.icalendar_instance.to_ical()
            obj.save(no_create=True, only_this_recurrence=False)
        else:
            ics = ICalendar()
            ics.add("prodid", "-//Omarchy Clock IONOS Calendar//DE")
            ics.add("version", "2.0")
            component = IEvent()
            component.add("uid", f"{uuid.uuid4()}@omarchy-clock.local")
            component.add("dtstamp", datetime.now(timezone.utc))
            apply_fields(component, fields)
            ics.add_component(component)
            obj = calendar.save_event(ics.to_ical().decode("utf-8"), no_overwrite=True)
    return {"resourceUrl": str(obj.url)}


def delete_event(data: dict) -> dict:
    account = account_for(str(data.get("accountId", "")))
    url = validate_resource_url(account, str(data.get("resourceUrl", "")))
    expected = str(data.get("etag", ""))
    client, calendar = open_calendar(account)
    with client:
        obj = calendar.event_by_url(url)
        if expected and obj.etag != expected:
            raise CalendarError("Der Termin wurde inzwischen geändert. Bitte neu laden.")
        headers = {"If-Match": obj.etag} if obj.etag else {}
        response = client.request(url, method="DELETE", headers=headers)
        if response.status not in (200, 202, 204):
            if response.status == 412:
                raise CalendarError("Der Termin wurde inzwischen geändert. Bitte neu laden.")
            raise CalendarError(f"Der Termin konnte nicht gelöscht werden (HTTP {response.status}).")
    return {}


def save_account(data: dict) -> dict:
    name = required_text(data, "name", "einen Kontonamen", 80)
    username = required_text(data, "username", "die vollständige E-Mail-Adresse", 254)
    if "@" not in username:
        raise CalendarError("Bitte die vollständige IONOS-E-Mail-Adresse angeben.")
    url = calendar_url(required_text(data, "url", "die CalDAV-Adresse", 2048))
    current = accounts()
    account_id = str(data.get("accountId", "")) or str(uuid.uuid4())
    existing = next((item for item in current if item["id"] == account_id), None)
    if data.get("accountId") and existing is None:
        raise CalendarError("Das Kalenderkonto wurde nicht gefunden.")
    password = str(data.get("password", "")) or (secret("lookup", account_id) if existing else "")
    if not password:
        raise CalendarError("Bitte ein Passwort oder IONOS-App-Passwort eingeben.")
    item = {"id": account_id, "name": name, "username": username, "url": url}
    client, calendar = open_calendar(item, password)
    with client:
        now = datetime.now().astimezone()
        calendar.search(start=now - timedelta(days=1), end=now + timedelta(days=1), event=True)
    if data.get("password"):
        secret("store", account_id, password)
    write_accounts([item if old["id"] == account_id else old for old in current] if existing else current + [item])
    return {"account": item}


def remove_account(data: dict) -> dict:
    account_id = str(data.get("accountId", ""))
    account_for(account_id)
    secret("clear", account_id)
    write_accounts([item for item in accounts() if item["id"] != account_id])
    return {}


def public_error(exc: Exception) -> str:
    if isinstance(exc, CalendarError):
        return str(exc)
    name = type(exc).__name__.lower()
    if "authorization" in name or "forbidden" in name:
        return "IONOS hat die Anmeldung oder den Zugriff abgelehnt."
    if "notfound" in name:
        return "Die CalDAV-Adresse wurde nicht gefunden."
    if "etag" in name or "precondition" in name:
        return "Der Termin wurde inzwischen geändert. Bitte neu laden."
    if "timeout" in name or "connection" in name:
        return "IONOS ist gerade nicht erreichbar."
    return "Die Kalenderanfrage ist fehlgeschlagen. Bitte Konto und CalDAV-Adresse prüfen."


OPERATIONS = {
    "accounts": lambda data: {"accounts": accounts()},
    "save_account": save_account,
    "remove_account": remove_account,
    "events": list_events,
    "event": load_event,
    "save_event": save_event,
    "delete_event": delete_event,
}


def main() -> None:
    for line in sys.stdin:
        try:
            request = json.loads(line)
            operation = str(request.get("operation", ""))
            if operation not in OPERATIONS:
                raise CalendarError("Unbekannte Kalenderaktion.")
            data = OPERATIONS[operation](request.get("data") or {})
            response = {"id": request.get("id"), "operation": operation, "ok": True, "data": data}
        except Exception as exc:
            response = {
                "id": request.get("id") if isinstance(locals().get("request"), dict) else None,
                "operation": request.get("operation") if isinstance(locals().get("request"), dict) else None,
                "ok": False,
                "error": public_error(exc),
            }
        print(json.dumps(response, ensure_ascii=False, default=str), flush=True)
        request = None


if __name__ == "__main__":
    main()
