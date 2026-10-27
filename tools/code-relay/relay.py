"""Relay of Telegram login codes for App Review.

Keeps a Telethon session on the owner's account, catches login-code messages
from the official Telegram service account (777000) and publishes the latest
code as code.json in a GitHub repository. The code is wiped after CODE_TTL.

Usage:
    python relay.py login   # one-time interactive login, creates the session
    python relay.py         # run the relay
"""
import asyncio
import base64
import json
import logging
import os
import re
import sys
import time
import urllib.error
import urllib.request

from telethon import TelegramClient, events

TG_API_ID = int(os.environ["TG_API_ID"])
TG_API_HASH = os.environ["TG_API_HASH"]
GH_TOKEN = os.environ["GH_TOKEN"]
GH_REPO = os.environ["GH_REPO"]
GH_BRANCH = os.environ.get("GH_BRANCH", "main")
GH_PATH = os.environ.get("GH_PATH", "code.json")
CODE_TTL = int(os.environ.get("CODE_TTL", "600"))
SESSION = os.environ.get("TG_SESSION", "/data/relay")

TELEGRAM_SERVICE_ID = 777000
CODE_RE = re.compile(r"(?:code|код)\D{0,12}(\d{5,6})", re.IGNORECASE)

log = logging.getLogger("relay")
scrub_task = None


def github_put(payload):
    """Writes code.json through the contents API, returns when committed."""
    url = f"https://api.github.com/repos/{GH_REPO}/contents/{GH_PATH}"
    headers = {
        "Authorization": f"Bearer {GH_TOKEN}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "opengram-code-relay",
    }
    sha = None
    try:
        req = urllib.request.Request(f"{url}?ref={GH_BRANCH}", headers=headers)
        with urllib.request.urlopen(req, timeout=15) as resp:
            sha = json.load(resp)["sha"]
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    body = {
        "message": "update",
        "branch": GH_BRANCH,
        "content": base64.b64encode(json.dumps(payload).encode()).decode(),
    }
    if sha:
        body["sha"] = sha
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers, method="PUT")
    with urllib.request.urlopen(req, timeout=15):
        pass


async def publish(code):
    payload = {"code": code, "ts": int(time.time()), "ttl": CODE_TTL}
    await asyncio.get_running_loop().run_in_executor(None, github_put, payload)


async def scrub_later():
    await asyncio.sleep(CODE_TTL)
    try:
        await publish(None)
        log.info("code wiped")
    except Exception:
        log.exception("wipe failed")


async def run():
    global scrub_task
    client = TelegramClient(SESSION, TG_API_ID, TG_API_HASH)
    await client.connect()
    if not await client.is_user_authorized():
        sys.exit("Session is not authorized: run `python relay.py login` first")

    @client.on(events.NewMessage(from_users=TELEGRAM_SERVICE_ID, incoming=True))
    async def on_service_message(event):
        global scrub_task
        match = CODE_RE.search(event.raw_text or "")
        if not match:
            return
        code = match.group(1)
        log.info("login code received (%s***)", code[:1])
        try:
            await publish(code)
        except Exception:
            log.exception("publish failed")
            return
        if scrub_task:
            scrub_task.cancel()
        scrub_task = asyncio.create_task(scrub_later())

    await publish(None)
    log.info("relay started, waiting for codes")
    await client.run_until_disconnected()


async def login():
    client = TelegramClient(SESSION, TG_API_ID, TG_API_HASH)
    await client.start()
    me = await client.get_me()
    print(f"Logged in as {me.first_name} ({me.id}). Session saved.")
    await client.disconnect()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    asyncio.run(login() if sys.argv[1:] == ["login"] else run())
