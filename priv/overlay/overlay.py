#!/usr/bin/env python3

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Pango", "1.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Gtk, GLib, Gdk, Pango, PangoCairo  # type: ignore[attr-defined]  # gi.repository modules are generated at runtime; pyright/mypy can't resolve them
import os
import math
import time
import threading

PIPE = "/tmp/voxd-overlay.pipe"

# ------------------------------------------------------------
# Futuristic glass card overlay. Bottom-center, fades in/out.
# Pipe protocol unchanged:
#   recording:dictation | recording:ai
#   transcribing | result:<text> | error:<text> | cancelled | idle
#   level:<0..1>   (live mic level for the waveform)
# ------------------------------------------------------------

# Cool-toned palette (RGB 0..1)
CYAN   = (0.31, 0.89, 1.0)   # #4fe3ff  — dictation
VIOLET = (0.72, 0.58, 1.0)   # #b794ff  — AI
GREEN  = (0.33, 0.90, 0.63)  # #54e6a0  — result
RED    = (1.0, 0.48, 0.45)   # #ff7a72  — error
GREY   = (0.60, 0.62, 0.70)  # cancelled / dots

CSS = b"""
window { background-color: transparent; }

/* Futuristic glass surface */
.card {
    background-image: linear-gradient(180deg,
        rgba(255,255,255,0.05),
        rgba(255,255,255,0.00) 42%);
    background-color: rgba(15, 16, 22, 0.96);
    border-radius: 22px;
    border: 1px solid rgba(255, 255, 255, 0.09);
    box-shadow: inset 0 1px 0 rgba(255,255,255,0.10);
}
/* state-tinted border ring (no outer shadow/glow - keeps the card edge clean) */
.card.cyan   { border-color: rgba(79,227,255,0.45); }
.card.violet { border-color: rgba(183,148,255,0.45); }
.card.green  { border-color: rgba(84,230,160,0.40); }
.card.red    { border-color: rgba(255,122,114,0.42); }

.label {
    color: #7d8298;
    font-family: "JetBrains Mono", "SF Mono", "DejaVu Sans Mono", Monospace;
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 2px;
}
.label.cyan   { color: #7ceaff; }
.label.violet { color: #c9b0ff; }
.label.ok     { color: #6df0b3; }
.label.err    { color: #ff948d; }

.text {
    color: #eef0f6;
    font-family: "Inter", "SF Pro Display", "Segoe UI", Sans;
    font-size: 14px;
    font-weight: 500;
}
.text.muted { color: #7d8298; }

.meta {
    color: #7d8298;
    font-family: "JetBrains Mono", "SF Mono", "DejaVu Sans Mono", Monospace;
    font-size: 12px;
    font-weight: 500;
}
"""


# ---------- Custom drawing widgets ----------

class WaveformIndicator(Gtk.DrawingArea):
    """Five animated bars with a soft glow. Color switches by mode."""

    BARS = 5
    BAR_WIDTH = 3
    BAR_GAP = 3
    MIN_H = 6
    MAX_H = 24

    def __init__(self):
        super().__init__()
        w = self.BARS * self.BAR_WIDTH + (self.BARS - 1) * self.BAR_GAP
        self.set_size_request(w, self.MAX_H)
        self._t0 = time.monotonic()
        self._tick_id = None
        self._level = 0.0
        self._color = CYAN
        self.connect("draw", self._on_draw)

    def set_level(self, level: float) -> None:
        self._level = max(0.0, min(1.0, level))

    def set_color(self, rgb) -> None:
        self._color = rgb
        self.queue_draw()

    def start(self):
        if self._tick_id is None:
            self._t0 = time.monotonic()
            self._tick_id = GLib.timeout_add(33, self._tick)  # ~30fps

    def stop(self):
        if self._tick_id is not None:
            GLib.source_remove(self._tick_id)
            self._tick_id = None

    def _tick(self):
        self.queue_draw()
        return True

    def _on_draw(self, widget, cr):
        alloc = self.get_allocation()
        t = time.monotonic() - self._t0
        cy = alloc.height / 2
        r, g, b = self._color
        lv = self._level
        for i in range(self.BARS):
            phase = t * 2.6 - i * 0.35
            v = 0.5 + 0.5 * math.sin(phase)
            effective_max = self.MIN_H + (self.MAX_H - self.MIN_H) * lv
            h = self.MIN_H + (effective_max - self.MIN_H) * v
            x = i * (self.BAR_WIDTH + self.BAR_GAP)
            y = cy - h / 2
            intensity = 0.6 + 0.4 * v
            # soft glow — wider, low-alpha bar behind
            cr.set_source_rgba(r, g, b, 0.18 * intensity)
            self._round_rect(cr, x - 1.5, y - 1.5, self.BAR_WIDTH + 3, h + 3, 3)
            cr.fill()
            # solid bar
            cr.set_source_rgba(r, g, b, (0.35 + 0.65 * lv) * intensity)
            self._round_rect(cr, x, y, self.BAR_WIDTH, h, 1.5)
            cr.fill()
        return False

    @staticmethod
    def _round_rect(cr, x, y, w, h, r):
        r = min(r, w / 2, h / 2)
        cr.new_sub_path()
        cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
        cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
        cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
        cr.arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
        cr.close_path()


