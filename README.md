# ThinkPad X1 Carbon Gen 14 unter Linux Mint

Setup-Skript für ein ThinkPad X1 Carbon Gen 14 (Intel Panther Lake) mit Linux Mint 22.x Cinnamon. Auf einer frischen Installation friert die Session nach dem Login ein, außerdem fehlt der Ton. Das Skript behebt beides (Boot-Parameter für den xe-Treiber, Ubuntus OEM-Kernel) und ergänzt aktuelle SOF-Audio-Firmware, Firmware-Updates über LVFS, power-profiles-daemon und eine korrekte Skalierung für die Wayland-Session.

Getestet mit:

- ThinkPad X1 Carbon Gen 14, Machine Type 21V7CTO1WW, OLED-Panel Samsung ATNA40HQ09
- Linux Mint 22.3 Cinnamon (Basis Ubuntu 24.04)
- HWE-Kernel 6.17 (Sound nur Dummy Output) gegen OEM-Kernel 6.17.0-1032 (`linux-oem-24.04d`, Sound läuft)
- sof-bin 2025.12.2
- Stand: September 2026

## Hintergrund

### Display

Das Samsung-OLED-Panel beherrscht PSR (Panel Self Refresh) und Panel Replay. Beides ist im xe-Treiber für Panther Lake noch nicht sauber: mit PSR friert die Session direkt nach dem Login ein (schwarzer Bildschirm, Maus tot), mit Panel Replay bleiben nach Idle-Phasen Reste des alten Frames im Bild stehen. `xe.enable_psr=0` allein reicht nicht, weil dann stillschweigend Panel Replay einspringt. Beide Parameter müssen aus. `enable_dc` und `enable_fbc` sind nicht nötig, das wurde einzeln gegengeprüft.

### Audio

Die Cirrus-Codecs hängen am SoundWire-Bus. Dem HWE-Kernel 6.17 fehlt die ACPI-Match-Tabelle für diese Konfiguration, es gibt nur den Dummy Output. Ubuntus OEM-Kernel `linux-oem-24.04d` enthält die Lenovo-Patches, damit läuft der Sound. Das ist ein regulärer Canonical-Kernel aus `noble-updates` und `noble-security`, für Secure Boot signiert und wie der HWE-Kernel über `apt` aktuell gehalten. Der HWE-Kernel bleibt installiert und im GRUB-Menü wählbar.

### Wayland

Unter Cinnamon on Wayland meldet Muffin die `xdg_output`-Größe im physischen Layout-Modus falsch, Firefox rendert deshalb mit Scale 1 und ist unscharf. Der logische Layout-Modus über `experimental-features` behebt das. Electron-Anwendungen wie VS Code sind in der Wayland-Session davon unabhängig weiterhin nicht brauchbar, X11 bleibt daher die Standard-Session.

## Was das Skript macht

1. Trägt `xe.enable_psr=0 xe.enable_panel_replay=0` in `/etc/default/grub` ein. Die Originaldatei wird beim ersten Lauf nach `/etc/default/grub.orig` gesichert, ein vorhandenes Backup wird nicht überschrieben.
2. Installiert den OEM-Kernel (`linux-oem-24.04d` samt Headern).
3. Stellt `GRUB_DEFAULT=saved` ein, führt `update-grub` aus und setzt den OEM-Kernel über `grub-set-default` als Standardeintrag.
4. Lädt sof-bin 2025.12.2 von GitHub und installiert die Firmware per `make install` nach `/lib/firmware/intel/`. Das geschieht an der Paketverwaltung vorbei und überschreibt Dateien aus `firmware-sof-signed`; ein späteres Update dieses Pakets kann sie wieder ersetzen. Anschließend wird das initramfs aller installierten Kernel neu gebaut.
5. Stellt sicher, dass fwupd installiert ist, aktualisiert die LVFS-Metadaten und listet verfügbare Firmware-Updates auf. Installiert wird nichts.
6. Installiert und aktiviert power-profiles-daemon.
7. Setzt für den ausführenden Benutzer `org.cinnamon.muffin experimental-features` auf `['scale-monitor-framebuffer']` (logischer Layout-Modus, ein vorhandener Wert wird ersetzt). Wirkt nur in der Wayland-Session, auf X11 nicht.

Mit `--with-xfce` wird zusätzlich XFCE als Fallback-Desktop installiert (`xfce4`, `xfce4-goodies`, `xfce4-power-manager`).

