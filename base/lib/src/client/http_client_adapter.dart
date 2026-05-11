import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// 七牛自定义 HTTP 客户端
///
/// 在 dio 默认的 [HttpClientAdapter] 之上补充：
/// - 连接超时 [connectTimeout]
/// - 请求体闲时超时 [writeTimeout]
/// - 等待响应头闲时超时（与 [readTimeout] 共用时长）
/// - 响应体闲时超时 [readTimeout]
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

  /// 写入闲时超时，类似 socket 的 SO_SNDTIMEO
  ///
  /// 请求体流两次数据流动之间的最大等待时间，默认 30 秒。
  /// 超时后触发 [TimeoutException]。
  final Duration writeTimeout;

  /// 读取闲时超时，类似 socket 的 SO_RCVTIMEO
  ///
  /// 包含两个阶段的闲时检测，两者共用该时长：
  /// 1. 请求体发送完毕 → 响应头到达：等待服务端响应期间网络断开的检测；
  /// 2. 响应体两次数据流动之间：响应传输过程中网络中断、服务端卡住的检测。
  ///
  /// 默认 30 秒。超时后触发 [TimeoutException]。
  final Duration readTimeout;

  /// TCP 发送缓冲区大小（字节），默认 256KB
  ///
  /// 设置后会通过 [Socket.setRawOption] 限制内核 send buffer 上限，
  /// 让大块数据无法一次写完，触发 IOSink 背压链路 pause 我们的 source，
  /// 从而让 [writeTimeout] 的"闲时"语义恢复成"传输停顿"，
  /// 而不是退化为"事件流动后的整体计时器"。
  ///
  /// 传入 null 时沿用 OS 自动调优（macOS/iOS 通常自动放大到几 MB），
  /// 此时如果上层一次写入的分片大于内核缓冲（典型 4MB 分片场景），
  /// [writeTimeout] 会因 onDone 提前到达而失效。
  ///
  /// 推荐 64 * 1024 ~ 1024 * 1024。
  /// 过小（如 32KB）会让 TCP 拥塞窗口拉不起来，影响吞吐；
  /// 过大（接近或超过分片大小）则失去触发 pause-driven idle 检测的作用。
  /// 默认 256KB 与分片上传的次级切片大小匹配，每片正好填满一次发送缓冲。
  final int? sendBufferSize;

  final HttpClientAdapter _delegate;

  QiniuHttpClient({
    this.connectTimeout = const Duration(seconds: 10),
    this.writeTimeout = const Duration(seconds: 30),
    this.readTimeout = const Duration(seconds: 30),
    this.sendBufferSize = 256 * 1024,
    HttpClientAdapter? delegate,
  }) : _delegate = delegate ?? _buildDefaultAdapter(sendBufferSize);

  /// 默认 delegate 工厂。
  ///
  /// 仅在调用方需要自定义 [sendBufferSize] 时构造带 connectionFactory 的
  /// [IOHttpClientAdapter]；否则退回到 dio 默认 [HttpClientAdapter]，避免
  /// 在 Web 等不支持 dart:io 的平台上引入硬依赖。
  static HttpClientAdapter _buildDefaultAdapter(int? sendBufferSize) {
    if (sendBufferSize == null) return HttpClientAdapter();
    return IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        final option = _buildSndBufOption(sendBufferSize);
        if (option != null) {
          client.connectionFactory = (uri, proxyHost, proxyPort) async {
            // 当设置了 connectionFactory，dart:io 的 HttpClient 不再自动做 TLS 升级
            // （详见 sdk/lib/_http/http_impl.dart 中 cf != null 的分支），
            // 因此必须由 factory 自身按 scheme/proxy 决定走 SecureSocket 还是 Socket。
            // 仅在直连 https 时使用 SecureSocket；https + proxy 场景由 HttpClient
            // 自己通过 CONNECT 隧道完成 TLS，这里只负责连到代理的明文 socket。
            final isDirectHttps = uri.isScheme('https') && proxyHost == null;
            final host = proxyHost ?? uri.host;
            final port = proxyPort ?? uri.port;
            print('[DIAG] connectionFactory: $host:$port isDirectHttps=$isDirectHttps sndbuf=$sendBufferSize');
            final ConnectionTask<Socket> task = isDirectHttps ? await SecureSocket.startConnect(host, port) : await Socket.startConnect(host, port);
            // 关键时序：此处的 then 比 HttpClient 的 `await task.socket` 先注册，
            // 微任务按注册顺序执行，因此 setRawOption 在 HttpClient 拿到 socket
            // 准备写第一个字节之前生效。
            task.socket.then((socket) {
              try {
                socket.setRawOption(option);
                // 读回内核实际生效值（OS 可能 round-up 或截断到上限）
                final actual = socket.getRawOption(
                  RawSocketOption(option.level, option.option, Uint8List(4)),
                );
                final view = ByteData.sublistView(actual);
                final got = view.getUint32(0, Endian.host);
                print('[DIAG] setRawOption SO_SNDBUF set=$sendBufferSize got=$got');
              } catch (e) {
                print('[DIAG] setRawOption failed: $e');
              }
            });
            return task;
          };
        }
        return client;
      },
    );
  }

  /// 按平台构造 SO_SNDBUF 的 [RawSocketOption]。
  ///
  /// `level` 都是 `SOL_SOCKET`（dart:io 暴露为 [RawSocketOption.levelSocket]），
  /// `optionName` 各 OS 不一致，必须按平台写死。
  static RawSocketOption? _buildSndBufOption(int size) {
    int? optionName;
    if (Platform.isLinux || Platform.isAndroid || Platform.isFuchsia) {
      optionName = 7; // SO_SNDBUF on Linux/Android
    } else if (Platform.isMacOS || Platform.isIOS) {
      optionName = 0x1001; // SO_SNDBUF on Darwin
    } else if (Platform.isWindows) {
      optionName = 0x1001; // SO_SNDBUF on Winsock
    }
    if (optionName == null) return null;
    return RawSocketOption.fromInt(
      RawSocketOption.levelSocket,
      optionName,
      size,
    );
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    print('[DIAG] ${DateTime.now()} fetch ${options.uri} by ${options.method}');
    options.connectTimeout ??= connectTimeout;

    // 本地取消信号：任一 idle timeout 触发时 complete，dio 收到后会 abort 底层请求。
    // 这是关键：底层 IOSink/_HttpOutgoing 的内部 controller 在背压期间会 buffer
    // 所有事件（包括 error），直接调用 onError 无法穿透。必须通过 abort 撕掉 socket
    // 来让 addStream future 真正 reject。
    final localCancel = Completer<void>();
    final mergedCancel = _mergeCancelFuture(cancelFuture, localCancel.future);

    // 用来把 idle 超时的真实错误抛给外层 await（绕过被 buffer 在 controller 里的 onError）。
    // 与 fetch 的 Future race，超时方先 complete 即可让上层立刻拿到 TimeoutException。
    final timeoutRace = Completer<ResponseBody>();

    void fireIdleTimeout(TimeoutException err, StackTrace st) {
      print('[DIAG] fireIdleTimeout at ${DateTime.now()}: $err');
      // 触发底层 abort，使 dio 的 addStream / response 链路自然终止
      if (!localCancel.isCompleted) localCancel.complete();
      // 给外层 await 一个明确的 TimeoutException
      if (!timeoutRace.isCompleted) timeoutRace.completeError(err, st);
    }

    // 等待响应头阶段的 idle 检测（请求体发完之后到 fetch 返回之间）
    Timer? awaitingHeaderTimer;

    void armAwaitingHeaderTimer() {
      if (readTimeout <= Duration.zero) return;
      awaitingHeaderTimer?.cancel();
      awaitingHeaderTimer = Timer(readTimeout, () {
        fireIdleTimeout(
          TimeoutException(
            'Idle timeout waiting for response headers',
            readTimeout,
          ),
          StackTrace.current,
        );
      });
    }

    void disarmAwaitingHeaderTimer() {
      awaitingHeaderTimer?.cancel();
      awaitingHeaderTimer = null;
    }

    Stream<Uint8List>? wrappedRequest;
    if (requestStream != null) {
      // 阶段 1：请求体推送（writeTimeout 计 idle，pause-driven 语义）；
      // 阶段 1 结束（请求体 onDone）后立即进入阶段 2（armAwaitingHeaderTimer）。
      wrappedRequest = _WriteIdleTimeoutStream(
        requestStream,
        writeTimeout,
        onConsumedDone: armAwaitingHeaderTimer,
        onIdleTimeout: fireIdleTimeout,
      );
    } else {
      // 没有请求体，从一开始就进入等待响应头阶段
      armAwaitingHeaderTimer();
    }

    final ResponseBody response;
    try {
      final fetchFuture = _delegate.fetch(options, wrappedRequest, mergedCancel);
      // 任一 idle 超时触发，timeoutRace 先于 fetch 完成，Future.any 把 TimeoutException
      // 抛出来。底层 fetchFuture 因为 localCancel → abort 也会随后 reject，
      // Future.any 内部会静默处理掉这条迟到的失败，不会留下未处理错误。
      response = await Future.any<ResponseBody>([
        fetchFuture,
        timeoutRace.future,
      ]);
      print('[DIAG] fetch got response status=${response.statusCode} at ${DateTime.now()}');
    } catch (e) {
      print('[DIAG] fetch threw $e at ${DateTime.now()}');
      rethrow;
    } finally {
      disarmAwaitingHeaderTimer();
    }

    return ResponseBody(
      readTimeout > Duration.zero
          ? _ReadIdleTimeoutStream(
              response.stream,
              readTimeout,
              onIdleTimeout: fireIdleTimeout,
            )
          : response.stream,
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

  /// 合并两个取消 future，任一完成即视为取消
  Future<void> _mergeCancelFuture(Future<void>? external, Future<void> internal) {
    if (external == null) return internal;
    final c = Completer<void>();
    void complete() {
      if (!c.isCompleted) c.complete();
    }

    external.then((_) => complete(), onError: (_) => complete());
    internal.then((_) => complete(), onError: (_) => complete());
    return c.future;
  }
}

/// 闲时超时回调签名
typedef _IdleTimeoutCallback = void Function(TimeoutException err, StackTrace st);

// ---------------------------------------------------------------------------
// 闲时超时检测：两种语义
// ---------------------------------------------------------------------------
//
// 都用来在「源流」和「消费者」之间插入一段计时逻辑，区别在于以什么信号
// 判定「网络停滞」：
//
// 1. [_WriteIdleTimeoutStream]（请求体）—— pause-driven
//    位置：上游（文件/encoder）→ 我们 → IOSink（socket）
//    pause 来自 IOSink/socket，表示「网络/socket 写不动」。这就是要测的「停滞」。
//    - pause: 开表
//    - resume: 停表（socket 又能吃了）
//    - onData/onDone/onError: 不驱动计时器
//
// 2. [_ReadIdleTimeoutStream]（响应体）—— data-driven
//    位置：socket（HttpClientResponse）→ 我们 → 消费者（dio 收集 body）
//    pause 来自消费者，表示「业务侧来不及处理」，跟网络无关。
//    - 源吐出数据: 重置计时器（网络在送数据，没停滞）
//    - 消费者 pause: 停表（是我们主动让网络停的，不该当作网络停滞）
//    - 消费者 resume: 重启计时器
//
// 两者共享 [_IdleTimeoutSubscriptionBase]：统一处理 listen 绑定、handler
// 可替换、_fire（错误传递 + 触发底层 abort）等通用部分；具体语义差异通过
// 三个钩子注入：_onBound / _onSourceData / _onConsumerPause / _onConsumerResume。
//
// 单订阅语义：每个 Stream 实例只能 listen 一次。

abstract class _IdleTimeoutSubscriptionBase implements StreamSubscription<Uint8List> {
  final Duration _idleTimeout;

  /// 闲时超时时通知外层（用于触发底层 abort）
  final _IdleTimeoutCallback? _onIdleTimeout;

  /// listen 现场的栈，timer 触发时作为错误堆栈，便于定位调用方
  final StackTrace _listenStack;

  void Function(Uint8List)? _onData;
  Function? _onError;
  void Function()? _onDone;

  StreamSubscription<Uint8List>? _source;
  Timer? _idleTimer;

  bool _finished = false;
  bool _canceled = false;

  _IdleTimeoutSubscriptionBase(this._idleTimeout, this._onIdleTimeout) : _listenStack = StackTrace.current;

  /// 子类钩子：每次源吐出数据时回调（早于消费者 onData）
  void _onSourceData();

  /// 子类钩子：listen 绑定完成后回调
  void _onBound();

  /// 子类钩子：消费者调用 pause() 时
  void _onConsumerPause();

  /// 子类钩子：消费者调用 resume() 时
  void _onConsumerResume();

  void _bind(
    Stream<Uint8List> source,
    void Function(Uint8List)? onData,
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
    void Function()? onConsumedDone,
  ) {
    _onData = onData;
    _onError = onError;
    _onDone = onDone;

    _source = source.listen(
      (data) {
        print('[DIAG] data:${data.length} at ${DateTime.now()}');
        _onSourceData();
        if (_finished) return;
        // 经由可变字段读取最新 handler，支持订阅中途替换
        _onData?.call(data);
      },
      onError: (Object e, StackTrace st) {
        if (_finished) return;
        _finished = true;
        _cancelTimer();
        _onError?.call(e, st);
      },
      onDone: () {
        if (_finished) return;
        _finished = true;
        _cancelTimer();
        _onDone?.call();
        // 源被完整消费后回调（用于切换至等待响应头阶段）
        onConsumedDone?.call();
      },
      cancelOnError: cancelOnError,
    );
    _onBound();
  }

  /// 启动（或重启）计时器，等价于 cancel + arm。
  /// 不区分「首次开启」和「重置」；在 [_finished] / [_idleTimeout]<=0 时无副作用。
  void _startTimer() {
    _idleTimer?.cancel();
    if (_finished) return;
    if (_idleTimeout <= Duration.zero) return;
    _idleTimer = Timer(_idleTimeout, _fire);
  }

  void _cancelTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void _fire() {
    if (_finished) return;
    _finished = true;

    // 立即取消源订阅，避免 timeout 后还有数据回调
    _source?.cancel();

    final err = TimeoutException('Idle timeout', _idleTimeout);

    // 关键：通过外层回调触发底层 abort。
    // 直接调用消费者 onError 在背压场景下会被 dart:io 的 _HttpOutgoing 内部
    // controller buffer 掉（参考 sdk/lib/_http/http_impl.dart _HttpOutgoing.addStream），
    // 必须通过 abort 撕断 socket 让 addStream future reject。
    _onIdleTimeout?.call(err, _listenStack);

    // 同时调用消费者注册的 onError：
    // - 响应体场景下消费者通常是 await for / toList 等，直接收到错误即可立刻终止；
    // - 请求体场景这一步会被 controller buffer 吞掉，但有上面的 _onIdleTimeout 兜底。
    final handler = _onError;
    if (handler == null) {
      // 没有注册：在响应体直接被丢弃的极少数路径，把错误送到 zone
      if (_onIdleTimeout == null) {
        Zone.current.handleUncaughtError(err, _listenStack);
      }
      return;
    }
    if (handler is void Function(Object, StackTrace)) {
      handler(err, _listenStack);
    } else {
      handler(err);
    }
  }

  @override
  void onData(void Function(Uint8List)? handleData) {
    _onData = handleData;
  }

  @override
  void onError(Function? handleError) {
    _onError = handleError;
  }

  @override
  void onDone(void Function()? handleDone) {
    _onDone = handleDone;
  }

  @override
  void pause([Future<void>? resumeSignal]) {
    print('[DIAG] subscription.pause at ${DateTime.now()}');
    _onConsumerPause();
    _source?.pause(resumeSignal);
  }

  @override
  void resume() {
    print('[DIAG] subscription.resume at ${DateTime.now()}');
    _onConsumerResume();
    _source?.resume();
  }

  @override
  bool get isPaused => _source?.isPaused ?? false;

  @override
  Future<void> cancel() async {
    if (_canceled) return;
    _canceled = true;
    _finished = true;
    _cancelTimer();
    await _source?.cancel();
  }

  @override
  Future<E> asFuture<E>([E? futureValue]) => _source?.asFuture<E>(futureValue) ?? Future<E>.value(futureValue as E);
}

/// 写阶段闲时超时：pause-driven。
///
/// 把 [Stream] 喂给 dio 的 `request.addStream` 之前包一层，专测「socket 写不动」。
/// 详见上方综述。
class _WriteIdleTimeoutStream extends Stream<Uint8List> {
  final Stream<Uint8List> _source;
  final Duration _idleTimeout;
  final void Function()? _onConsumedDone;
  final _IdleTimeoutCallback? _onIdleTimeout;
  bool _listened = false;

  _WriteIdleTimeoutStream(
    this._source,
    this._idleTimeout, {
    void Function()? onConsumedDone,
    _IdleTimeoutCallback? onIdleTimeout,
  })  : _onConsumedDone = onConsumedDone,
        _onIdleTimeout = onIdleTimeout;

  @override
  bool get isBroadcast => false;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (_listened) {
      throw StateError(
        '_WriteIdleTimeoutStream has already been listened to.',
      );
    }
    _listened = true;
    final sub = _WriteIdleSubscription(_idleTimeout, _onIdleTimeout);
    sub._bind(_source, onData, onError, onDone, cancelOnError, _onConsumedDone);
    return sub;
  }
}

