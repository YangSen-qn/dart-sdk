import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// Native 平台：当 [sendBufferSize] 非空时构造带 connectionFactory 的
/// [IOHttpClientAdapter]，通过 SO_SNDBUF 限制内核发送缓冲以配合写超时检测。
HttpClientAdapter createDefaultDelegate(int? sendBufferSize) {
  if (sendBufferSize == null) return HttpClientAdapter();

  return IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();
      final option = _buildSndBufOption(sendBufferSize);
      if (option != null) {
        client.connectionFactory = (uri, proxyHost, proxyPort) async {
          // 直连 HTTPS：必须用 SecureSocket.startConnect，HttpClient 拿到 socket
          // 后不会自己再走 TLS，必须由 connectionFactory 完成。
          // HTTP / 代理 HTTPS：HttpClient 内部会自己处理（HTTP 走明文，代理 HTTPS
          // 走 createProxyTunnel），返回裸 TCP Socket 即可。
          // SO_SNDBUF 在 SecureSocket 完成 TLS 握手后设置的同一 fd 上仍生效。
          final isDirectHttps = uri.isScheme('https') && proxyHost == null;
          final host = proxyHost ?? uri.host;
          final port = proxyPort ?? uri.port;
          final ConnectionTask<Socket> task = isDirectHttps
              ? await SecureSocket.startConnect(host, port)
              : await Socket.startConnect(host, port);
          task.socket.then((socket) {
            try {
              socket.setRawOption(option);
            } catch (_) {
              // SO_SNDBUF 设置失败不影响正常连接，静默忽略
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
RawSocketOption? _buildSndBufOption(int size) {
  int? optionName;
  if (Platform.isLinux || Platform.isAndroid || Platform.isFuchsia) {
    optionName = 7;
  } else if (Platform.isMacOS || Platform.isIOS) {
    optionName = 0x1001;
  } else if (Platform.isWindows) {
    optionName = 0x1001;
  }
  if (optionName == null) return null;
  return RawSocketOption.fromInt(
    RawSocketOption.levelSocket,
    optionName,
    size,
  );
}