Das Skript lässt sich mehrfach ausführen: Boot-Parameter werden nur einmal eingetragen, Pakete nur bei Bedarf installiert. Die SOF-Firmware und der GRUB-Standardeintrag werden bei jedem Lauf neu gesetzt, das ist auch der vorgesehene Weg nach einem Kernel-Update. Die Parameter `xe.enable_dc=0` und `xe.enable_fbc=0` aus früheren Versionen des Skripts werden dabei aus `/etc/default/grub` entfernt. Bricht das Skript ab, bleiben die bereits ausgeführten Schritte wirksam.

## Voraussetzungen

- Linux Mint 22.x Cinnamon mit HWE-Kernel. Getestet auf einer frischen Installation; auf einem bereits eingerichteten System vorher `/etc/default/grub` ansehen, das Skript erwartet die Standardzeile `GRUB_CMDLINE_LINUX_DEFAULT="…"`.
- Internetverbindung (Paketquellen, sof-bin von GitHub, LVFS-Metadaten)
- Benutzer mit sudo-Rechten (das Skript nicht als root starten)
- `make`, `wget`, `tar`, `dmidecode` und `gsettings` sind auf Linux Mint vorinstalliert

## Verwendung

```bash
git clone https://github.com/Domi-cc/carbon-x1-linux-mint.git
cd carbon-x1-linux-mint
./install.sh               # Standard-Setup
./install.sh --with-xfce   # zusätzlich XFCE
sudo reboot
```

Meldet sich das Gerät per DMI nicht als X1 Carbon, fragt das Skript vor dem Start nach, ob es trotzdem weitermachen soll (`j` zum Fortfahren). Andere X1-Carbon-Generationen werden dabei nicht unterschieden. `./install.sh --help` gibt den Kommentarblock am Anfang des Skripts aus, dort stehen die Hintergrundinformationen noch einmal ausführlicher.

Für andere Panther-Lake-Geräte: Die xe-Parameter aus Schritt 1 sind nicht Lenovo-spezifisch und lassen sich auch von Hand setzen (in `/etc/default/grub` an `GRUB_CMDLINE_LINUX_DEFAULT` anhängen, danach `sudo update-grub`). Ob der OEM-Kernel dort den Sound bringt, hängt von der Codec-Konfiguration ab und ist ungetestet.

## Nach dem Neustart

Der OEM-Kernel wird automatisch gestartet, sofern das Skript in Schritt 3 „Default: …“ gemeldet hat. In der Cinnamon-Session (X11) sollten Display und Audio laufen. Beim allerersten Login fehlt gelegentlich das Panel, ein zweiter Neustart behebt das.

Kontrolle:

```bash
uname -r              # endet auf -oem
cat /proc/cmdline     # enthält enable_psr=0 enable_panel_replay=0
aplay -l              # listet mehr als nur HDMI-Geräte
sudo head -2 /sys/kernel/debug/dri/0000:00:02.0/eDP-1/i915_psr_status   # PSR mode: disabled
```

Firmware-Updates werden vom Skript nur angezeigt, nicht installiert:

```bash
sudo fwupdmgr update
```

## Wenn etwas nicht funktioniert

GRUB-Menü einblenden: Mint versteckt das Bootmenü. Direkt nach dem Lenovo-Logo `Esc` drücken oder `Shift` gedrückt halten, dann „Advanced options“ öffnen. Dort lassen sich der OEM-Kernel (Eintrag mit `-oem`) und der HWE-Kernel (`-generic`) manuell starten.

Falscher Kernel gestartet: Endet `uname -r` nicht auf `-oem`, konnte das Skript den Standardeintrag nicht setzen (Warnung im Skriptlauf) oder ein Kernel-Update hat den gespeicherten Eintrag ungültig gemacht. Kernel manuell wählen und das Skript erneut ausführen.

Session friert weiterhin ein: Mit `cat /proc/cmdline` prüfen, ob beide `xe.`-Parameter ankommen. Falls nicht, im GRUB-Menü mit `e` die Kernelzeile bearbeiten und die Parameter für diesen Start von Hand anhängen.

GRUB-Konfiguration zurücksetzen:

```bash
sudo cp /etc/default/grub.orig /etc/default/grub
sudo update-grub
```

## Bewusst nicht enthalten

- kisak-mesa-PPA: Mesa 26.x ändert auf Panther Lake nichts an den Artefakten.
- Firefox-Einstellungen (`about:config`): profilabhängig, kein Systemsetup.

## Lizenz

Apache License 2.0, siehe [LICENSE](LICENSE).
