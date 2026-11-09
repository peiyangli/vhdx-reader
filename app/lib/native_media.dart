import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:media_kit/media_kit.dart';
// Pinned media_kit 1.2.6: use the same loaded libmpv as NativePlayer.
// ignore: implementation_imports
import 'package:media_kit/src/player/native/core/native_library.dart';

typedef _Open = Int32 Function(Pointer<Void>, Pointer<Char>, Pointer<Void>);
typedef _Register =
    Int32 Function(
      Pointer<Void>,
      Pointer<Char>,
      Pointer<Void>,
      Pointer<NativeFunction<_Open>>,
    );

/// Process-lifetime library reference. No Dart callback is invoked by mpv's
/// demux threads. Rust owns cookies even after media_kit's delayed destruction.
class NativeMedia {
  static DynamicLibrary? library;

  static Future<void> register(NativePlayer player) async {
    await player.handle;
    final version = player.mpv.mpv_client_api_version();
    final major = version >> 16;
    final minor = version & 0xffff;
    if (!(major == 2 || (major == 1 && minor >= 106))) {
      throw StateError('Unsupported libmpv stream callback ABI');
    }
    final reader = library;
    if (reader == null) throw StateError('Native reader is not initialized');
    final callback = reader.lookup<NativeFunction<_Open>>('vhdx_mpv_open');
    final register = DynamicLibrary.open(NativeLibrary.path)
        .lookupFunction<
          _Register,
          int Function(
            Pointer<Void>,
            Pointer<Char>,
            Pointer<Void>,
            Pointer<NativeFunction<_Open>>,
          )
        >('mpv_stream_cb_add_ro');
    final protocol = 'vhdx'.toNativeUtf8();
    try {
      final status = register(
        player.ctx.cast(),
        protocol.cast(),
        nullptr,
        callback,
      );
      if (status < 0) {
        throw StateError('libmpv stream registration failed: $status');
      }
    } finally {
      calloc.free(protocol);
    }
  }
}