class DotsIndicator(Gtk.DrawingArea):
    """Three bouncing dots for the transcribing state."""

    DOTS = 3
    DOT_R = 2.5
    GAP = 4
    AMPLITUDE = 4
    COLOR = GREY

    def __init__(self):
        super().__init__()
        w = self.DOTS * (self.DOT_R * 2) + (self.DOTS - 1) * self.GAP
        self.set_size_request(int(w), 24)
        self._t0 = time.monotonic()
        self._tick_id = None
        self.connect("draw", self._on_draw)

    def start(self):
        if self._tick_id is None:
            self._t0 = time.monotonic()
            self._tick_id = GLib.timeout_add(33, lambda: (self.queue_draw(), True)[1])

    def stop(self):
        if self._tick_id is not None:
            GLib.source_remove(self._tick_id)
            self._tick_id = None

    def _on_draw(self, widget, cr):
        alloc = self.get_allocation()
        t = time.monotonic() - self._t0
        r, g, b = self.COLOR
        cy = alloc.height / 2
        for i in range(self.DOTS):
            phase = t * 4.5 - i * 0.6
            v = max(0.0, math.sin(phase))  # 0..1, positive half only
            dy = -v * self.AMPLITUDE
            x = self.DOT_R + i * (self.DOT_R * 2 + self.GAP)
            cr.set_source_rgba(r, g, b, 0.35 + 0.65 * v)
            cr.arc(x, cy + dy, self.DOT_R, 0, 2 * math.pi)
            cr.fill()
        return False


class GlyphBadge(Gtk.DrawingArea):
    """Round chip with a single glyph, with a soft glow halo. ✓ / ! / ×."""

    SIZE = 24

    def __init__(self):
        super().__init__()
        self.set_size_request(self.SIZE, self.SIZE)
        self._glyph = ""
        self._fg = (1, 1, 1, 1)
        self._bg = (1, 1, 1, 0.06)
        self._glow = None
        self.connect("draw", self._on_draw)

    def set_state(self, glyph, fg_rgba, bg_rgba, glow_rgb=None):
        self._glyph = glyph
        self._fg = fg_rgba
        self._bg = bg_rgba
        self._glow = glow_rgb
        self.queue_draw()

    def _on_draw(self, widget, cr):
        s = self.SIZE
        cx = cy = s / 2
        # glow halo
        if self._glow is not None:
            gr, gg, gb = self._glow
            cr.set_source_rgba(gr, gg, gb, 0.18)
            cr.arc(cx, cy, s / 2 + 2, 0, 2 * math.pi)
            cr.fill()
        # background circle
        cr.set_source_rgba(*self._bg)
        cr.arc(cx, cy, s / 2, 0, 2 * math.pi)
        cr.fill()

        if not self._glyph:
            return False

        cr.set_source_rgba(*self._fg)
        layout = self.create_pango_layout(self._glyph)
        layout.set_font_description(Pango.FontDescription("Inter Bold 11"))
        tw, th = layout.get_pixel_size()
        cr.move_to((s - tw) / 2, (s - th) / 2 - 1)
        PangoCairo.show_layout(cr, layout)
        return False


# ---------- Main window ----------