class _WriteIdleSubscription extends _IdleTimeoutSubscriptionBase {
  _WriteIdleSubscription(super.idleTimeout, super.onIdleTimeout);

  // 写阶段：onData/onBound 都不启动 timer。
  // 启动时未被 IOSink pause，说明 socket 还能吃，无须开表。
  @override
  void _onSourceData() {}

  @override
  void _onBound() {}

  // 下游 IOSink/socket 写不动 → 开表
  @override
  void _onConsumerPause() {
    _startTimer();
  }

  // socket 又能吃 → 停表
  @override
  void _onConsumerResume() {
    _cancelTimer();
  }
}

/// 读阶段闲时超时：data-driven。
///
/// 把 dio 返回的 response.stream 包一层，专测「socket 不再来数据」。
/// 详见上方综述。
class _ReadIdleTimeoutStream extends Stream<Uint8List> {
  final Stream<Uint8List> _source;
  final Duration _idleTimeout;
  final _IdleTimeoutCallback? _onIdleTimeout;
  bool _listened = false;

  _ReadIdleTimeoutStream(
    this._source,
    this._idleTimeout, {
    _IdleTimeoutCallback? onIdleTimeout,
  }) : _onIdleTimeout = onIdleTimeout;

  @override
  bool get isBroadcast => false;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (_listened) {
      throw StateError(
        '_ReadIdleTimeoutStream has already been listened to.',
      );
    }
    _listened = true;
    final sub = _ReadIdleSubscription(_idleTimeout, _onIdleTimeout);
    sub._bind(_source, onData, onError, onDone, cancelOnError, null);
    return sub;
  }
}

class _ReadIdleSubscription extends _IdleTimeoutSubscriptionBase {
  _ReadIdleSubscription(super.idleTimeout, super.onIdleTimeout);

  // 读阶段：数据流过即视为网络活跃，重置计时器
  @override
  void _onSourceData() {
    _startTimer();
  }

  // 绑定完成立即开表，等待第一片数据
  @override
  void _onBound() {
    _startTimer();
  }

  // 消费者主动 pause（业务慢），不该把这段时间算到网络头上
  @override
  void _onConsumerPause() {
    _cancelTimer();
  }

  // 消费者 resume，恢复对网络的闲时检测
  @override
  void _onConsumerResume() {
    _startTimer();
  }
}
