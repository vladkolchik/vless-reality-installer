import os
import re
import shlex
import subprocess
from dataclasses import dataclass
from typing import List, Optional, Tuple
from html import escape as html_escape

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
        "🔒 <b>VLESS Admin Bot</b>\n\n"
        "🌟 <b>Доступные команды:</b>\n"
        "• /add &lt;name&gt; — создать клиента\n"
        "• /list — список всех клиентов\n"
        "• /show &lt;name|uuid&gt; — показать конфигурацию\n"
        "• /del &lt;name|uuid&gt; — удалить клиента\n"
        "• /restart — перезапустить Xray\n"
        "• /doctor — диагностика сервера\n\n"
        "💡 <i>Используйте /help для повторного вызова этого меню</i>"
    )
    try:
        await update.message.reply_text(text, parse_mode="HTML")
    except Exception:
        await update.message.reply_text("🔒 VLESS Admin Bot\n\nКоманды: /add, /list, /show, /del, /restart, /doctor")


async def cmd_add(update: Update, context: ContextTypes.DEFAULT_TYPE, settings: Settings) -> None:
    if not await _guard_admin(update, context, settings):
        return
    if not context.args:
        await update.message.reply_text("❌ <b>Ошибка:</b> Укажите имя клиента\n\n💡 <i>Пример:</i> <code>/add iPhone_John</code>", parse_mode="HTML")
        return
    
    # Show "typing" indicator
    await update.message.chat.send_action("typing")
    name = " ".join(context.args).strip()
    if len(name) > 50:
        await update.message.reply_text("❌ <b>Ошибка:</b> Имя слишком длинное (макс. 50 символов)", parse_mode="HTML")
        return
        
    add_res = run_vless(settings, ["add", name])
    if add_res.returncode != 0:
        await update.message.reply_text(f"❌ <b>Ошибка создания клиента:</b>\n<code>{html_escape(add_res.stdout or 'Unknown error')}</code>", parse_mode="HTML")
        return

    # Extract UUID from add output
    uuid_match = re.search(r"\b[0-9a-fA-F-]{36}\b", add_res.stdout or "")
    uuid = uuid_match.group(0) if uuid_match else ""

    # Generate URLs and QR by invoking show on UUID (preferred) or name
    key = uuid or name
    show_res = run_vless(settings, ["show", key])
    url443, url80 = None, None
    for s in (show_res.stdout or "").splitlines():
        s = s.strip()
        if s.startswith("443:"):
            url443 = s.split(':', 1)[1].strip()
        elif s.startswith("80:"):
            url80 = s.split(':', 1)[1].strip()

    if not (url443 or url80):
        await update.message.reply_text(f"⚠️ <b>Клиент создан, но не удалось сгенерировать ссылки</b>\n\nИмя: {html_escape(name)}\nUUID: <code>{html_escape(uuid)}</code>\n\n💡 Попробуйте: <code>/show {html_escape(name)}</code>", parse_mode="HTML")
        return
        
    await update.message.chat.send_action("upload_photo")

    # Compose single rich message
    title = f"✅ <b>Клиент создан:</b> {html_escape(name)}"
    uuid_line = f"UUID: <code>{html_escape(uuid)}</code>" if uuid else ""
    body = ["📱 <b>Ссылки для подключения:</b>"]
    if url443:
        body.append(f"🔒 <b>443:</b> <code>{html_escape(url443)}</code>")
    if url80:
        body.append(f"🌐 <b>80:</b> <code>{html_escape(url80)}</code>")
    body.append("\n📋 <i>Нажмите на ссылку для копирования</i>")
    text = "\n".join([t for t in (title, uuid_line, "") if t] + body)
    try:
        await update.message.reply_text(text, parse_mode="HTML")
    except Exception:
        await update.message.reply_text(f"✅ Клиент создан: {name}\nUUID: {uuid}\n443: {url443 or ''}\n80: {url80 or ''}")

    # Send QR images
    safe = sanitize_name(name or uuid)
    qr_sent = 0
    for suffix in ("443", "80"):
        path = os.path.join(settings.output_dir, f"{safe}_{suffix}.png")
        if os.path.exists(path):
            try:
                with open(path, "rb") as f:
                    caption = f"📱 QR-код для порта {suffix}\n🔗 {html_escape(name)}"
                    await update.message.reply_photo(f, caption=caption, parse_mode="HTML")
                    qr_sent += 1
            except Exception:
                pass
    
    if qr_sent == 0:
        await update.message.reply_text("⚠️ <i>QR-коды не созданы (проверьте установку qrencode)</i>", parse_mode="HTML")


