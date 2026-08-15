Drop the four alert sound files here, named to match the Settings page's
Alert Sound dropdown (index.html `#soundChoice` option values):

- chime.mp3
- alert-tone.mp3
- soft-bell.mp3
- siren-lite.mp3

`NotificationSound` (index.html, defined just before the Data Management
IIFE) loads `assets/sounds/<value>.mp3` on demand. A missing file fails
silently (caught in `NotificationSound.play()`) rather than throwing.
