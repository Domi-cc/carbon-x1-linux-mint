#!/usr/bin/env bash
#
# Lenovo ThinkPad X1 Carbon Gen 14 (Panther Lake) — Linux Mint Setup
# ------------------------------------------------------------------
# Bringt eine frische Mint-Cinnamon-HWE-Installation (22.x) auf einen
# Stand, der mit der neuen Hardware sauber läuft.
#
# Hintergrund (Stand Sept. 2026, Kernel 6.17):
#   - Das Samsung-OLED-Panel (ATNA40HQ09) kann PSR und Panel Replay
#     (Self-Refresh aus panel-eigenem Frame-Cache). Beides ist auf dem
#     xe-Treiber für Panther Lake noch nicht sauber:
#       * PSR          -> Session friert direkt nach dem Login ein
#                         (schwarz, Maus tot)
#       * Panel Replay -> Bildartefakte nach Idle-Phasen: Teile des
#                         alten Frames bleiben quer im Bild stehen
#                         ("PSR/Panel Replay corruption", kein Tearing)
#     xe.enable_psr=0 schaltet nur PSR ab, Panel Replay springt dann
#     stillschweigend ein. Beide müssen aus. enable_dc/enable_fbc
#     (Display-C-States / Framebuffer Compression) sind NICHT nötig —
#     einzeln gegengeprüft.
#   - Audio (Cirrus SoundWire-Codecs): der reguläre HWE-Kernel hat
#     keine ACPI-Match-Tabelle für diese Konfiguration -> nur "Dummy
#     Output". Ubuntus OEM-Kernel (linux-oem-24.04d) trägt die
#     Lenovo-Patches, damit läuft der Sound. Selbe Hauptversion 6.17.
#   - Cinnamon on Wayland: Muffin meldet xdg_output im physischen
#     Layout-Modus falsch (logisch = physisch), dadurch rendert Firefox
#     mit Scale 1 und ist unscharf. Fix: logischer Layout-Modus per
#     experimental-features. Wirkt nur in der Wayland-Session.
#     Hinweis: Electron/VS Code läuft in der Wayland-Session nicht
#     brauchbar (nativ kaputt, XWayland unscharf) -> X11 bleibt Default.
#
# Was das Skript macht:
#   1. Boot-Parameter xe.enable_psr=0 xe.enable_panel_replay=0
#   2. OEM-Kernel installieren und als GRUB-Default setzen
#   3. SOF-Audio-Firmware auf aktuellen Stand (sof-bin)
#   4. fwupd für Firmware-Updates via LVFS
#   5. power-profiles-daemon
#   6. Wayland-Session: logischer Layout-Modus (User-Setting)
#   7. Optional: XFCE als Fallback-Desktop (--with-xfce)
#
# Nicht enthalten (bewusst):
#   - kisak-mesa-PPA: Mesa 26.x hat auf PTL nichts an den Artefakten
#     geändert; für dieses Setup nicht nötig.
#   - Firefox about:config-Prefs: profilabhängig, kein Systemsetup.
#
# Anwendung:
#   chmod +x install.sh
#   ./install.sh                # Standard-Setup
#   ./install.sh --with-xfce    # zusätzlich XFCE
#   sudo reboot
#

set -euo pipefail

# --- Optionen ---------------------------------------------------------------

INSTALL_XFCE=0
for arg in "$@"; do
    case "$arg" in
        --with-xfce) INSTALL_XFCE=1 ;;
        -h|--help)  sed -n '2,50p' "$0"; exit 0 ;;
        *) echo "Unbekannte Option: $arg" >&2; exit 1 ;;
    esac
done

# --- Sanity Checks ----------------------------------------------------------

if [[ $EUID -eq 0 ]]; then
    echo "FEHLER: Bitte als normaler User mit sudo-Rechten starten, nicht als root." >&2
    exit 1
fi

if ! sudo -n true 2>/dev/null; then
    echo "Bitte sudo-Passwort eingeben:"
    sudo -v
fi

# Bei Lenovo steht der Machine-Type-Code in system-product-name
# (z.B. "21V7CTO1WW"), der Friendly-Name in system-version.
PRODUCT_NAME="$(sudo dmidecode -s system-product-name 2>/dev/null || echo unknown)"
PRODUCT_VERSION="$(sudo dmidecode -s system-version 2>/dev/null || echo unknown)"
if [[ "$PRODUCT_VERSION" != *"X1 Carbon"* && "$PRODUCT_NAME" != *"X1 Carbon"* ]]; then
    echo "Hinweis: System ist '$PRODUCT_VERSION' ($PRODUCT_NAME)"
    echo "Skript ist für ThinkPad X1 Carbon Gen 14 gedacht. Trotzdem fortfahren? [j/N]"
    read -r answer
    [[ "$answer" =~ ^[jJyY]$ ]] || exit 0
fi

echo
echo "=== ThinkPad X1 Carbon Gen 14 — Linux Mint Setup ==="
echo

# --- 1. Boot-Parameter ------------------------------------------------------

echo "[1/7] xe-Boot-Parameter setzen (PSR + Panel Replay aus)"

GRUB_FILE=/etc/default/grub
sudo cp -n "$GRUB_FILE" "${GRUB_FILE}.orig"   # einmalige Sicherung

