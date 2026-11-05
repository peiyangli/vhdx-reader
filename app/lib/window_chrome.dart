import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _windowChannel = MethodChannel('vhdx_reader/window');

Future<void> windowAction(String action) async {
  if (!Platform.isWindows) return;
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
