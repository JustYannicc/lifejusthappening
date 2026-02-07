# Life Just Happening

A native macOS menu bar app that quietly captures random moments throughout your day using your webcam. No cloud. No internet. Just your life, as it happens.

## Install

### Homebrew (Recommended)

```bash
brew install --cask lifejusthappening
```

### Manual Download

Download the latest `.zip` from the [Releases](https://github.com/JustYannicc/lifejusthappening/releases) page, unzip it, and drag **Life Just Happening.app** to your `/Applications` folder.

### Build from Source

Requires macOS 13.0+ and Swift 5.9+.

```bash
git clone https://github.com/JustYannicc/lifejusthappening.git
cd lifejusthappening/LifeJustHappening
./build-app.sh
open "lifejusthappening.app"
```

## Features

- **Menu bar only** -- Lives quietly in your menu bar with a camera icon. No dock icon, no distractions.
- **Random interval capture** -- Takes photos at random intervals (default 45-60 min, configurable 15-120 min).
- **Sleep/wake aware** -- Captures immediately if a scheduled time passed while your Mac was asleep.
- **Multiple webcam support** -- Drag to reorder priority, enable/disable individual cameras.
- **Flexible storage** -- Save to the Photos app (add-only access) or any folder you choose.
- **Pause anytime** -- Pause indefinitely or for a set duration (30 min, 1 hour, 2 hours).
- **Launch at login** -- Prompts on first launch, configurable in settings.
- **Year-end Wrapped** -- Generate a video slideshow of all your captured moments from the year.
- **All-in-one popover** -- Every setting accessible from the menu bar. No separate windows.

## Usage

1. **First launch** -- Grant camera permission when prompted. Optionally enable launch at login.
2. **Configure** -- Click the camera icon in the menu bar to access all settings.
3. **Set storage** -- Choose the Photos app or a custom folder.
4. **Set interval** -- Adjust the min/max capture interval to your liking.
5. **Manage cameras** -- If you have multiple webcams, drag to set priority and toggle each one.

### Pausing

- Click **Pause** for an indefinite pause.
- Or select a duration: 30 min, 1 hour, 2 hours.
- Click **Resume** to restart capturing.

### Wrapped

At the end of the year, use the Wrapped feature to generate a video slideshow of all your captured moments. Supports HD and 4K output.

## Privacy

Life Just Happening is designed with privacy as a core principle.

- **All photos are stored locally on your device.** Nothing is uploaded anywhere.
- **No internet connection is required** to use this app. It works entirely offline.
- **Camera access** is used only to capture photos at your configured interval.
- **Photos app integration** uses add-only access -- the app cannot read your existing photo library.
- **The Wrapped feature** requires read access to your Photo Library, but only reads the "Life Just Happening" album it created.
- **Anonymous usage analytics** are collected to help improve the app. This can be disabled in Settings. No personal data or photos are ever transmitted.

## Requirements

- macOS 13.0 (Ventura) or later
- A built-in or external webcam

## Uninstall

If installed via Homebrew:

```bash
brew uninstall --cask lifejusthappening
```

If installed manually, drag **Life Just Happening.app** from `/Applications` to the Trash. App preferences are stored in `~/Library/Preferences/com.yanniccharlon.lifejusthappening.plist` and can be removed manually.

## Contributing

Contributions are welcome. Please open an issue first to discuss what you'd like to change.

## License

[MIT](LICENSE.md)
