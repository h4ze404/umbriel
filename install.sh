#!/usr/bin/env bash
# ==============================================================================
# umbriel-cachyos-setup
# Автоустановка десктопа на чистый CachyOS (без DE):
#   Umbriel (композитор) + Noctalia Shell + noctalia-greeter (экран входа)
#
# 1. Ставит пакеты из официальных репозиториев (pacman)
# 2. Ставит AUR-помощник yay (запасной — paru)
# 3. Ставит из AUR: umbriel-git, xdg-desktop-portal-umbriel-git,
#    noctalia-greeter-git (вход через greetd), google-chrome-stable
# 4. Ставит Throne (прокси-клиент) официальным инсталлером проекта
# 5. Кладёт config.toml в ~/.config/umbriel/ (старый бэкапит)
# 6. Проверяет конфиг: umbriel config validate
# 7. Настраивает greetd + noctalia-greeter и включает его в systemd
#
# Запуск из папки umbriel-config, НЕ под root (sudo спросится сам):
#   ./install.sh
# Флаги:
#   SKIP_GREETER=1 ./install.sh   — без greetd (вход из TTY: start-umbriel)
#   SKIP_AUR=1 ./install.sh       — пропустить установку AUR-пакетов
#   SKIP_THRONE=1 ./install.sh    — пропустить установку Throne
#
# Мониторы заданы в config.toml: HDMI-A-1 1920x1080@100 (левый) и
# HDMI-A-2 1920x1080@75 (правый). Раскладка: us,ru, переключение Alt+Shift
# (или Mod+Space в сессии). Аппаратный курсор отключён в [input.cursor].
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SRC="${SCRIPT_DIR}/config.toml"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
info() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
die()  { printf '  \033[31mОШИБКА: %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -ne 0 ]] || die "Запусти от обычного пользователя, а не от root (sudo спросится само)."
[[ -f "${CONFIG_SRC}" ]] || die "config.toml не найден рядом со скриптом (${SCRIPT_DIR})."
command -v pacman >/dev/null 2>&1 || die "pacman не найден — нужен CachyOS/Arch."
command -v sudo   >/dev/null 2>&1 || die "sudo не найден."

# ─────────────────────── 1. Пакеты из репозиториев ───────────────────────
info "Шаг 1/7: пакеты из репозиториев (pacman)"
REPO_PKGS=(
    git base-devel          # база для сборки AUR
    curl python             # скачивание и запуск инсталлера Throne
    noctalia                # оболочка Noctalia (официальный пакет в [extra])
    polkit-kde-agent        # polkit-агент для запросов (пароли от sudo и т.п.)
    greetd                  # менеджер входа
    alacritty nautilus      # приложения из биндов (браузер и Umbriel — из AUR, см. ниже)
    xdg-desktop-portal xdg-desktop-portal-gtk xdg-user-dirs
)
for pkg in "${REPO_PKGS[@]}"; do
    if pacman -Qi "$pkg" >/dev/null 2>&1; then
        ok "$pkg — уже установлен"
    elif sudo pacman -S --needed --noconfirm "$pkg"; then
        ok "$pkg — установлен"
    else
        warn "не удалось поставить '$pkg' — проверь имя пакета для своего репозитория"
    fi
done

# ─────────────────────── 2. AUR-помощник (yay, запасной — paru) ───────────────────────
info "Шаг 2/7: AUR-помощник"
AUR_HELPER=""
for h in yay paru; do
    if command -v "$h" >/dev/null 2>&1; then AUR_HELPER="$h"; break; fi
done

if [[ -z "${AUR_HELPER}" ]]; then
    if sudo pacman -S --needed --noconfirm yay 2>/dev/null && command -v yay >/dev/null 2>&1; then
        AUR_HELPER="yay"
        ok "yay установлен из репозитория"
    else
        info "yay нет, собираю yay из AUR (нужен компилятор go — поставится сам)"
        tmp="$(mktemp -d)"
        git clone https://aur.archlinux.org/yay.git "${tmp}/yay"
        ( cd "${tmp}/yay" && makepkg -si --noconfirm --needed )
        rm -rf "${tmp}"
        if command -v yay >/dev/null 2>&1; then
            AUR_HELPER="yay"
            ok "yay собран и установлен"
        else
            info "yay не собрался, пробую paru"
            sudo pacman -S --needed --noconfirm paru 2>/dev/null || true
            if command -v paru >/dev/null 2>&1; then
                AUR_HELPER="paru"
                ok "paru установлен как запасной помощник"
            else
                tmp="$(mktemp -d)"
                git clone https://aur.archlinux.org/paru.git "${tmp}/paru"
                ( cd "${tmp}/paru" && makepkg -si --noconfirm --needed )
                rm -rf "${tmp}"
                command -v paru >/dev/null 2>&1 || die "Не удалось поставить ни yay, ни paru"
                AUR_HELPER="paru"
                ok "paru собран как запасной помощник"
            fi
        fi
    fi
else
    ok "найден AUR-помощник: ${AUR_HELPER}"
fi

# ─────────────────────── 3. Пакеты из AUR ───────────────────────
info "Шаг 3/7: пакеты из AUR"
if [[ "${SKIP_AUR:-0}" == "1" ]]; then
    warn "SKIP_AUR=1 — установка из AUR пропущена"
else
    AUR_PKGS=(
        umbriel-git                     # композитор (мейнтейнер: noctalia-dev)
        xdg-desktop-portal-umbriel-git  # портал Umbriel: скриншоты/шеринг экрана
        noctalia-greeter-git            # экран входа greetd в стиле Noctalia
        google-chrome-stable            # браузер (Mod+B)
    )
    for pkg in "${AUR_PKGS[@]}"; do
        if pacman -Qi "$pkg" >/dev/null 2>&1; then
            ok "$pkg — уже установлен"
        elif "${AUR_HELPER}" -S --needed --noconfirm "$pkg"; then
            ok "$pkg — установлен"
        else
            die "Не удалось поставить '$pkg' из AUR"
        fi
    done
fi

# ─────────────────────── 4. Throne (прокси-клиент) ───────────────────────
info "Шаг 4/7: Throne"
THRONE_URL="https://raw.githubusercontent.com/throneproj/Throne/dev/script/install_linux.py"
if [[ "${SKIP_THRONE:-0}" == "1" ]]; then
    warn "SKIP_THRONE=1 — установка Throne пропущена"
else
    printf '  Откроется интерактивный TUI-установщик: ↑/↓ (или j/k) выбрать, Enter подтвердить.\n'
    printf '  Эти шаги: «Install» → «Stable» → ждём загрузку → финальный «Press any key to exit».\n'
    if curl -fsSL "${THRONE_URL}" | sudo python3; then
        ok "Throne установлен (официальный инсталлер throneproj)"
    else
        warn "инсталлер Throne упал (сеть/прервано в TUI). Сессия не пострадает;"
        printf '     запусти позже вручную:\n       curl -fsSL %s | sudo python3\n' "${THRONE_URL}"
    fi
fi

# ─────────────────────── 5. Конфиг Umbriel ───────────────────────
info "Шаг 5/7: конфиг Umbriel"
CONF_DIR="${HOME}/.config/umbriel"
mkdir -p "${CONF_DIR}"
if [[ -f "${CONF_DIR}/config.toml" ]]; then
    stamp="$(date +%Y%m%d-%H%M%S)"
    cp "${CONF_DIR}/config.toml" "${CONF_DIR}/config.toml.bak-${stamp}"
    ok "старый конфиг сохранён как config.toml.bak-${stamp}"
fi
install -Dm644 "${CONFIG_SRC}" "${CONF_DIR}/config.toml"
ok "конфиг записан: ${CONF_DIR}/config.toml"

# ─────────────────────── 6. Валидация конфига ───────────────────────
info "Шаг 6/7: проверка конфига"
if command -v umbriel >/dev/null 2>&1; then
    if umbriel config validate; then
        ok "umbriel config validate — ошибок нет"
    else
        die "umbriel config validate нашёл проблемы (диагностика выше: файл/строка/колонка)"
    fi
else
    warn "umbriel не найден в PATH — проверка пропущена (поставится после перезапуска shell)"
fi

# ─────────────────────── 7. Экран входа: greetd + noctalia-greeter ───────────────────────
info "Шаг 7/7: экран входа"
if [[ "${SKIP_GREETER:-0}" == "1" ]]; then
    warn "SKIP_GREETER=1 — greetd не настроен"
    printf '  Вход в сессию вручную из TTY:  %s\n' "$(bold start-umbriel)"
else
    if pacman -Qi noctalia-greeter-git >/dev/null 2>&1 || pacman -Qi noctalia-greeter >/dev/null 2>&1; then
        GREETER_CMD="noctalia-greeter"
    else
        warn "noctalia-greeter не установлен, ставлю tuigreet как запасной вариант"
        "${AUR_HELPER}" -S --needed --noconfirm greetd-tuigreet || die "Не удалось поставить greetd-tuigreet"
        GREETER_CMD="tuigreet --cmd start-umbriel"
    fi

    GREETD_CFG="/etc/greetd/config.toml"
    if [[ -f "${GREETD_CFG}" ]]; then
        sudo cp "${GREETD_CFG}" "${GREETD_CFG}.bak-$(date +%Y%m%d-%H%M%S)"
        ok "старый конфиг greetd сохранён"
    fi
    sudo tee "${GREETD_CFG}" >/dev/null <<EOF
[terminal]
vt = 1

[default_session]
command = "${GREETER_CMD}"
user = "greeter"
EOF
    ok "конфиг greetd записан: ${GREETD_CFG} (command = ${GREETER_CMD})"

    if sudo systemctl enable greetd 2>/dev/null; then
        ok "greetd включён (systemctl enable greetd)"
    else
        warn "не удалось включить greetd. Если стоит другой ДМ (sddm/gdm/...) — отключи его:"
        printf '     sudo systemctl disable --now <дм>  &&  sudo systemctl enable greetd\n'
    fi
fi

bold "Готово. После перезагрузки выбери Umbriel на экране входа; либо из TTY: start-umbriel"
printf 'Подсказки:\n'
printf '  umbriel outputs                            — имена/режимы мониторов\n'
printf '  umbriel config validate                    — проверка конфига\n'
printf '  umbriel config schema                      — все ключи вашей версии\n'
printf '  ALT+SHIFT (или Mod+Space)                  — переключение us<->ru\n'
