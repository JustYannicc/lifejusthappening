# Life Just Happening

A native macOS menu bar app that captures random moments throughout your day using your webcam.

## Features

- **Menu bar only** - Lives quietly in your menu bar with a camera icon, no dock icon
- **Random interval capture** - Takes photos at random intervals (default 45-60 minutes, configurable 15-120 min)
- **Proper sleep/wake handling** - Captures immediately if scheduled time passed during sleep
- **Multiple webcam support** - Drag to reorder priority, enable/disable cameras
- **Storage options**:
  - Photos app (add-only access - can't read your other photos)
  - Custom folder of your choice
- **Pause functionality** - Single click to pause indefinitely, or set duration (30m, 1h, 2h)
- **Launch at login** - Prompts on first launch, configurable in settings
- **Year-end Wrapped** - Generate a video slideshow of your captured moments
- **All-in-one menu** - Everything accessible from the popover, no separate windows

## Requirements

- macOS 13.0 (Ventura) or later
- Swift 5.9+

## Building

```bash
cd LifeJustHappening
./build-app.sh
```

This creates `Life Just Happening.app` which you can:

1. Run directly: `open "Life Just Happening.app"`
2. Move to `/Applications` for permanent installation

## Usage

1. **First launch** - Grant camera permission when prompted, optionally enable launch at login
2. **Configure** - Click the camera icon in menu bar to access all settings
3. **Set storage** - Choose Photos app or a custom folder
4. **Set interval** - Adjust min/max capture interval (default 45-60 minutes)
5. **Manage cameras** - If you have multiple webcams, drag to set priority

### Pausing

- Click **Pause** for indefinite pause
- Or select a duration: 30 min, 1 hour, 2 hours
- Click **Resume** to restart capturing

### Wrapped

At the end of the year, use the Wrapped feature to generate a video slideshow of all your captured moments.

## Migrating from the Old Script

If you were using the launchd script approach:

```bash
# Stop the old service
launchctl unload ~/Library/LaunchAgents/com.user.imagesnapservice.plist

# Build and run the new app
cd LifeJustHappening
./build-app.sh
open "Life Just Happening.app"
```

## Privacy

- Camera access is used only to capture photos at your configured interval
- Photos app integration uses **add-only** access - the app cannot read your photo library
- All data stays on your device

## License

[MIT](LICENSE.md)
