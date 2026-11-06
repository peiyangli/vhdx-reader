import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _windowChannel = MethodChannel('vhdx_reader/window');

Future<void> windowAction(String action) async {
  if (!Platform.isWindows && !Platform.isMacOS) return;
  try {
    await _windowChannel.invokeMethod<void>(action);
  } on MissingPluginException {
    // Widget tests do not host a native window.
  }
}

class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key});
  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onPanStart: (_) => windowAction('drag'),
    onDoubleTap: () => windowAction('maximize'),
    child: const SizedBox.expand(),
  );
}

class WindowButtons extends StatelessWidget {
  const WindowButtons({super.key});
  @override
  Widget build(BuildContext context) => Row(
    children: [
      _button('最小化', Icons.remove, 'minimize'),
      _button('最大化 / 还原', Icons.crop_square, 'maximize'),
      _button('关闭窗口', Icons.close, 'close'),
    ],
  );
  Widget _button(String tooltip, IconData icon, String action) => SizedBox(
    width: 44,
    height: 44,
    child: IconButton(
      tooltip: tooltip,
      style: IconButton.styleFrom(
        shape: const RoundedRectangleBorder(),
        hoverColor: action == 'close' ? const Color(0xffffdce0) : null,
      ),
      onPressed: () => windowAction(action),
      icon: Icon(icon, size: 16),
    ),
  );
}

/// The native host explicitly reports hide/restore; desktop lifecycle events
/// alone do not reliably describe a window kept alive in the tray.
void setDesktopWindowHandler(Future<dynamic> Function(MethodCall)? handler) {
  _windowChannel.setMethodCallHandler(handler);
}

class DesktopTitleBar extends StatelessWidget {
  const DesktopTitleBar({super.key});
  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xfff7f9fc),
    child: SizedBox(
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 16),
          const Icon(Icons.layers_rounded, size: 20, color: Color(0xff247cbe)),
          const SizedBox(width: 9),
          const Text(
            'VHDX Reader',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const Expanded(child: WindowDragArea()),
          const WindowButtons(),
        ],
      ),
    ),
  );
}