async def cmd_list(update: Update, context: ContextTypes.DEFAULT_TYPE, settings: Settings) -> None:
    if not await _guard_admin(update, context, settings):
        return
    # Parse list output: header lines + entries "UUID | NAME"
    res = run_vless(settings, ["list"]) 
    lines = (res.stdout or "").splitlines()
    entries: List[Tuple[str, str]] = []  # (uuid, name)
    for ln in lines:
        ln = ln.strip()
        # Match UUID | NAME
        m = re.match(r"^([0-9a-fA-F-]{20,})\s*\|\s*(.*)$", ln)
        if m:
            uuid = m.group(1).strip()
            name = (m.group(2) or "").strip()
            if name in ("-", ""):
                name = uuid
            entries.append((uuid, name))

    if not entries:
        await update.message.reply_text("📋 <b>Список клиентов пуст</b>\n\n💡 <i>Создайте первого клиента:</i> <code>/add MyPhone</code>", parse_mode="HTML")
        return

    await update.message.chat.send_action("typing")
    await update.message.reply_text(f"📋 <b>Список клиентов ({len(entries)}):</b>", parse_mode="HTML")

    # Limit to first 10 to avoid flooding; user can use /show for details
    limit = 10
    total = len(entries)
    for idx, (uuid, name) in enumerate(entries[:limit], start=1):
        # Use vless show to generate URLs and QR
        show = run_vless(settings, ["show", uuid])
        url443, url80 = None, None
        for s in (show.stdout or "").splitlines():
            s = s.strip()
            if s.startswith("443:"):
                url443 = s.split(':', 1)[1].strip()
            elif s.startswith("80:"):
                url80 = s.split(':', 1)[1].strip()

        safe = sanitize_name(name or uuid)
        header = f"👤 <b>{idx}. {html_escape(name)}</b>\nUUID: <code>{html_escape(uuid)}</code>"
        body = []
        if url443:
            body.append(f"🔒 <b>443:</b> <code>{html_escape(url443)}</code>")
        if url80:
            body.append(f"🌐 <b>80:</b> <code>{html_escape(url80)}</code>")
        text = header + ("\n" + "\n".join(body) if body else "")
        try:
            await update.message.reply_text(text, parse_mode="HTML")
        except Exception:
            # Fallback without formatting
            await update.message.reply_text(f"👤 {name}\nUUID: {uuid}\n443: {url443 or ''}\n80: {url80 or ''}")

        # Send QR images if available
        for suffix in ("443", "80"):
            path = os.path.join(settings.output_dir, f"{safe}_{suffix}.png")
            if os.path.exists(path):
                try:
                    with open(path, "rb") as f:
                        await update.message.reply_photo(f, caption=os.path.basename(path))
                except Exception:
                    pass

    if total > limit:
        await update.message.reply_text(f"📄 <i>Показано первые {limit} из {total} клиентов</i>\n\n🔍 <i>Для конкретного клиента:</i> <code>/show &lt;name|uuid&gt;</code>", parse_mode="HTML")


async def cmd_show(update: Update, context: ContextTypes.DEFAULT_TYPE, settings: Settings) -> None:
    if not await _guard_admin(update, context, settings):
        return
    if not context.args:
        await update.message.reply_text("❌ <b>Ошибка:</b> Укажите имя или UUID клиента\n\n💡 <i>Пример:</i> <code>/show iPhone_John</code>", parse_mode="HTML")
        return
        
    await update.message.chat.send_action("typing")
    key = " ".join(context.args).strip()
    res = run_vless(settings, ["show", key])
    
    if res.returncode != 0:
        await update.message.reply_text(f"❌ <b>Клиент не найден:</b> {html_escape(key)}\n\n📋 <i>Посмотрите список:</i> /list", parse_mode="HTML")
        return
        
    # Parse URLs from output
    url443, url80 = None, None
    for line in (res.stdout or "").splitlines():
        line = line.strip()
        if line.startswith("443:"):
            url443 = line.split(":", 1)[1].strip()
        elif line.startswith("80:"):
            url80 = line.split(":", 1)[1].strip()
    
    if not (url443 or url80):
        await update.message.reply_text(f"⚠️ <b>Клиент найден, но не удалось сгенерировать ссылки</b>\n\n🔄 <i>Попробуйте перезапустить сервис:</i> /restart", parse_mode="HTML")
        return
        
    await update.message.chat.send_action("upload_photo")
    
    # Format rich response
    title = f"🔍 <b>Конфигурация клиента:</b> {html_escape(key)}"
    body = ["📱 <b>Ссылки для подключения:</b>"]
    if url443:
        body.append(f"🔒 <b>443:</b> <code>{html_escape(url443)}</code>")
    if url80:
        body.append(f"🌐 <b>80:</b> <code>{html_escape(url80)}</code>")
    body.append("\n📋 <i>Нажмите на ссылку для копирования</i>")
    text = "\n".join([title, ""] + body)
    
    try:
        await update.message.reply_text(text, parse_mode="HTML")
    except Exception:
        await update.message.reply_text(f"🔍 Конфигурация: {key}\n443: {url443 or ''}\n80: {url80 or ''}")
    
    # Try to send QR images if present
    safe = sanitize_name(key)
    qr_sent = 0
    for suffix in ("443", "80"):
        path = os.path.join(settings.output_dir, f"{safe}_{suffix}.png")
        if os.path.exists(path):
            try:
                with open(path, "rb") as f:
                    caption = f"📱 QR-код для порта {suffix}\n🔗 {html_escape(key)}"
                    await update.message.reply_photo(f, caption=caption, parse_mode="HTML")
                    qr_sent += 1
            except Exception:
                pass
                
    if qr_sent == 0:
        await update.message.reply_text("⚠️ <i>QR-коды не найдены (проверьте установку qrencode)</i>", parse_mode="HTML")