class Overlay(Gtk.Window):
    WIDTH = 300
    BOTTOM_MARGIN = 40

    # state name -> card glow style class
    _CARD_CLASSES = ("cyan", "violet", "green", "red")

    def __init__(self):
        super().__init__(type=Gtk.WindowType.POPUP)
        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_resizable(False)
        self.set_app_paintable(True)
        self.set_accept_focus(False)
        self.set_focus_on_map(False)

        visual = self.get_screen().get_rgba_visual()
        if visual:
            self.set_visual(visual)

        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

        self.connect("draw", self._on_draw)

        # ---------- layout ----------
        outer = Gtk.Box()
        outer.set_margin_top(16)
        outer.set_margin_bottom(16)
        outer.set_margin_start(16)
        outer.set_margin_end(16)
        self.add(outer)

        card = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=15)
        self._card = card
        self._card_ctx = card.get_style_context()
        self._card_ctx.add_class("card")
        card.set_size_request(self.WIDTH, -1)

        card_pad = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=15)
        card_pad.set_margin_top(15)
        card_pad.set_margin_bottom(15)
        card_pad.set_margin_start(20)
        card_pad.set_margin_end(20)
        card.pack_start(card_pad, True, True, 0)
        outer.pack_start(card, False, False, 0)

        # Icon slot
        self._icon_slot = Gtk.Box()
        self._icon_slot.set_size_request(30, 30)
        self._icon_slot.set_valign(Gtk.Align.CENTER)
        self._icon_slot.set_halign(Gtk.Align.CENTER)
        card_pad.pack_start(self._icon_slot, False, False, 0)

        # Body
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        body.set_valign(Gtk.Align.CENTER)
        card_pad.pack_start(body, True, True, 0)

        self._label = Gtk.Label(xalign=0)
        self._label.get_style_context().add_class("label")
        self._label.set_ellipsize(Pango.EllipsizeMode.END)
        # visibility is managed per-state (hidden while recording/transcribing)
        self._label.set_no_show_all(True)
        body.pack_start(self._label, False, False, 0)

        self._text = Gtk.Label(xalign=0)
        self._text.get_style_context().add_class("text")
        self._text.set_line_wrap(True)
        self._text.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
        self._text.set_lines(2)
        self._text.set_ellipsize(Pango.EllipsizeMode.END)
        self._text.set_max_width_chars(38)
        body.pack_start(self._text, False, False, 0)

        # Meta (recording timer)
        self._meta = Gtk.Label(xalign=1)
        self._meta.get_style_context().add_class("meta")
        self._meta.set_valign(Gtk.Align.CENTER)
        card_pad.pack_end(self._meta, False, False, 0)

        # Indicators
        self._wave = WaveformIndicator()
        self._dots = DotsIndicator()
        self._badge = GlyphBadge()
        self._current_indicator = None

        # Timers / animation state
        self._hide_timer = None
        self._fade_timer = None
        self._opacity_target = 1.0
        self._record_t0 = None
        self._record_timer = None

    # --- transparent background ---
    def _on_draw(self, widget, cr):
        cr.set_source_rgba(0, 0, 0, 0)
        cr.set_operator(1)  # CAIRO_OPERATOR_SOURCE
        cr.paint()
        return False

    # --- card accent ---
    def _set_card_accent(self, name):
        for c in self._CARD_CLASSES:
            self._card_ctx.remove_class(c)
        if name:
            self._card_ctx.add_class(name)

    # --- positioning ---
    def _reposition(self):
        self.show_all()
        self.resize(1, 1)
        GLib.idle_add(self._do_move)

    def _do_move(self):
        display = Gdk.Display.get_default()
        monitor = display.get_primary_monitor() or display.get_monitor(0)
        geo = monitor.get_geometry()
        w, h = self.get_size()
        # geo and move() are both in logical (already scale-adjusted) pixels on
        # the X11 backend, so don't divide by the scale factor again.
        x = geo.x + (geo.width - w) // 2
        y = geo.y + geo.height - h - self.BOTTOM_MARGIN
        self.move(x, y)
        return False

    # --- fading ---
    def _fade_to(self, target: float):
        if self._fade_timer:
            GLib.source_remove(self._fade_timer)
        self._opacity_target = target
        self._fade_timer = GLib.timeout_add(16, self._fade_step)

    def _fade_step(self) -> bool:
        current = self.get_opacity()
        diff = self._opacity_target - current
        if abs(diff) < 0.04:
            self.set_opacity(self._opacity_target)
            if self._opacity_target == 0.0:
                self.hide()
                self._stop_all_animations()
            self._fade_timer = None
            return False
        self.set_opacity(current + diff * 0.18)
        return True

    # --- indicator swapping ---
    def _set_indicator(self, widget):
        if self._current_indicator is widget:
            return
        for child in self._icon_slot.get_children():
            self._icon_slot.remove(child)
        if widget is not None:
            widget.set_halign(Gtk.Align.CENTER)
            widget.set_valign(Gtk.Align.CENTER)
            self._icon_slot.pack_start(widget, True, True, 0)
            widget.show()
        self._current_indicator = widget

    def _stop_all_animations(self):
        self._wave.stop()
        self._dots.stop()
        if self._record_timer is not None:
            GLib.source_remove(self._record_timer)
            self._record_timer = None

    # --- recording timer ---
    def _start_record_timer(self):
        self._record_t0 = time.monotonic()
        self._meta.set_text("0:00")

        def tick():
            if self._record_t0 is None:
                return False
            elapsed = int(time.monotonic() - self._record_t0)
            m, s = divmod(elapsed, 60)
            self._meta.set_text(f"{m}:{s:02d}")
            return True

        self._record_timer = GLib.timeout_add(500, tick)

    def _stop_record_timer(self):
        self._record_t0 = None
        if self._record_timer is not None:
            GLib.source_remove(self._record_timer)
            self._record_timer = None
        self._meta.set_text("")

    # --- public API ---
    def set_level(self, level: float) -> None:
        self._wave.set_level(level)

    def show_state(self, state: str, text: str = ""):
        if self._hide_timer:
            GLib.source_remove(self._hide_timer)
            self._hide_timer = None

        if state == "idle":
            self._fade_to(0.0)
            self._stop_record_timer()
            return

        text_ctx = self._text.get_style_context()
        text_ctx.remove_class("muted")
        label_ctx = self._label.get_style_context()
        for c in ("cyan", "violet", "ok", "err"):
            label_ctx.remove_class(c)

        if state == "recording":
            self._set_indicator(self._wave)
            self._wave.start()
            self._dots.stop()
            mode = text if text in ("dictation", "ai") else "dictation"
            if mode == "ai":
                self._wave.set_color(VIOLET)
                self._set_card_accent("violet")
            else:
                self._wave.set_color(CYAN)
                self._set_card_accent("cyan")
            self._label.set_visible(False)
            self._text.set_text("Listening…")
            if self._record_timer is None:
                self._start_record_timer()

        elif state == "transcribing":
            self._set_indicator(self._dots)
            self._dots.start()
            self._wave.stop()
            self._stop_record_timer()
            self._set_card_accent(None)
            self._label.set_visible(False)
            self._text.set_text("Converting speech to text…")
            text_ctx.add_class("muted")

        elif state == "result":
            self._set_indicator(self._badge)
            self._badge.set_state(
                "✓",
                fg_rgba=(*GREEN, 1.0),
                bg_rgba=(*GREEN, 0.16),
                glow_rgb=GREEN,
            )
            self._wave.stop()
            self._dots.stop()
            self._stop_record_timer()
            self._set_card_accent("green")
            self._label.set_visible(True)
            self._label.set_text("INSERTED")
            label_ctx.add_class("ok")
            self._text.set_text(text or "Done")
            self._hide_timer = GLib.timeout_add(
                3000, lambda: (self._fade_to(0.0), False)[1]
            )

        elif state == "error":
            self._set_indicator(self._badge)
            self._badge.set_state(
                "!",
                fg_rgba=(*RED, 1.0),
                bg_rgba=(*RED, 0.16),
                glow_rgb=RED,
            )
            self._wave.stop()
            self._dots.stop()
            self._stop_record_timer()
            self._set_card_accent("red")
            self._label.set_visible(True)
            self._label.set_text("ERROR")
            label_ctx.add_class("err")
            self._text.set_text(text or "Something went wrong")
            self._hide_timer = GLib.timeout_add(
                4000, lambda: (self._fade_to(0.0), False)[1]
            )

        elif state == "cancelled":
            self._set_indicator(self._badge)
            self._badge.set_state(
                "×",
                fg_rgba=(*GREY, 1.0),
                bg_rgba=(1.0, 1.0, 1.0, 0.07),
                glow_rgb=None,
            )
            self._wave.stop()
            self._dots.stop()
            self._stop_record_timer()
            self._set_card_accent(None)
            self._label.set_visible(True)
            self._label.set_text("CANCELLED")
            self._text.set_text("Recording discarded")
            text_ctx.add_class("muted")
            self._hide_timer = GLib.timeout_add(
                1500, lambda: (self._fade_to(0.0), False)[1]
            )

        else:
            return

        self.set_opacity(0.0)
        self._reposition()
        self._fade_to(1.0)


# ---------- pipe reader ----------

def pipe_reader(overlay: Overlay):
    if os.path.exists(PIPE):
        os.remove(PIPE)
    os.mkfifo(PIPE)
    while True:
        with open(PIPE, "r") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                state, _, text = line.partition(":")
                if state == "level":
                    try:
                        GLib.idle_add(overlay.set_level, float(text))
                    except ValueError:
                        pass
                else:
                    GLib.idle_add(overlay.show_state, state, text)


def main():
    overlay = Overlay()
    threading.Thread(target=pipe_reader, args=(overlay,), daemon=True).start()
    Gtk.main()


if __name__ == "__main__":
    main()