XE_PARAMS="xe.enable_psr=0 xe.enable_panel_replay=0"
for param in $XE_PARAMS; do
    if ! grep -q "$param" "$GRUB_FILE"; then
        sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\\(.*\\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\\1 $param\"|" "$GRUB_FILE"
        echo "      → $param hinzugefügt"
    else
        echo "      → $param bereits gesetzt"
    fi
done

# Altlasten aus früheren Versionen dieses Skripts entfernen
sudo sed -i 's| xe.enable_dc=0||; s| xe.enable_fbc=0||' "$GRUB_FILE"

# --- 2. OEM-Kernel ----------------------------------------------------------

echo "[2/7] OEM-Kernel installieren"

sudo apt update -qq
sudo apt install -y linux-oem-24.04d linux-headers-oem-24.04d

echo "[3/7] OEM-Kernel als GRUB-Default setzen"

# GRUB_DEFAULT=saved + grub-set-default: unabhängig vom Release-Namen
# (Wilma/Zena/...). Gesucht wird über die menuentry-IDs in grub.cfg, nicht
# über die Titel (die sind je nach Locale übersetzt). grub.cfg ist nur für
# root lesbar, daher sudo.
if grep -q '^GRUB_DEFAULT=' "$GRUB_FILE"; then
    sudo sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT=saved|' "$GRUB_FILE"
else
    echo 'GRUB_DEFAULT=saved' | sudo tee -a "$GRUB_FILE" >/dev/null
fi
sudo update-grub

OEM_VERSION="$(dpkg -l | awk '/^ii.*linux-image-.*-oem/ {print $2}' \
    | grep -oP '\d+\.\d+\.\d+-\d+-oem' | sort -V | tail -1 || true)"

GRUB_CFG=/boot/grub/grub.cfg
if [[ -n "$OEM_VERSION" ]]; then
    SUBMENU_ID="$(sudo grep -oP "^submenu .*'\Kgnulinux-advanced-[^']+" "$GRUB_CFG" | head -1 || true)"
    ENTRY_ID="$(sudo grep -oP "'\Kgnulinux-${OEM_VERSION}-advanced-[^']+" "$GRUB_CFG" | head -1 || true)"
    if [[ -n "$SUBMENU_ID" && -n "$ENTRY_ID" ]]; then
        sudo grub-set-default "${SUBMENU_ID}>${ENTRY_ID}"
        echo "      → Default: $OEM_VERSION"
    else
        echo "      WARNUNG: GRUB-Eintrag für $OEM_VERSION nicht gefunden — beim Booten manuell wählen!"
    fi
else
    echo "      WARNUNG: OEM-Kernel-Version nicht ermittelbar — beim Booten manuell wählen!"
fi

# --- 4. SOF Audio Firmware --------------------------------------------------

echo "[4/7] SOF Audio Firmware (sof-bin) aktualisieren"

SOF_BIN_VERSION="2025.12.2"
SOF_BIN_URL="https://github.com/thesofproject/sof-bin/releases/download/v${SOF_BIN_VERSION}/sof-bin-${SOF_BIN_VERSION}.tar.gz"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

(
    cd "$TMPDIR"
    wget -q "$SOF_BIN_URL"
    tar xf "sof-bin-${SOF_BIN_VERSION}.tar.gz"
    cd "sof-bin-${SOF_BIN_VERSION}"
    sudo make install >/dev/null
)

sudo update-initramfs -u -k all >/dev/null

# --- 5. Firmware-Updates via LVFS -------------------------------------------

echo "[5/7] fwupd einrichten und Firmware-Stand prüfen"

sudo apt install -y fwupd
sudo fwupdmgr refresh --force >/dev/null 2>&1 || true
echo "      Verfügbare Updates:"
sudo fwupdmgr get-updates 2>&1 | sed 's/^/        /' || true
echo "      → Updates manuell installieren mit: sudo fwupdmgr update"

# --- 6. Power Management ----------------------------------------------------

echo "[6/7] Power Management"

sudo apt install -y power-profiles-daemon
sudo systemctl enable --now power-profiles-daemon.service

# --- 7. Wayland-Session: logischer Layout-Modus (User-Setting) --------------
# Wirkt nur in "Cinnamon on Wayland": xdg_output liefert dann die korrekte
# logische Größe (1440x900 bei Scale 2), Firefox rendert scharf.
# Auf X11 ohne Effekt.

echo "[7/7] Muffin: logischer Layout-Modus für die Wayland-Session"

gsettings set org.cinnamon.muffin experimental-features "['scale-monitor-framebuffer']" \
    && echo "      → gesetzt" || echo "      → Key nicht verfügbar, übersprungen"

# --- Optional: XFCE ---------------------------------------------------------

if [[ $INSTALL_XFCE -eq 1 ]]; then
    echo "[+] XFCE als Fallback-Desktop installieren"
    sudo apt install -y xfce4 xfce4-goodies xfce4-power-manager
fi

# --- Fertig -----------------------------------------------------------------

echo
echo "=== Fertig ==="
echo
echo "Nächste Schritte:"
echo "  1. sudo reboot   (OEM-Kernel wird automatisch gewählt)"
echo "  2. Cinnamon-(X11-)Session — Display und Audio sollten laufen."
echo "     Beim allerersten Login fehlt gelegentlich das Panel; ein"
echo "     zweiter Reboot behebt das."
echo
echo "Verifizieren:"
echo "  uname -r                       # endet auf -oem"
echo "  cat /proc/cmdline              # enthält enable_psr=0 enable_panel_replay=0"
echo "  sudo head -2 /sys/kernel/debug/dri/0000:00:02.0/eDP-1/i915_psr_status"
echo "                                 # 'PSR mode: disabled'"
echo "  aplay -l                       # mehr als nur HDMI-Devices"
echo
echo "Original-GRUB-Konfig: ${GRUB_FILE}.orig"
echo

