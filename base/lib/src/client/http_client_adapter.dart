import 'dart:typed_data';

import 'package:dio/dio.dart';

class StorageHttpClientAdapter implements HttpClientAdapter {
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

  /// 响应接收超时
  ///
  /// 从请求发送完毕到接收到服务端响应的最大等待时间，默认 30 秒。
  /// 超时后触发 [DioExceptionType.receiveTimeout] 错误。
  ///
  /// 注意：这是接收响应头的总时长，而非读取完整响应体的时长。
  /// 对于上传场景，此超时覆盖的是"数据发完后等服务端返回结果"的阶段，
  /// 与上传数据量无关，不受分片大小影响。
  final Duration receiveTimeout;

  final HttpClientAdapter _delegate;

  StorageHttpClientAdapter({
    this.connectTimeout = const Duration(seconds: 10),
    this.receiveTimeout = const Duration(seconds: 30),
    HttpClientAdapter? delegate,
  }) : _delegate = delegate ?? HttpClientAdapter();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    options.connectTimeout ??= connectTimeout;
    options.receiveTimeout ??= receiveTimeout;
    return _delegate.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {
    _delegate.close(force: force);
  }
}
