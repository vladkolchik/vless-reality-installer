import os
import re
import shlex
import subprocess
from dataclasses import dataclass
from typing import List, Optional, Tuple
from html import escape as html_escape

from dotenv import load_dotenv
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, ContextTypes


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
        "• /del &lt;name|uuid&gt; — удалить клиента (с подтверждением)\n"
        "• /restart — перезапустить Xray\n"
        "• /fix — исправить права и перезапустить\n"
        "• /block_torrents — заблокировать торренты\n"
        "• /unblock_torrents — разблокировать торренты\n"
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
    
    # Check if client with this name already exists
    list_res = run_vless(settings, ["list"])
    if list_res.returncode == 0:
        lines = (list_res.stdout or "").splitlines()
        for ln in lines:
            ln = ln.strip()
            # Skip header and separator lines
            if ln.startswith("UUID") or ln.startswith("-"):
                continue
            # Match UUID | NAME
            m = re.match(r"^([0-9a-fA-F-]{36})\s*\|\s*(.*)$", ln)
            if m:
                existing_name = (m.group(2) or "").strip()
                if existing_name == name:
                    await update.message.reply_text(
                        f"❌ <b>Клиент с именем '{html_escape(name)}' уже существует</b>\n\n"
                        f"💡 <b>Попробуйте:</b>\n"
                        f"• Другое имя: <code>/add {html_escape(name)}_new</code>\n"
                        f"• Удалить старый: <code>/del {html_escape(name)}</code>\n"
                        f"• Посмотреть список: <code>/list</code>",
                        parse_mode="HTML"
                    )
                    return
        
    add_res = run_vless(settings, ["add", name])
    if add_res.returncode != 0:
        error_output = add_res.stdout or 'Unknown error'
        
        # Check if it's a duplicate name error
        if "already exists" in error_output:
            await update.message.reply_text(
                f"❌ <b>Клиент с именем '{html_escape(name)}' уже существует</b>\n\n"
                f"💡 <b>Попробуйте:</b>\n"
                f"• Другое имя: <code>/add {html_escape(name)}_new</code>\n"
                f"• Удалить старый: <code>/del {html_escape(name)}</code>\n"
                f"• Посмотреть список: <code>/list</code>",
                parse_mode="HTML"
            )
        else:
            await update.message.reply_text(f"❌ <b>Ошибка создания клиента:</b>\n<code>{html_escape(error_output)}</code>", parse_mode="HTML")
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
    
    # Add restart reminder after client creation
    await update.message.reply_text(
        "🔄 <b>Не забудьте перезапустить сервис:</b> /restart",
        parse_mode="HTML"
    )


