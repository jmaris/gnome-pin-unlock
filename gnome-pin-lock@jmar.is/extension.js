// import deps
import GObject from 'gi://GObject';
import St from 'gi://St';
import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

//find the password field
function findPasswordClutterText(root) {
    if (!root) return null;
    if (root instanceof Clutter.Text && root.password_char)
        return root;
    for (const child of root.get_children?.() ?? []) {
        const found = findPasswordClutterText(child);
        if (found) return found;
    }
    return null;
}

// draw the numpad

const NumpadOverlay = GObject.registerClass(
class NumpadOverlay extends St.BoxLayout {
    /**
     * @param {function} getEntry - called on each keypress to retrieve the
     *   current Clutter.Text password node. We look it up fresh each time
     *   rather than caching it, because the native dialog may recreate its
     *   widget tree between lock cycles.
     */
    _init(getEntry) {
        super._init({
            name: 'NumpadOverlay',
            vertical: true,
            x_align: Clutter.ActorAlign.CENTER,
            // Pin to the bottom of the lock screen, above the system tray area
            y_align: Clutter.ActorAlign.END,
            style: 'spacing:12px; padding-bottom:48px;',
            // Must be reactive to receive touch/pointer events
            reactive: true,
            opacity: 0,
        });

        this._getEntry = getEntry;
        this._buildNumpad();

        // Fade in smoothly so it doesn't jar against the lock animation
        this.ease({
            opacity: 255,
            duration: 250,
            mode: Clutter.AnimationMode.EASE_OUT_QUAD,
        });
    }

    /** Builds the 4×3 grid of numpad buttons. */
    _buildNumpad() {
        const rows = [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
            ['⌫', '0', '↵'],
        ];
        rows.forEach(row => {
            const rowBox = new St.BoxLayout({
                x_align: Clutter.ActorAlign.CENTER,
                style: 'spacing:12px;',
            });
            row.forEach(label => rowBox.add_child(this._makeKey(label)));
            this.add_child(rowBox);
        });
    }

    /**
     * Creates a single numpad button.
     * Action keys (⌫ and ↵) are styled slightly differently to distinguish
     * them from digit keys.
     */
    _makeKey(label) {
        const isAction = label === '⌫' || label === '↵';

        const base = [
            'width:72px', 'height:72px', 'border-radius:36px',
            `font-size:${isAction ? '20px' : '26px'}`,
            'font-family:"DejaVu Sans"',
            'font-weight:300',
            `color:${isAction ? 'rgba(255,255,255,0.5)' : '#e8e8f0'}`,
            'background-color:rgba(255,255,255,0.10)',
            'border:1px solid rgba(255,255,255,0.15)',
        ].join(';');

        // Pressed state: purple tint for tactile feedback
        const press = base
            .replace('rgba(255,255,255,0.10)', 'rgba(167,139,250,0.40)')
            .replace('rgba(255,255,255,0.15)', 'rgba(167,139,250,0.60)');

        const btn = new St.Button({
            label,
            style: base,
            reactive: true,
            can_focus: false, // don't steal keyboard focus from the password entry
        });

        // Mouse press/release feedback
        btn.connect('button-press-event', () => {
            btn.set_style(press);
            return Clutter.EVENT_PROPAGATE;
        });
        btn.connect('button-release-event', () => {
            btn.set_style(base);
            return Clutter.EVENT_PROPAGATE;
        });

        // Touch feedback — handle BEGIN/END/CANCEL explicitly so the press
        // state is always cleaned up even if the finger slides away
        btn.connect('touch-event', (_actor, ev) => {
            const t = ev.type();
            if (t === Clutter.EventType.TOUCH_BEGIN) {
                btn.set_style(press);
            } else if (t === Clutter.EventType.TOUCH_END) {
                btn.set_style(base);
                this._tap(label);
            } else if (t === Clutter.EventType.TOUCH_CANCEL) {
                btn.set_style(base);
            }
            // STOP prevents the event bubbling up and accidentally
            // shifting focus away from the native password entry
            return Clutter.EVENT_STOP;
        });

        // Mouse click (covers both primary pointer and accessibility activation)
        btn.connect('clicked', () => this._tap(label));

        return btn;
    }

    /**
     * Handles a button tap by manipulating the native password entry's
     * Clutter.Text directly:
     *   - digit  → append to current text
     *   - ⌫      → remove last character
     *   - ↵      → emit 'activate' to submit the password
     */
    _tap(label) {
        const ct = this._getEntry();
        if (!ct) return;

        if (label === '⌫') {
            const current = ct.text ?? '';
            ct.set_text(current.slice(0, -1));
        } else if (label === '↵') {
            ct.emit('activate');
        } else {
            ct.set_text((ct.text ?? '') + label);
        }
    }
});

// ── Extension lifecycle ───────────────────────────────────────────────────────

export default class PinLockExtension {
    constructor(metadata) {
        this._metadata = metadata;
    }

    enable() {
        this._overlay = null;
        this._sessionModeId = null;

        // Watch for session mode changes. GNOME switches to 'unlock-dialog'
        // when the screen locks and back to 'user' when it unlocks.
        this._sessionModeId = Main.sessionMode.connect('updated', () => {
            if (Main.sessionMode.currentMode === 'unlock-dialog')
                this._show();
            else
                this._hide();
        });

        // Handle the case where the extension is enabled while already locked
        if (Main.sessionMode.currentMode === 'unlock-dialog')
            this._show();
    }

    disable() {
        if (this._sessionModeId) {
            Main.sessionMode.disconnect(this._sessionModeId);
            this._sessionModeId = null;
        }
        this._hide();
    }

    _show() {
        if (this._overlay) return;

        // _lockDialogGroup is the container GNOME uses for the unlock dialog.
        // It sits within screenShieldGroup and is the correct place to add
        // supplementary lock-screen UI — it receives input correctly on Wayland.
        const container = Main.screenShield?._lockDialogGroup;
        if (!container) return;

        // Delay slightly so the native UnlockDialog has time to build its
        // full widget tree before we try to walk it looking for the entry.
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, 300, () => {
            if (this._overlay) return GLib.SOURCE_REMOVE;

            this._overlay = new NumpadOverlay(() => {
                // Look up the password entry fresh on every keypress.
                // The native dialog is at Main.screenShield._dialog.
                return findPasswordClutterText(Main.screenShield?._dialog);
            });

            // Stretch the overlay to fill the dialog group so clicks outside
            // the numpad buttons fall through to the native dialog beneath.
            this._overlay.add_constraint(new Clutter.BindConstraint({
                source: container,
                coordinate: Clutter.BindCoordinate.SIZE,
            }));
            this._overlay.set_position(0, 0);
            container.add_child(this._overlay);

            // Null our reference if GNOME destroys the overlay externally
            this._overlay.connect('destroy', () => {
                this._overlay = null;
            });

            return GLib.SOURCE_REMOVE;
        });
    }

    _hide() {
        if (this._overlay) {
            this._overlay.destroy();
            this._overlay = null;
        }
    }
}
