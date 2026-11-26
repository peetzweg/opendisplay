# macOS sender language packs

On launch, the sender checks the user’s preferred languages and downloads a pack only when it supports the selected language and has no verified local copy. A stored pack works offline. English is available immediately while the download runs and remains available if it fails.

The system’s Local Network permission prompt uses the small `InfoPlist.strings` in the app bundle. This lets macOS display that prompt in Chinese even when the interface pack is still downloading.

Each revision is a UTF-8 Apple `Localizable.strings` file under `<language>/<revision>/`. Use the English source text as the key. Keep the argument types of any format placeholders so macOS can insert the dynamic values correctly.

Keep published revisions available for existing builds. To revise a translation, add a new revision and update its URL and SHA-256 in `Mac/AppLanguagePack.swift`. Validate the file with `plutil -lint` and compute its digest with `shasum -a 256`.

The initial Simplified Chinese terminology and translations build on [wlt743’s translation in #491](https://github.com/peetzweg/opendisplay/pull/491).
