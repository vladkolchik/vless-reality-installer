import os
import re
import shlex
import subprocess
from dataclasses import dataclass
from typing import List, Optional

from dotenv import load_dotenv
from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes


@dataclass
class Settings:
    token: str
    admins: List[int]
    vless_path: str = "/usr/local/bin/vless"
    output_dir: str = "/root/vless-configs"


def load_settings() -> Settings:
    load_dotenv()
    token = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
    admins_raw = os.getenv("TELEGRAM_ADMINS", "").strip()
    vless_path = os.getenv("VLESS_BIN", "/usr/local/bin/vless").strip()
    output_dir = os.getenv("VLESS_OUTPUT_DIR", "/root/vless-configs").strip()
    if not token:
        raise RuntimeError("TELEGRAM_BOT_TOKEN is not set")
    admins: List[int] = []
    if admins_raw:
        for part in re.split(r"[,\s]+", admins_raw):
            if not part:
                continue
            try:
                admins.append(int(part))
            except ValueError:
                pass
    if not admins:
        raise RuntimeError("TELEGRAM_ADMINS is empty; specify at least one admin user id")
    return Settings(token=token, admins=admins, vless_path=vless_path, output_dir=output_dir)


def is_admin(user_id: Optional[int], settings: Settings) -> bool:
    return user_id is not None and user_id in settings.admins


def run_vless(settings: Settings, args: List[str]) -> subprocess.CompletedProcess:
    # Use a strict command invocation; no shell injection
    cmd = [settings.vless_path] + args
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)


async def _guard_admin(update: Update, context: ContextTypes.DEFAULT_TYPE, settings: Settings) -> bool:
    uid = update.effective_user.id if update.effective_user else None
    if not is_admin(uid, settings):
        # silently ignore non-admins
        return False
    return True


async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE, settings: Settings) -> None:
    if not await _guard_admin(update, context, settings):
        return
    text = (
        "Available commands:\n"
        "/add <name> — add client\n"
        "/list — list clients\n"
        "/show <name|uuid> — show URLs and generate QR\n"
        "/del <name|uuid> — remove client\n"
        "/restart — restart xray\n"
        "/doctor — quick diagnostics\n"
    )
    await update.message.reply_text(text)


async def cmd_add(update: Update, context: ContextTypes.DEFAULT_TYPE, settings: Settings) -> None:
    if not await _guard_admin(update, context, settings):
        return
    if not context.args:
        await update.message.reply_text("Usage: /add <name>")
        return
    name = " ".join(context.args).strip()
    res = run_vless(settings, ["add", name])
    await update.message.reply_text(res.stdout or "(no output)")
    # Generate URLs and QR, then send
    await cmd_show(update, context, settings)


async def cmd_list(update: Update, context: ContextTypes.DEFAULT_TYPE, settings: Settings) -> None:
    if not await _guard_admin(update, context, settings):
        return
    res = run_vless(settings, ["list"])
    out = res.stdout.strip()
    if not out:
        out = "(no output)"
    await update.message.reply_text(out)


async def cmd_show(update: Update, context: ContextTypes.DEFAULT_TYPE, settings: Settings) -> None:
    if not await _guard_admin(update, context, settings):
        return
    if not context.args:
        await update.message.reply_text("Usage: /show <name|uuid>")
        return
    key = " ".join(context.args).strip()
    res = run_vless(settings, ["show", key])
    text = res.stdout or "(no output)"
    await update.message.reply_text(text)
    # Try to send QR images if present
    safe = sanitize_name(key)
    for suffix in ("443", "80"):
        path = os.path.join(settings.output_dir, f"{safe}_{suffix}.png")
        if os.path.exists(path):
            try:
                with open(path, "rb") as f:
                    await update.message.reply_photo(f, caption=os.path.basename(path))
            except Exception:
                pass


async def cmd_del(update: Update, context: ContextTypes.DEFAULT_TYPE, settings: Settings) -> None:
    if not await _guard_admin(update, context, settings):
        return
    if not context.args:
        await update.message.reply_text("Usage: /del <name|uuid>")
        return
    key = " ".join(context.args).strip()
    res = run_vless(settings, ["del", key])
    await update.message.reply_text(res.stdout or "(no output)")


async def cmd_restart(update: Update, context: ContextTypes.DEFAULT_TYPE, settings: Settings) -> None:
    if not await _guard_admin(update, context, settings):
        return
    res = run_vless(settings, ["restart"])
    await update.message.reply_text(res.stdout or "(no output)")


async def cmd_doctor(update: Update, context: ContextTypes.DEFAULT_TYPE, settings: Settings) -> None:
    if not await _guard_admin(update, context, settings):
        return
    res = run_vless(settings, ["doctor"])
    await update.message.reply_text(res.stdout or "(no output)")


def sanitize_name(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9._-]+", "_", value or "")[:50]
    return value or "vpn_profile"


def build_app(settings: Settings) -> Application:
    app = Application.builder().token(settings.token).build()

    # Bind partial handlers with settings via lambdas
    app.add_handler(CommandHandler("start", lambda u, c: cmd_start(u, c, settings)))
    app.add_handler(CommandHandler("help", lambda u, c: cmd_start(u, c, settings)))
    app.add_handler(CommandHandler("add", lambda u, c: cmd_add(u, c, settings)))
    app.add_handler(CommandHandler("list", lambda u, c: cmd_list(u, c, settings)))
    app.add_handler(CommandHandler("show", lambda u, c: cmd_show(u, c, settings)))
    app.add_handler(CommandHandler("del", lambda u, c: cmd_del(u, c, settings)))
    app.add_handler(CommandHandler("restart", lambda u, c: cmd_restart(u, c, settings)))
    app.add_handler(CommandHandler("doctor", lambda u, c: cmd_doctor(u, c, settings)))

    return app


def main() -> None:
    settings = load_settings()
    # Ensure vless path exists
    if not os.path.exists(settings.vless_path):
        # Try fallback to repo path scripts/vless
        repo_vless = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "vless"))
        if os.path.exists(repo_vless):
            settings.vless_path = repo_vless
    app = build_app(settings)
    app.run_polling(close_loop=False)


if __name__ == "__main__":
    main()