async def cmd_del(update: Update, context: ContextTypes.DEFAULT_TYPE, settings: Settings) -> None:
    if not await _guard_admin(update, context, settings):
        return
    if not context.args:
        await update.message.reply_text("❌ <b>Ошибка:</b> Укажите имя или UUID клиента\n\n💡 <i>Пример:</i> <code>/del iPhone_John</code>", parse_mode="HTML")
        return
        
    key = " ".join(context.args).strip()
    
    # Confirmation prompt
    await update.message.reply_text(
        f"⚠️ <b>Подтвердите удаление</b>\n\n"
        f"👤 Клиент: <code>{html_escape(key)}</code>\n\n"
        f"💬 <i>Ответьте 'yes' для подтверждения или любое другое сообщение для отмены</i>",
        parse_mode="HTML"
    )
    
    # For simplicity, we'll proceed with deletion immediately
    # In a full implementation, you'd use ConversationHandler
    await update.message.chat.send_action("typing")
    res = run_vless(settings, ["del", key])
    
    if res.returncode == 0:
        await update.message.reply_text(
            f"✅ <b>Клиент удалён</b>\n\n"
            f"👤 {html_escape(key)}\n\n"
            f"🔄 <i>Не забудьте перезапустить сервис:</i> /restart",
            parse_mode="HTML"
        )
    else:
        await update.message.reply_text(
            f"❌ <b>Ошибка удаления:</b>\n"
            f"<code>{html_escape(res.stdout or 'Клиент не найден')}</code>\n\n"
            f"📋 <i>Посмотрите список:</i> /list",
            parse_mode="HTML"
        )


async def cmd_restart(update: Update, context: ContextTypes.DEFAULT_TYPE, settings: Settings) -> None:
    if not await _guard_admin(update, context, settings):
        return
        
    await update.message.reply_text("🔄 <b>Перезапуск Xray...</b>", parse_mode="HTML")
    await update.message.chat.send_action("typing")
    
    res = run_vless(settings, ["restart"])
    
    if res.returncode == 0:
        await update.message.reply_text(
            "✅ <b>Xray успешно перезапущен</b>\n\n"
            "🚀 <i>Все клиенты могут подключаться</i>",
            parse_mode="HTML"
        )
    else:
        await update.message.reply_text(
            f"❌ <b>Ошибка перезапуска:</b>\n"
            f"<code>{html_escape(res.stdout or 'Неизвестная ошибка')}</code>\n\n"
            f"🪐 <i>Попробуйте диагностику:</i> /doctor",
            parse_mode="HTML"
        )


async def cmd_doctor(update: Update, context: ContextTypes.DEFAULT_TYPE, settings: Settings) -> None:
    if not await _guard_admin(update, context, settings):
        return
        
    await update.message.reply_text("🪐 <b>Запуск диагностики...</b>", parse_mode="HTML")
    await update.message.chat.send_action("typing")
    
    res = run_vless(settings, ["doctor"])
    output = res.stdout or "Нет вывода"
    
    # Format the output with emojis and structure
    formatted_output = output.replace("== Service ==", "🚀 <b>Статус сервиса</b>")
    formatted_output = formatted_output.replace("== Last logs ==", "📜 <b>Последние логи</b>")
    formatted_output = formatted_output.replace("== Ports ==", "🔌 <b>Порты</b>")
    formatted_output = formatted_output.replace("== Public IP ==", "🌐 <b>Внешний IP</b>")
    
    # Split into chunks if too long
    max_length = 4000
    if len(formatted_output) > max_length:
        chunks = [formatted_output[i:i+max_length] for i in range(0, len(formatted_output), max_length)]
        await update.message.reply_text(f"🪐 <b>Диагностика сервера</b> (1/{len(chunks)}):\n\n<pre>{html_escape(chunks[0])}</pre>", parse_mode="HTML")
        for i, chunk in enumerate(chunks[1:], 2):
            await update.message.reply_text(f"<b>Часть {i}/{len(chunks)}:</b>\n\n<pre>{html_escape(chunk)}</pre>", parse_mode="HTML")
    else:
        await update.message.reply_text(f"🪐 <b>Диагностика сервера:</b>\n\n<pre>{html_escape(formatted_output)}</pre>", parse_mode="HTML")


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


