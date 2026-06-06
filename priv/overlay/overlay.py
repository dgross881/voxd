#!/usr/bin/env python3

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Pango", "1.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Gtk, GLib, Gdk, Pango, PangoCairo
import os
import math
import time
import threading

PIPE = "/tmp/voxd-overlay.pipe"

# ------------------------------------------------------------
# Card-style overlay. Bottom-center, fades in/out, frosted dark.
# Pipe protocol unchanged: write "<state>:<optional text>\n"
#   states: recording | transcribing | result | error | cancelled | idle
# ------------------------------------------------------------

CSS = b"""
window { background-color: transparent; }

.card {
    background-color: rgba(20, 20, 22, 0.94);
    border-radius: 18px;
    border: 1px solid rgba(255, 255, 255, 0.07);
    /* GTK doesn't honor multiple shadows with offsets perfectly, but this
       gives a soft drop shadow under the card. */
    box-shadow: 0 20px 50px rgba(0, 0, 0, 0.55),
                0 4px 14px rgba(0, 0, 0, 0.4);
}

.label {
    color: #8a8a92;
    font-family: "Inter", "SF Pro Display", "Segoe UI", Sans;
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 1.4px;
}
.label.rec { color: #ff6b62; }
.label.ai  { color: #a78bfa; }
.label.ok  { color: #4cd97a; }
.label.err { color: #ff6b62; }

.text {
    color: #f5f5f7;
    font-family: "Inter", "SF Pro Display", "Segoe UI", Sans;
    font-size: 14px;
    font-weight: 500;
}
.text.muted { color: #8a8a92; }

.meta {
    color: #8a8a92;
    font-family: "Inter", "SF Pro Display", "Segoe UI", Sans;
    font-size: 12px;
    font-weight: 500;
}
"""


# ---------- Custom drawing widgets ----------

class WaveformIndicator(Gtk.DrawingArea):
    """Five animated bars. Pure visual, not tied to mic level."""

    BARS = 5
    BAR_WIDTH = 3
    BAR_GAP = 3
    MIN_H = 5
    MAX_H = 22
    COLOR = (1.0, 0.27, 0.23)  # #ff453a-ish

    def __init__(self):
        super().__init__()
        w = self.BARS * self.BAR_WIDTH + (self.BARS - 1) * self.BAR_GAP
        self.set_size_request(w, self.MAX_H)
        self._t0 = time.monotonic()
        self._tick_id = None
        self._level = 0.0
        self.connect("draw", self._on_draw)

    def set_level(self, level: float) -> None:
        self._level = max(0.0, min(1.0, level))

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
        cx = 0
        cy = alloc.height / 2
        r, g, b = self.COLOR
        lv = self._level
        for i in range(self.BARS):
            phase = t * 2.6 - i * 0.35
            v = 0.5 + 0.5 * math.sin(phase)
            effective_max = self.MIN_H + (self.MAX_H - self.MIN_H) * lv
            h = self.MIN_H + (effective_max - self.MIN_H) * v
            x = cx + i * (self.BAR_WIDTH + self.BAR_GAP)
            y = cy - h / 2
            alpha = 0.25 + 0.75 * lv
            cr.set_source_rgba(r, g, b, alpha * (0.6 + 0.4 * v))
            self._round_rect(cr, x, y, self.BAR_WIDTH, h, 1.5)
            cr.fill()
        return False

    @staticmethod
    def _round_rect(cr, x, y, w, h, r):
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
    COLOR = (0.72, 0.72, 0.75)  # #b8b8c0

    def __init__(self):
        super().__init__()
        w = self.DOTS * (self.DOT_R * 2) + (self.DOTS - 1) * self.GAP
        self.set_size_request(int(w), 22)
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
            v = max(0.0, math.sin(phase))  # 0..1, only positive half
            dy = -v * self.AMPLITUDE
            x = self.DOT_R + i * (self.DOT_R * 2 + self.GAP)
            cr.set_source_rgba(r, g, b, 0.4 + 0.6 * v)
            cr.arc(x, cy + dy, self.DOT_R, 0, 2 * math.pi)
            cr.fill()
        return False


class GlyphBadge(Gtk.DrawingArea):
    """Round chip with a single glyph in it. Used for ✓ / ! / ×."""

    SIZE = 22

    def __init__(self):
        super().__init__()
        self.set_size_request(self.SIZE, self.SIZE)
        self._glyph = ""
        self._fg = (1, 1, 1, 1)
        self._bg = (1, 1, 1, 0.06)
        self.connect("draw", self._on_draw)

    def set_state(self, glyph: str, fg_rgba, bg_rgba):
        self._glyph = glyph
        self._fg = fg_rgba
        self._bg = bg_rgba
        self.queue_draw()

    def _on_draw(self, widget, cr):
        s = self.SIZE
        # background circle
        cr.set_source_rgba(*self._bg)
        cr.arc(s / 2, s / 2, s / 2, 0, 2 * math.pi)
        cr.fill()

        if not self._glyph:
            return False

        # glyph
        cr.set_source_rgba(*self._fg)
        layout = self.create_pango_layout(self._glyph)
        font = Pango.FontDescription("Inter Bold 11")
        layout.set_font_description(font)
        tw, th = layout.get_pixel_size()
        cr.move_to((s - tw) / 2, (s - th) / 2 - 1)
        PangoCairo.show_layout(cr, layout)
        return False


