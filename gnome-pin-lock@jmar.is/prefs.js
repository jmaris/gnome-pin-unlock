/**
 * Lock Screen Numpad — prefs.js
 *
 * Preferences window shown when the user opens extension settings.
 * This extension has no configurable options — the prefs window exists
 * to explain how the extension works and how to use it.
 */

import Adw from 'gi://Adw';

export default class PinLockPreferences {
    constructor(metadata) {
        this._metadata = metadata;
    }

    fillPreferencesWindow(window) {
        window.set_title('Lock Screen Numpad');
        window.set_default_size(440, 280);

        const page = new Adw.PreferencesPage({
            title: 'About',
            icon_name: 'input-dialpad-symbolic',
        });
        window.add(page);

        const group = new Adw.PreferencesGroup({
            title: 'Lock Screen Numpad',
        });
        page.add(group);

        group.add(new Adw.ActionRow({
            title: 'How it works',
            subtitle: 'A numpad appears at the bottom of the lock screen. ' +
                'Tap digit buttons to type your password, ⌫ to delete the ' +
                'last character, and ↵ to submit. Your keyboard works simultaneously.',
            icon_name: 'dialog-information-symbolic',
        }));

        group.add(new Adw.ActionRow({
            title: 'Password',
            subtitle: 'Your system login password is used unchanged — ' +
                'this extension does not store or alter any credentials. ' +
                'It simply provides a touch-friendly way to type into the ' +
                'standard GNOME password field.',
            icon_name: 'dialog-password-symbolic',
        }));

        group.add(new Adw.ActionRow({
            title: 'Numeric passwords',
            subtitle: 'For the best experience, set your system login password ' +
                'to a numeric PIN in Settings → Users. The numpad then gives ' +
                'you a complete touch-only unlock flow.',
            icon_name: 'emblem-ok-symbolic',
        }));
    }
}
