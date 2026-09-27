#!/usr/bin/env python3
"""Выдаёт действующий OAuth2-токен Freesound (печатает в stdout), при необходимости продлевает.

Ключи: ~/.config/freesound/credentials (CLIENT_ID=..., CLIENT_SECRET=...).
Токен: ~/.config/freesound/token.json (живёт 24 ч, продлевается refresh_token).
Использование: T=$(tools/freesound_token.py); curl -H "Authorization: Bearer $T" ...
Скачивание оригинала: GET https://freesound.org/apiv2/sounds/<id>/download/
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

DIR = os.path.expanduser("~/.config/freesound")
TOKEN = os.path.join(DIR, "token.json")


def creds() -> dict:
    out = {}
    with open(os.path.join(DIR, "credentials")) as f:
        for line in f:
            if "=" in line:
                k, v = line.strip().split("=", 1)
                out[k] = v
    return out


def main() -> None:
    with open(TOKEN) as f:
        tok = json.load(f)
    obtained = tok.get("obtained_at", os.path.getmtime(TOKEN))
    if time.time() < obtained + tok["expires_in"] - 600:
        print(tok["access_token"])
        return
    c = creds()
    data = urllib.parse.urlencode({
        "client_id": c["CLIENT_ID"], "client_secret": c["CLIENT_SECRET"],
        "grant_type": "refresh_token", "refresh_token": tok["refresh_token"],
    }).encode()
    with urllib.request.urlopen("https://freesound.org/apiv2/oauth2/access_token/", data) as r:
        new = json.load(r)
    if "access_token" not in new:
        sys.exit("freesound: не удалось продлить токен: %s" % new)
    new["obtained_at"] = time.time()
    old_umask = os.umask(0o077)
    with open(TOKEN, "w") as f:
        json.dump(new, f)
    os.umask(old_umask)
    print(new["access_token"])


if __name__ == "__main__":
    main()
