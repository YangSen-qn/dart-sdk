import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

class QiniuHttpClient implements HttpClientAdapter {
  /// TCP 连接建立超时
  ///
  /// 与服务端建立 TCP 连接（三次握手）的最大等待时间，默认 10 秒。
  /// 超时后触发 [DioExceptionType.connectionTimeout] 错误。
  ///
  /// 若不设置，各操作系统默认等待时间差异较大：
  /// - Linux/Android: 约 60 秒
  /// - macOS/iOS: 约 75 秒
  /// - Windows: 约 21 秒
  final Duration connectTimeout;

  /// 写入超时，类似 socket 的 SO_SNDTIMEO
  ///
  /// 请求体流两次数据流动之间的最大等待时间，默认 30 秒。
  /// 超时后触发 [TimeoutException]。
  final Duration writeTimeout;

  /// 读取超时，类似 socket 的 SO_RCVTIMEO
  ///
  /// 响应体流两次数据流动之间的最大等待时间，默认 30 秒。
  /// 如果服务端在传输响应体过程中停滞（网络中断、服务端卡住等），
  /// 超时后触发 [TimeoutException]。
  final Duration readTimeout;

  final HttpClientAdapter _delegate;

  QiniuHttpClient({
    this.connectTimeout = const Duration(seconds: 10),
    this.writeTimeout = const Duration(seconds: 30),
    this.readTimeout = const Duration(seconds: 30),
    HttpClientAdapter? delegate,
  }) : _delegate = delegate ?? HttpClientAdapter();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    options.connectTimeout ??= connectTimeout;
    final stream = requestStream != null
        ? _IdleTimeoutStream(requestStream, writeTimeout)
        : null;
    final response = await _delegate.fetch(options, stream, cancelFuture);
    return ResponseBody(
      _IdleTimeoutStream(response.stream, readTimeout),
      response.statusCode,
      statusMessage: response.statusMessage,
      headers: response.headers,
      isRedirect: response.isRedirect,
    );
  }

  @override
  void close({bool force = false}) {
    _delegate.close(force: force);
  }
}

/// 在源流和消费者之间插入闲时超时检测。
///
/// 核心机制：维护一个独立的 [Timer]，监测"数据是否在流动"。
/// 每次成功转发数据（[output.add]）时重置计时器；
/// 如果 [_idleTimeout] 内没有任何数据转发，计时器触发超时，终止源流并报错。
class _IdleTimeoutStream extends Stream<Uint8List> {
  final Stream<Uint8List> _source;
  final Duration _idleTimeout;

  _IdleTimeoutStream(this._source, this._idleTimeout);

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (_idleTimeout <= Duration.zero) {
      return _source.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
    }

    var done = false;
    Timer? idleTimer;
    StreamSubscription<Uint8List>? sourceSub;

    void resetIdleTimer() {
      idleTimer?.cancel();

      if (done) return;

      idleTimer = Timer(_idleTimeout, () {
        if (done) return;

        done = true;
        sourceSub?.cancel();
        onError?.call(TimeoutException('Idle timeout', _idleTimeout));
        onDone?.call();
      });
    }

    void cancelIdleTimer() {
      idleTimer?.cancel();
      idleTimer = null;
    }

    sourceSub = _source.listen(
      (data) {
        resetIdleTimer();

        if (done) return;

        onData?.call(data);
      },
      onError: (Object e, StackTrace st) {
        if (done) return;

        done = true;
        cancelIdleTimer();
        onError?.call(e, st);
      },
      onDone: () {
        if (done) return;

        done = true;
        cancelIdleTimer();
        onDone?.call();
      },
      cancelOnError: cancelOnError,
    );

    resetIdleTimer();

    return _IdleTimeoutSubscription(
      sourceSub,
      () {
        done = true;
        cancelIdleTimer();
      },
    );
  }
}

/// 包装 [StreamSubscription]，取消时同时清理闲时计时器。
class _IdleTimeoutSubscription implements StreamSubscription<Uint8List> {
  final StreamSubscription<Uint8List> _source;
  final void Function() _onCancel;

  _IdleTimeoutSubscription(this._source, this._onCancel);

  @override
  Future<void> cancel() {
    _onCancel();
    return _source.cancel();
  }

  @override
  void onData(void Function(Uint8List data)? handleData) =>
      _source.onData(handleData);

  @override
  void onDone(void Function()? handleDone) => _source.onDone(handleDone);

  @override
  void onError(Function? handleError) => _source.onError(handleError);

  @override
  void pause([Future<void>? resumeSignal]) => _source.pause(resumeSignal);

  @override
  void resume() => _source.resume();

  @override
  bool get isPaused => _source.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _source.asFuture(futureValue);
}
