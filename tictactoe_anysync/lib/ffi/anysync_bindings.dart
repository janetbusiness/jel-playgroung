import 'dart:ffi';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:ffi/ffi.dart';

// Load platform-specific library
DynamicLibrary _openDynamicLibrary() {
  if (Platform.isLinux) {
    final candidates = <String>[
      'lib/native/anysync_bridge_linux.so',
      p.join(Directory.current.path, 'lib/native/anysync_bridge_linux.so'),
      // Allow override via env var for local dev
      if (Platform.environment['ANYSYNC_LIB_PATH'] != null)
        Platform.environment['ANYSYNC_LIB_PATH']!,
    ];
    for (final path in candidates.where((e) => e.isNotEmpty)) {
      try {
        if (File(path).existsSync()) return DynamicLibrary.open(path);
      } catch (_) {}
    }
    // Last attempt: rely on loader to search
    return DynamicLibrary.open('anysync_bridge_linux.so');
  } else if (Platform.isMacOS) {
    String? exePath;
    try {
      exePath = File(Platform.resolvedExecutable).resolveSymbolicLinksSync();
    } catch (_) {}
    final exeDir = exePath != null ? p.dirname(exePath) : null; // .../Contents/MacOS
    final frameworksDir =
        exeDir != null ? p.normalize(p.join(exeDir, '../Frameworks')) : null;
    final envPath = Platform.environment['ANYSYNC_LIB_PATH'];
    final candidates = <String>[
      // App bundle Frameworks directory (preferred runtime location)
      if (frameworksDir != null)
        p.join(frameworksDir, 'anysync_bridge_macos.dylib'),
      if (frameworksDir != null)
        p.join(frameworksDir, 'anysync_bridge_macos.so'),
      // Repo-relative dev locations
      'lib/native/anysync_bridge_macos.so',
      'lib/native/anysync_bridge_macos.dylib',
      p.join(Directory.current.path, 'lib/native/anysync_bridge_macos.so'),
      p.join(Directory.current.path, 'lib/native/anysync_bridge_macos.dylib'),
      // Explicit override via env var
      if (envPath != null) envPath,
    ];
    for (final path in candidates.where((e) => e.isNotEmpty)) {
      try {
        if (File(path).existsSync()) return DynamicLibrary.open(path);
      } catch (_) {}
    }
    // Last attempt: rely on loader to search
    try {
      return DynamicLibrary.open('anysync_bridge_macos.dylib');
    } catch (_) {
      return DynamicLibrary.open('anysync_bridge_macos.so');
    }
  } else if (Platform.isAndroid) {
    // On Android, prefer explicit path from ANYSYNC_LIB_PATH; otherwise rely on
    // loader search paths for bundled NDK libs in jniLibs/ (libanysync_bridge.so)
    final override = Platform.environment['ANYSYNC_LIB_PATH'];
    if (override != null && override.isNotEmpty) {
      return DynamicLibrary.open(override);
    }
    // Typical names the Android loader recognizes when packaged under jniLibs
    final candidates = <String>[
      'libanysync_bridge.so',
      'anysync_bridge', // sometimes resolves without lib prefix
    ];
    for (final name in candidates) {
      try {
        return DynamicLibrary.open(name);
      } catch (_) {}
    }
    // Last attempt: fall back to absolute-like search using current dir
    final fallback = p.join(Directory.current.path, 'lib/native/anysync_bridge_linux.so');
    if (File(fallback).existsSync()) {
      return DynamicLibrary.open(fallback);
    }
    throw ArgumentError('Failed to load Android native library');
  } else if (Platform.isIOS) {
    // iOS: dynamic loading of arbitrary dylibs is restricted. The recommended
    // approach is to link the static library (c-archive) into the app and use
    // DynamicLibrary.process() to access its symbols.
    // Ensure an xcframework is linked in Xcode for the Runner target.
    try {
      return DynamicLibrary.process();
    } catch (_) {
      // Allow override for dev builds that embed a dynamic framework
      final override = Platform.environment['ANYSYNC_LIB_PATH'];
      if (override != null && override.isNotEmpty) {
        return DynamicLibrary.open(override);
      }
      throw ArgumentError('Failed to load iOS native library (ensure static linking or set ANYSYNC_LIB_PATH)');
    }
  }
  throw UnsupportedError('Platform not supported');
}

final DynamicLibrary _lib = _openDynamicLibrary();

// C signatures
typedef InitializeClientC = Int32 Function(Pointer<Utf8>, Int32, Pointer<Utf8>);
typedef CreateSpaceC = Pointer<Utf8> Function();
typedef JoinSpaceC = Int32 Function(Pointer<Utf8>);
typedef SendOperationC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef SetOperationCallbackC = Void Function(
  Pointer<Utf8>,
  Pointer<NativeFunction<Void Function(Pointer<Utf8>)>>,
);
typedef StartListeningC = Int32 Function(Pointer<Utf8>);
typedef FreeStringC = Void Function(Pointer<Utf8>);
typedef GetStatusC = Pointer<Utf8> Function();
typedef PollOperationC = Pointer<Utf8> Function(Pointer<Utf8>);

// Dart typedefs
typedef InitializeClientDart = int Function(Pointer<Utf8>, int, Pointer<Utf8>);
typedef CreateSpaceDart = Pointer<Utf8> Function();
typedef JoinSpaceDart = int Function(Pointer<Utf8>);
typedef SendOperationDart = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef SetOperationCallbackDart = void Function(
  Pointer<Utf8>,
  Pointer<NativeFunction<Void Function(Pointer<Utf8>)>>,
);
typedef StartListeningDart = int Function(Pointer<Utf8>);
typedef FreeStringDart = void Function(Pointer<Utf8>);
typedef GetStatusDart = Pointer<Utf8> Function();
typedef PollOperationDart = Pointer<Utf8> Function(Pointer<Utf8>);

// Lookup bindings (suffixed with Native to avoid name collisions)
final InitializeClientDart initializeClientNative =
    _lib.lookup<NativeFunction<InitializeClientC>>('BridgeInitializeClient').asFunction();

final CreateSpaceDart createSpaceNative =
    _lib.lookup<NativeFunction<CreateSpaceC>>('BridgeCreateSpace').asFunction();

final JoinSpaceDart joinSpaceNative =
    _lib.lookup<NativeFunction<JoinSpaceC>>('BridgeJoinSpace').asFunction();

final SendOperationDart sendOperationNative =
    _lib.lookup<NativeFunction<SendOperationC>>('BridgeSendOperation').asFunction();

final SetOperationCallbackDart setOperationCallbackNative = _lib
    .lookup<NativeFunction<SetOperationCallbackC>>('BridgeSetOperationCallback')
    .asFunction();

final StartListeningDart startListeningNative =
    _lib.lookup<NativeFunction<StartListeningC>>('BridgeStartListening').asFunction();

final FreeStringDart freeStringNative =
    _lib.lookup<NativeFunction<FreeStringC>>('BridgeFreeString').asFunction();

final PollOperationDart pollOperationNative =
    _lib.lookup<NativeFunction<PollOperationC>>('BridgePollOperation').asFunction();

final GetStatusDart getStatusNative =
    _lib.lookup<NativeFunction<GetStatusC>>('BridgeGetStatus').asFunction();
