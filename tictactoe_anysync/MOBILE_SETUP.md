# Mobile Setup (Android & iOS)

This app supports mobile via a Go FFI bridge. Mobile builds require packaging the native library per-platform.

## Prerequisites
- Flutter SDK (stable)
- Go 1.23+
- Android: Android SDK + NDK (set `ANDROID_NDK_HOME` or provide `--ndk` to the script)
- iOS: Xcode + Command Line Tools

## 1) Add mobile platforms

If `android/` or `ios/` folders are missing:

```
cd tictactoe_anysync
flutter create --platforms=android,ios .
```

## 2) Android: build and package NDK libs

```
bash tictactoe_anysync/scripts/build_android_ndk.sh
```

Outputs: `tictactoe_anysync/android/app/src/main/jniLibs/<abi>/libanysync_bridge.so`

Notes
- Requires Android NDK. Set env `ANDROID_NDK_HOME` or pass `--ndk <path>`.
- Emulator host mapping: use `10.0.2.2:8080` in app settings; physical devices use your machine’s LAN IP:8080.
- Ensure `android/app/src/main/AndroidManifest.xml` includes `<uses-permission android:name="android.permission.INTERNET"/>`.

## 3) iOS: build xcframework and link

```
bash tictactoe_anysync/scripts/build_ios_xcframework.sh
```

Outputs: `tictactoe_anysync/lib/native/ios/AnySyncBridge.xcframework`

Integrate (one-time)
- Open `ios/Runner.xcworkspace` in Xcode.
- Drag `AnySyncBridge.xcframework` into Runner (Embed & Sign).
- Clean build folder, then build/run. Dart loads symbols via `DynamicLibrary.process()`.

## 4) Run on device/emulator

```
cd tictactoe_anysync
flutter run -d android   # or -d ios
```

In-app Settings
- Host: Android emulator `10.0.2.2` (or LAN IP for device); iOS simulator can use `127.0.0.1`.
- Port: `8080`
- Network ID: `tictactoe-network`

Troubleshooting
- Android: if `.so` not found, verify files under `android/src/main/jniLibs/<abi>`.
- iOS: if symbols not found, ensure the xcframework is embedded and code-signed, and do not strip symbols.
- Network: ensure any-sync Docker is running and reachable from the device.
