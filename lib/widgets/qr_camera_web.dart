import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Есть ли камера для QR-кода: браузер даёт её только на https.
bool get qrCameraSupported {
  try {
    final navigator = globalContext.getProperty<JSObject?>('navigator'.toJS);
    final media = navigator?.getProperty<JSObject?>('mediaDevices'.toJS);
    return media != null && media.has('getUserMedia');
  } catch (_) {
    return false;
  }
}

/// Почему камера не открылась.
enum QrCameraProblem { denied, unavailable }

/// Видео с задней камеры и поиск QR-кода в нём.
///
/// Распознаёт jsQR (web/js/jsqr.min.js) — он лежит в самой сборке, а не
/// грузится с чужого сайта, и подтягивается, только когда камеру открыли:
/// остальным страницам его 130 КБ ни к чему. Кадр уменьшаем до 640 точек по
/// большей стороне: QR-код на экране компьютера крупный, а слабый телефон
/// иначе не успевает.
class QrCamera extends StatefulWidget {
  const QrCamera({super.key, required this.onCode, required this.onProblem});

  /// Что прочитано в коде — один раз.
  final ValueChanged<String> onCode;
  final ValueChanged<QrCameraProblem> onProblem;

  @override
  State<QrCamera> createState() => _QrCameraState();
}

class _QrCameraState extends State<QrCamera> {
  static const _scanEvery = Duration(milliseconds: 250);
  static const _maxSide = 640;

