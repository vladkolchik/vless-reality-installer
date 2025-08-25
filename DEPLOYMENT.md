# 📤 Инструкции по развертыванию на GitHub

## 🚀 Как опубликовать скрипт на GitHub

### 1. Создайте новый репозиторий

1. Зайдите на [GitHub.com](https://github.com)
2. Нажмите кнопку **"New repository"**
3. Назовите репозиторий, например: `vless-reality-installer`
4. Сделайте репозиторий **публичным** (для доступа к raw файлам)
5. Отметьте **"Add a README file"**
6. Нажмите **"Create repository"**

### 2. Загрузите файлы

Можете использовать веб-интерфейс GitHub или Git командную строку:

#### Через веб-интерфейс:
1. Нажмите **"Add file" → "Upload files"**
2. Перетащите файлы:
   - `install_vless_reality.sh` (основной инсталлятор VPN)
   - `install_vless_bot.sh` (инсталлятор Telegram-бота)
   - `README.md` (главная документация)
   - Папку `bot/` со всеми файлами бота
   - Папку `Instruction/` с HTML-гидами и документацией
3. Напишите commit message: "Initial release"
4. Нажмите **"Commit changes"**

#### Через Git:
```bash
git clone https://github.com/yourusername/vless-reality-installer.git
cd vless-reality-installer
cp /path/to/your/files/* .
git add .
git commit -m "Initial release"
git push origin main
```

### 3. Получите ссылку на raw файл

После загрузки файла `install_vless_reality.sh`:

1. Откройте файл в GitHub
2. Нажмите кнопку **"Raw"**
3. Скопируйте URL из адресной строки

Ссылка будет вида:
```
https://raw.githubusercontent.com/yourusername/reponame/main/install_vless_reality.sh
```

### 4. Обновите ссылки в документации

Замените `yourusername` на ваш GitHub username во всех файлах:

- `README.md`
- `server_security_guide.html`
- Команде для установки

### 5. Проверьте работу

Протестируйте команды установки:

**VPN:**
```bash
bash <(curl -s https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/refs/heads/main/install_vless_reality.sh)
```

**Telegram-бот:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/refs/heads/main/install_vless_bot.sh)
```

## 🔧 Настройка автообновлений

### GitHub Actions для автотестирования

Создайте файл `.github/workflows/test.yml`:

```yaml
name: Test Installation Script

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  test:
    runs-on: ubuntu-latest
    
    steps:
    - uses: actions/checkout@v3
    
    - name: Test script syntax
      run: |
        bash -n install_vless_reality.sh
        bash -n install_vless_bot.sh
        
    - name: Check script permissions
      run: |
        test -x install_vless_reality.sh || chmod +x install_vless_reality.sh
        test -x install_vless_bot.sh || chmod +x install_vless_bot.sh
        
    - name: Test bot Python syntax
      run: |
        python3 -m py_compile bot/telegram_bot.py
```

### Создание релизов

1. Перейдите в **"Releases"** → **"Create a new release"**
2. Создайте тег версии: `v1.0.0`
3. Заполните описание релиза:

```markdown
## ⚡ Быстрая установка

**VPN сервер:**
```bash
bash <(curl -s https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/refs/heads/main/install_vless_reality.sh)
```

**Telegram-бот (опционально):**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vladkolchik/vless-reality-installer/refs/heads/main/install_vless_bot.sh)
```

## 🆕 Новое в этой версии
- ✅ Автоматическая установка CLI `vless` для управления
- 🤖 Telegram-бот с admin-only доступом
- 🔧 Команда `/fix` для решения проблем с правами доступа
- 📱 Улучшенный UX: QR-коды, копируемые ссылки
- 🔄 Автообновление бота одной командой
```

4. Прикрепите файлы при необходимости
5. Опубликуйте релиз

## 📊 Мониторинг использования

### GitHub Analytics

- Проверяйте статистику в разделе **"Insights"**
- Смотрите количество клонов и просмотров
- Анализируйте географию пользователей

### Логирование использования (опционально)

Можете добавить в скрипт анонимную телеметрию:

```bash
# В начало скрипта
SCRIPT_VERSION="1.0.0"
USER_AGENT="VlessInstaller/$SCRIPT_VERSION"

# Отправка анонимной статистики (опционально)
if [[ -z "$NO_ANALYTICS" ]]; then
    curl -s -A "$USER_AGENT" "https://api.github.com/repos/yourusername/reponame" >/dev/null 2>&1 || true
fi
```

## 🛡️ Безопасность

### Проверка целостности

Добавьте контрольные суммы для критичных файлов:

```bash
# Создание чексуммы
sha256sum install_vless_reality.sh > install_vless_reality.sh.sha256

# Проверка в скрипте
EXPECTED_HASH="ваш_хеш_здесь"
ACTUAL_HASH=$(sha256sum "$0" | cut -d' ' -f1)
if [[ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]]; then
    echo "ВНИМАНИЕ: Файл скрипта мог быть изменен!"
fi
```

### Подпись коммитов

Настройте GPG подпись для коммитов:

```bash
git config --global user.signingkey YOUR_GPG_KEY_ID
git config --global commit.gpgsign true
```

## 📈 Продвижение

### Создание документации

1. Включите GitHub Pages в настройках репозитория
2. Создайте красивую главную страницу
3. Добавьте скриншоты и видеоинструкции

### README badges

Добавьте бейджи в README.md:

```markdown
![GitHub release](https://img.shields.io/github/v/release/yourusername/reponame)
![GitHub downloads](https://img.shields.io/github/downloads/yourusername/reponame/total)
![GitHub stars](https://img.shields.io/github/stars/yourusername/reponame)
![License](https://img.shields.io/github/license/yourusername/reponame)
```

### Социальные сети

- Поделитесь в Telegram каналах
- Создайте пост на Habr
- Добавьте в awesome-списки на GitHub

## 🔄 Обновления

### Версионирование

Используйте семантическое версионирование:
- `1.0.0` - первый релиз
- `1.0.1` - исправления багов
- `1.1.0` - новые функции
- `2.0.0` - breaking changes

### Автоматические обновления

Добавьте в скрипт проверку версий:

```bash
check_updates() {
    LATEST_VERSION=$(curl -s https://api.github.com/repos/yourusername/reponame/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')
    if [[ "$SCRIPT_VERSION" != "$LATEST_VERSION" ]]; then
        echo "Доступна новая версия: $LATEST_VERSION"
        echo "Текущая версия: $SCRIPT_VERSION"
        echo "Обновите скрипт: curl -O https://raw.githubusercontent.com/yourusername/reponame/main/install_vless_reality.sh"
    fi
}
```

## 📞 Поддержка пользователей

### Issues шаблоны

Создайте `.github/ISSUE_TEMPLATE/bug_report.md`:

```markdown
---
name: Bug report
about: Сообщить об ошибке
title: '[BUG] '
labels: bug
assignees: ''
---

**Описание ошибки**
Краткое описание проблемы.

**Воспроизведение**
1. Выполните '...'
2. Нажмите на '....'
3. Прокрутите до '....'
4. Появляется ошибка

**Ожидаемое поведение**
Что должно было произойти.

**Скриншоты**
Если применимо, добавьте скриншоты.

**Окружение:**
 - ОС: [e.g. Ubuntu 20.04]
 - Версия скрипта: [e.g. 1.0.0]

**Дополнительная информация**
Любая другая полезная информация.
```

### FAQ

Создайте FAQ.md с частыми вопросами и ответами.

---

🎯 **Следуя этой инструкции, вы сможете профессионально развернуть и поддерживать VPN установщик на GitHub!**