# ---------- Main window ----------

class Overlay(Gtk.Window):
    WIDTH = 420
    BOTTOM_MARGIN = 80

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
        # Outer transparent margin so the shadow has room to render.
        outer = Gtk.Box()
        outer.set_margin_top(14)
        outer.set_margin_bottom(14)
        outer.set_margin_start(14)
        outer.set_margin_end(14)
        self.add(outer)

        card = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14)
        card.get_style_context().add_class("card")
        card.set_margin_top(0)
        card.set_size_request(self.WIDTH, -1)
        # internal padding
        card_pad = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14)
        card_pad.set_margin_top(14)
        card_pad.set_margin_bottom(14)
        card_pad.set_margin_start(18)
        card_pad.set_margin_end(18)
        card.pack_start(card_pad, True, True, 0)
        outer.pack_start(card, False, False, 0)

        # Icon slot — fixed 32px square, holds whichever indicator is active
        self._icon_slot = Gtk.Box()
        self._icon_slot.set_size_request(32, 32)
        self._icon_slot.set_valign(Gtk.Align.CENTER)
        self._icon_slot.set_halign(Gtk.Align.CENTER)
        card_pad.pack_start(self._icon_slot, False, False, 0)

        # Body — vertical stack: tiny label + main text
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        body.set_valign(Gtk.Align.CENTER)
        card_pad.pack_start(body, True, True, 0)

        self._label = Gtk.Label(xalign=0)
        self._label.get_style_context().add_class("label")
        self._label.set_ellipsize(Pango.EllipsizeMode.END)
        body.pack_start(self._label, False, False, 0)

        self._text = Gtk.Label(xalign=0)
        self._text.get_style_context().add_class("text")
        self._text.set_line_wrap(True)
        self._text.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
        self._text.set_lines(2)
        self._text.set_ellipsize(Pango.EllipsizeMode.END)
        self._text.set_max_width_chars(38)
        body.pack_start(self._text, False, False, 0)

        # Meta (right side, e.g. recording timer)
        self._meta = Gtk.Label(xalign=1)
        self._meta.get_style_context().add_class("meta")
        self._meta.set_valign(Gtk.Align.CENTER)
        card_pad.pack_end(self._meta, False, False, 0)

        # Indicator widgets (created once, swapped into icon slot)
        self._wave = WaveformIndicator()
        self._dots = DotsIndicator()
        self._badge = GlyphBadge()
        self._current_indicator = None

        # State for animations & timers
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

    # --- positioning ---
    def _reposition(self):
        self.show_all()
        self.resize(1, 1)
        GLib.idle_add(self._do_move)

    def _do_move(self):
        display = Gdk.Display.get_default()
        monitor = display.get_primary_monitor() or display.get_monitor(0)
        geo = monitor.get_geometry()
        scale = monitor.get_scale_factor() or 1
        w, h = self.get_size()
        x = geo.x + (geo.width // scale - w) // 2
        y = geo.y + geo.height // scale - h - self.BOTTOM_MARGIN
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

    # --- recording timer (mm:ss in meta slot) ---
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
        for c in ("rec", "ok", "err", "ai"):
            label_ctx.remove_class(c)

        if state == "recording":
            self._set_indicator(self._wave)
            self._wave.start()
            self._dots.stop()
            mode = text if text in ("dictation", "ai") else "dictation"
            if mode == "ai":
                self._label.set_text("AI")
                label_ctx.add_class("ai")
            else:
                self._label.set_text("DICTATION")
                label_ctx.add_class("rec")
            self._text.set_text("Listening…")
            if self._record_timer is None:
                self._start_record_timer()

        elif state == "transcribing":
            self._set_indicator(self._dots)
            self._dots.start()
            self._wave.stop()
            self._stop_record_timer()
            self._label.set_text("TRANSCRIBING")
            self._text.set_text("Converting speech to text…")
            text_ctx.add_class("muted")

        elif state == "result":
            self._set_indicator(self._badge)
            self._badge.set_state(
                "✓",
                fg_rgba=(0.30, 0.82, 0.36, 1.0),
                bg_rgba=(0.30, 0.82, 0.36, 0.16),
            )
            self._wave.stop()
            self._dots.stop()
            self._stop_record_timer()
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
                fg_rgba=(1.0, 0.42, 0.38, 1.0),
                bg_rgba=(1.0, 0.27, 0.23, 0.16),
            )
            self._wave.stop()
            self._dots.stop()
            self._stop_record_timer()
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
                fg_rgba=(0.6, 0.6, 0.63, 1.0),
                bg_rgba=(1.0, 1.0, 1.0, 0.06),
            )
            self._wave.stop()
            self._dots.stop()
            self._stop_record_timer()
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