  JSObject? _video;
  JSObject? _stream;
  JSObject? _canvas;
  JSObject? _context;
  Timer? _timer;
  bool _found = false;
  bool _disposed = false;
  bool _ready = false;

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _stop();
    super.dispose();
  }

  void _stop() {
    final stream = _stream;
    _stream = null;
    if (stream == null) return;
    try {
      final tracks = stream.callMethod<JSArray<JSObject>>('getTracks'.toJS);
      for (final track in tracks.toDart) {
        track.callMethod('stop'.toJS);
      }
    } catch (_) {}
    try {
      _video?.setProperty('srcObject'.toJS, null);
    } catch (_) {}
  }

  Future<void> _start(JSObject video) async {
    _video = video;
    video.callMethod('setAttribute'.toJS, 'playsinline'.toJS, ''.toJS);
    video.callMethod('setAttribute'.toJS, 'muted'.toJS, ''.toJS);
    video.setProperty('muted'.toJS, true.toJS);
    final style = video.getProperty<JSObject>('style'.toJS);
    style.setProperty('width'.toJS, '100%'.toJS);
    style.setProperty('height'.toJS, '100%'.toJS);
    style.setProperty('objectFit'.toJS, 'cover'.toJS);

    try {
      await _loadDecoder();
    } catch (_) {
      if (!_disposed) widget.onProblem(QrCameraProblem.unavailable);
      return;
    }
    if (_disposed) return;

    try {
      final media = globalContext
          .getProperty<JSObject>('navigator'.toJS)
          .getProperty<JSObject>('mediaDevices'.toJS);
      final wanted = JSObject()
        ..setProperty('facingMode'.toJS, 'environment'.toJS);
      final constraints = JSObject()
        ..setProperty('video'.toJS, wanted)
        ..setProperty('audio'.toJS, false.toJS);
      final stream = await media
          .callMethod<JSPromise<JSObject>>('getUserMedia'.toJS, constraints)
          .toDart;
      if (_disposed) {
        _stream = stream;
        _stop();
        return;
      }
      _stream = stream;
      video.setProperty('srcObject'.toJS, stream);
      try {
        await video.callMethod<JSPromise<JSAny?>>('play'.toJS).toDart;
      } catch (_) {
        // Safari иногда отклоняет play(), но видео всё равно идёт.
      }
    } catch (e) {
      if (_disposed) return;
      final text = e.toString();
      widget.onProblem(text.contains('NotAllowed') || text.contains('Security')
          ? QrCameraProblem.denied
          : QrCameraProblem.unavailable);
      return;
    }
    if (_disposed) return;
    setState(() => _ready = true);
    _timer = Timer.periodic(_scanEvery, (_) => _scan());
  }

  /// Подгружает jsQR, если его ещё нет на странице.
  static Future<void> _loadDecoder() async {
    if (globalContext.has('jsQR')) return;
    final document = globalContext.getProperty<JSObject>('document'.toJS);
    final script = document.callMethod<JSObject>(
        'createElement'.toJS, 'script'.toJS);
    final done = Completer<void>();
    script.setProperty(
        'onload'.toJS,
        ((JSAny? _) {
          if (!done.isCompleted) done.complete();
        }).toJS);
    script.setProperty(
        'onerror'.toJS,
        ((JSAny? _) {
          if (!done.isCompleted) done.completeError('jsQR не загрузился');
        }).toJS);
    // Путь — от адреса страницы (/web/), как и у остальной сборки.
    script.setProperty('src'.toJS, 'js/jsqr.min.js'.toJS);
    document
        .getProperty<JSObject>('head'.toJS)
        .callMethod('appendChild'.toJS, script);
    await done.future.timeout(const Duration(seconds: 30));
    if (!globalContext.has('jsQR')) throw StateError('нет jsQR');
  }

  void _scan() {
    final video = _video;
    if (_found || _disposed || video == null || _stream == null) return;
    try {
      final width = video.getProperty<JSNumber>('videoWidth'.toJS).toDartInt;
      final height = video.getProperty<JSNumber>('videoHeight'.toJS).toDartInt;
      if (width == 0 || height == 0) return;
      final scale = math.min(1.0, _maxSide / math.max(width, height));
      final w = (width * scale).round();
      final h = (height * scale).round();

      var canvas = _canvas;
      if (canvas == null) {
        final document = globalContext.getProperty<JSObject>('document'.toJS);
        canvas = document.callMethod<JSObject>(
            'createElement'.toJS, 'canvas'.toJS);
        _canvas = canvas;
        final options = JSObject()
          ..setProperty('willReadFrequently'.toJS, true.toJS);
        _context = canvas.callMethod<JSObject>(
            'getContext'.toJS, '2d'.toJS, options);
      }
      final context = _context!;
      if (canvas.getProperty<JSNumber>('width'.toJS).toDartInt != w ||
          canvas.getProperty<JSNumber>('height'.toJS).toDartInt != h) {
        canvas.setProperty('width'.toJS, w.toJS);
        canvas.setProperty('height'.toJS, h.toJS);
      }
      context.callMethodVarArgs('drawImage'.toJS,
          [video, 0.toJS, 0.toJS, w.toJS, h.toJS]);
      final image = context.callMethodVarArgs<JSObject>('getImageData'.toJS,
          [0.toJS, 0.toJS, w.toJS, h.toJS]);
      final options = JSObject()
        ..setProperty('inversionAttempts'.toJS, 'attemptBoth'.toJS);
      final result = globalContext.callMethodVarArgs<JSObject?>('jsQR'.toJS, [
        image.getProperty<JSAny>('data'.toJS),
        w.toJS,
        h.toJS,
        options,
      ]);
      final text = result?.getProperty<JSString?>('data'.toJS)?.toDart ?? '';
      if (text.isEmpty) return;
      _found = true;
      _timer?.cancel();
      _stop();
      widget.onCode(text);
    } catch (_) {
      // Кадр не удался — следующий через четверть секунды.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        HtmlElementView.fromTagName(
          tagName: 'video',
          onElementCreated: (element) => _start(element as JSObject),
        ),
        // Рамка-прицел поверх видео.
        IgnorePointer(
          child: Center(
            child: FractionallySizedBox(
              widthFactor: 0.65,
              child: AspectRatio(
                aspectRatio: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white, width: 3),
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (!_ready)
          const Center(
              child: CircularProgressIndicator(color: Colors.white)),
      ],
    );
  }
}

/// Убрать «?pc=…» из адресной строки, чтобы обновление страницы не
/// спрашивало про тот же компьютер снова.
void forgetCodeInAddress() {
  try {
    final location = globalContext.getProperty<JSObject>('location'.toJS);
    final path = location.getProperty<JSString>('pathname'.toJS).toDart;
    final hash = location.getProperty<JSString>('hash'.toJS).toDart;
    globalContext
        .getProperty<JSObject>('history'.toJS)
        .callMethodVarArgs('replaceState'.toJS, [null, ''.toJS, '$path$hash'.toJS]);
  } catch (_) {}
}