async def cmd_list(update: Update, context: ContextTypes.DEFAULT_TYPE, settings: Settings) -> None:
    if not await _guard_admin(update, context, settings):
        return
    # Parse list output: header lines + entries "UUID | NAME"
    res = run_vless(settings, ["list"]) 
    lines = (res.stdout or "").splitlines()
    entries: List[Tuple[str, str]] = []  # (uuid, name)
    for ln in lines:
        ln = ln.strip()
        # Skip header and separator lines
        if ln.startswith("UUID") or ln.startswith("-"):
            continue
        # Match UUID | NAME (UUID must contain alphanumeric chars, not just dashes)
        m = re.match(r"^([0-9a-fA-F-]{36})\s*\|\s*(.*)$", ln)
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

    # Limit to first 5 to avoid flooding; user can use /show for details
    limit = 5
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

        # Format like /show command but more compact
        title = f"👤 <b>Клиент {idx}: {html_escape(name)}</b>"
        uuid_line = f"UUID: <code>{html_escape(uuid)}</code>"
        body = ["📱 <b>Ссылки для подключения:</b>"]
        if url443:
            body.append(f"🔒 <b>443:</b> <code>{html_escape(url443)}</code>")
        if url80:
            body.append(f"🌐 <b>80:</b> <code>{html_escape(url80)}</code>")
        body.append("\n📋 <i>Нажмите на ссылку для копирования</i>")
        text = "\n".join([title, uuid_line, ""] + body)
        
        try:
            await update.message.reply_text(text, parse_mode="HTML")
        except Exception:
            # Fallback without formatting
            await update.message.reply_text(f"👤 Клиент {idx}: {name}\nUUID: {uuid}\n443: {url443 or ''}\n80: {url80 or ''}")

        # Send QR images if available
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
            await update.message.reply_text(f"⚠️ <i>QR-коды для {html_escape(name)} не найдены</i>", parse_mode="HTML")

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
    
    # Create inline keyboard for confirmation
    keyboard = [
        [
            InlineKeyboardButton("🗑️ Удалить", callback_data=f"delete_confirm:{key}"),
            InlineKeyboardButton("❌ Отмена", callback_data="delete_cancel")
        ]
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    # Confirmation prompt with buttons
    await update.message.reply_text(
        f"⚠️ <b>Подтвердите удаление</b>\n\n"
        f"👤 Клиент: <code>{html_escape(key)}</code>\n\n"
        f"⚡ <i>Нажмите кнопку для подтверждения или отмены</i>",
        parse_mode="HTML",
        reply_markup=reply_markup
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


async def cmd_fix(update: Update, context: ContextTypes.DEFAULT_TYPE, settings: Settings) -> None:
    if not await _guard_admin(update, context, settings):
        return
        
    await update.message.reply_text("🔧 <b>Исправление прав доступа и перезапуск...</b>", parse_mode="HTML")
    await update.message.chat.send_action("typing")
    
    res = run_vless(settings, ["fix"])
    
    if res.returncode == 0:
        await update.message.reply_text(
            "✅ <b>Исправление завершено успешно</b>\n\n"
            "🔧 Права доступа исправлены\n"
            "🔄 Xray перезапущен\n\n"
            "🚀 <i>Сервис должен работать нормально</i>",
            parse_mode="HTML"
        )
    else:
        output = res.stdout or "Неизвестная ошибка"
        await update.message.reply_text(
            f"❌ <b>Ошибка при исправлении:</b>\n"
            f"<pre>{html_escape(output[:3000])}</pre>\n\n"
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
    formatted_output = output.replace("== Service Status ==", "🚀 <b>Статус сервиса</b>")
    formatted_output = formatted_output.replace("== Service List ==", "📋 <b>Список служб</b>")
    formatted_output = formatted_output.replace("== Last logs ==", "📜 <b>Последние логи</b>")
    formatted_output = formatted_output.replace("== Configuration ==", "⚙️ <b>Конфигурация</b>")
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


async def cmd_block_torrents(update: Update, context: ContextTypes.DEFAULT_TYPE, settings: Settings) -> None:
    if not await _guard_admin(update, context, settings):
        return
        
    await update.message.reply_text("🚫 <b>Блокировка торрент-трафика...</b>", parse_mode="HTML")
    await update.message.chat.send_action("typing")

    res = run_vless(settings, ["block-torrents"])
    if res.returncode == 0:
        await update.message.reply_text(
            "✅ <b>Торренты заблокированы!</b>\n\n"
            "🚫 <b>Заблокировано:</b>\n"
            "• BitTorrent протокол\n"
            "• Порты 6881-6889, 51413\n"
            "• UDP порты 1337, 6969, 8080, 2710\n"
            "• Домены: tracker, torrent, популярные торрент-сайты\n\n"
            "💡 <i>Для отмены используйте /unblock_torrents</i>", 
            parse_mode="HTML"
        )
    else:
        error_msg = res.stdout or "Неизвестная ошибка"
        await update.message.reply_text(
            f"❌ <b>Ошибка блокировки торрентов:</b>\n<pre>{html_escape(error_msg)}</pre>\n\n"
            "💡 <i>Попробуйте /doctor для диагностики</i>", 
            parse_mode="HTML"
        )


async def cmd_unblock_torrents(update: Update, context: ContextTypes.DEFAULT_TYPE, settings: Settings) -> None:
    if not await _guard_admin(update, context, settings):
        return
        
    await update.message.reply_text("🌐 <b>Разблокировка торрент-трафика...</b>", parse_mode="HTML")
    await update.message.chat.send_action("typing")

    res = run_vless(settings, ["unblock-torrents"])
    if res.returncode == 0:
        await update.message.reply_text(
            "✅ <b>Торренты разблокированы!</b>\n\n"
            "🌐 <b>Весь трафик теперь проходит через VPN</b>\n\n"
            "💡 <i>Для повторной блокировки используйте /block_torrents</i>", 
            parse_mode="HTML"
        )
    else:
        error_msg = res.stdout or "Неизвестная ошибка"
        await update.message.reply_text(
            f"❌ <b>Ошибка разблокировки торрентов:</b>\n<pre>{html_escape(error_msg)}</pre>\n\n"
            "💡 <i>Попробуйте /doctor для диагностики</i>", 
            parse_mode="HTML"
        )


async def handle_delete_callback(update: Update, context: ContextTypes.DEFAULT_TYPE, settings: Settings) -> None:
    query = update.callback_query
    if not query or not query.data:
        return
        
    # Check admin permissions
    uid = update.effective_user.id if update.effective_user else None
    if not is_admin(uid, settings):
        await query.answer("❌ Доступ запрещен", show_alert=True)
        return
    
    await query.answer()  # Acknowledge the callback
    
    if query.data == "delete_cancel":
        # User cancelled deletion
        await query.edit_message_text(
            "❌ <b>Удаление отменено</b>\n\n"
            "👤 Клиент не был удален",
            parse_mode="HTML"
        )
        return
    
    if query.data.startswith("delete_confirm:"):
        # User confirmed deletion
        key = query.data.split(":", 1)[1]
        
        # Show processing message
        await query.edit_message_text(
            f"🔄 <b>Удаление клиента...</b>\n\n"
            f"👤 {html_escape(key)}",
            parse_mode="HTML"
        )
        
        # Perform actual deletion
        res = run_vless(settings, ["del", key])
        
        if res.returncode == 0:
            await query.edit_message_text(
                f"✅ <b>Клиент удалён</b>\n\n"
                f"👤 {html_escape(key)}\n\n"
                f"🔄 <i>Не забудьте перезапустить сервис:</i> /restart",
                parse_mode="HTML"
            )
        else:
            await query.edit_message_text(
                f"❌ <b>Ошибка удаления:</b>\n"
                f"<code>{html_escape(res.stdout or 'Клиент не найден')}</code>\n\n"
                f"📋 <i>Посмотрите список:</i> /list",
                parse_mode="HTML"
            )


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
    app.add_handler(CommandHandler("fix", lambda u, c: cmd_fix(u, c, settings)))
    app.add_handler(CommandHandler("block_torrents", lambda u, c: cmd_block_torrents(u, c, settings)))
    app.add_handler(CommandHandler("unblock_torrents", lambda u, c: cmd_unblock_torrents(u, c, settings)))
    app.add_handler(CommandHandler("doctor", lambda u, c: cmd_doctor(u, c, settings)))
    
    # Add callback query handler for delete confirmation
    app.add_handler(CallbackQueryHandler(lambda u, c: handle_delete_callback(u, c, settings)))

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


