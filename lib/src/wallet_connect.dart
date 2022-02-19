import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:stack_trace/stack_trace.dart';
import 'package:uuid/uuid.dart';
import 'package:verify_public_address/src/api/json_rpc_request.dart';
import 'package:verify_public_address/src/api/json_rpc_response.dart';
import 'package:verify_public_address/src/api/wallet_connect/wc_session_request.dart';
import 'package:verify_public_address/src/api/wallet_connect/wc_session_request_response.dart';
import 'package:verify_public_address/src/api/websocket/web_socket_message.dart';
import 'package:verify_public_address/src/crypto/cipher_box.dart';
import 'package:verify_public_address/src/crypto/encrypted_payload.dart';
import 'package:verify_public_address/src/crypto/wallet_connect_cipher.dart';
import 'package:verify_public_address/src/exceptions/wallet_connect_exceptions.dart';
import 'package:verify_public_address/src/network/network.dart';
import 'package:verify_public_address/src/session/peer_meta.dart';
import 'package:verify_public_address/src/session/session_status.dart';
import 'package:verify_public_address/src/session/session_storage.dart';
import 'package:verify_public_address/src/session/wallet_connect_session.dart';
import 'package:verify_public_address/src/utils/bridge_utils.dart';
import 'package:verify_public_address/src/utils/event.dart';
import 'package:verify_public_address/src/utils/event_bus.dart';

typedef OnConnectRequest = void Function(SessionStatus status);
typedef OnDisconnect = void Function();
typedef OnDisplayUriCallback = void Function(String uri);

/// WalletConnect is an open source protocol for connecting decentralised
/// applications to mobile wallets with QR code scanning or deep linking.
///
/// A user can interact securely with any Dapp from their mobile phone,
/// making WalletConnect wallets a safer choice compared to desktop or
/// browser extension wallets.
class WalletConnect {
  /// The wallet connect protocol
  static const protocol = 'wc';

  /// The current wallet connect version
  static const version = 1;

  /// The current active session.
  final WalletConnectSession session;

  /// The storage when sessions can be stored and retrieved.
  final SessionStorage? sessionStorage;

  /// Default signing methods (for Ethereum)
  //final List<String> signingMethods;

  /// The socket transport layer
  SocketTransport transport;

  /// The algorithm used to encrypt/decrypt payloads
  CipherBox cipherBox;

  /// The map of request ids to pending requests.
  final _pendingRequests = <int, _Request>{};

  /// Eventbus used for internal events.
  final EventBus _eventBus;

  WalletConnect._internal({
    required this.session,
    required this.sessionStorage,
    //required this.signingMethods,
    required this.cipherBox,
    required this.transport,
  }) : _eventBus = EventBus() {
    // Init transport event handling
    _initTransport();

    // Subscribe to internal events
    _subscribeToInternalEvents();

    if (session.handshakeTopic.isNotEmpty) {
      transport.subscribe(topic: session.handshakeTopic);
    }
  }

  /// WalletConnect is an open source protocol for connecting decentralised
  /// applications to mobile wallets with QR code scanning or deep linking.
  ///
  /// You should provide a bridge, uri or session object.
  factory WalletConnect({
    String bridge = '',
    String uri = '',
    WalletConnectSession? session,
    SessionStorage? sessionStorage,
    CipherBox? cipher,
    SocketTransport? transport,
    String? clientId,
    PeerMeta? clientMeta,
  }) {
    if (bridge.isEmpty && uri.isEmpty && session == null) {
      throw WalletConnectException(
        'Missing one of the required parameters: bridge / uri / session',
      );
    }

    if (bridge.isNotEmpty) {
      bridge = BridgeUtils.getBridgeUrl(bridge);
    }

    if (uri.isNotEmpty) {
      session = WalletConnectSession.fromUri(uri);
    }

    session = session ??
        WalletConnectSession(
          bridge: bridge,
          accounts: [],
          clientId: clientId ?? const Uuid().v4(),
          clientMeta: clientMeta ?? const PeerMeta(),
        );

    cipher = cipher ?? WalletConnectCipher();

    transport = transport ??
        SocketTransport(
          protocol: session.protocol,
          version: session.version,
          url: session.bridge,
          subscriptions: [session.clientId],
        );

    return WalletConnect._internal(
      session: session,
      sessionStorage: sessionStorage,
      cipherBox: cipher,
      //signingMethods: [...ethSigningMethods],
      transport: transport,
    );
  }

  /// Listen to internal events.
  void on<T>(String eventName, OnEvent<T> callback) {
    _eventBus
        .on<Event<T>>()
        .where((event) => event.name == eventName)
        .listen((event) => callback(event.data));
  }

  /// Create a new session.
  Future<SessionStatus> connect(
      {int? chainId, OnDisplayUriCallback? onDisplayUri}) async {
    if (connected) {
      onDisplayUri?.call(session.toUri());
      return SessionStatus(
        chainId: session.chainId,
        accounts: session.accounts,
      );
    }

    return await createSession(chainId: chainId, onDisplayUri: onDisplayUri);
  }

  /// Create a new session between the dApp and wallet.
  Future<SessionStatus> createSession({
    int? chainId,
    OnDisplayUriCallback? onDisplayUri,
  }) async {
    if (connected) {
      throw WalletConnectException('Session currently connected');
    }

    // Generate encryption key
    session.key = await cipherBox.generateKey();

    final request = JsonRpcRequest(
      id: payloadId,
      method: 'wc_sessionRequest',
      params: [
        {
          'peerId': session.clientId,
          'peerMeta': session.clientMeta,
          'chainId': chainId,
        }
      ],
    );

    session.handshakeId = request.id;
    session.handshakeTopic = const Uuid().v4();

    // Display the URI
    final uri = session.toUri();
    onDisplayUri?.call(uri);
    _eventBus.fire(Event<String>('display_uri', uri));

    // Send the request
    final response = await _sendRequest(request, topic: session.handshakeTopic);

    // Notify listeners
    await _handleSessionResponse(response);

    return WCSessionRequestResponse.fromJson(response).status;
  }

  /// Approve the session.
  Future approveSession({
    required List<String> accounts,
    required int chainId,
  }) async {
    if (connected) {
      throw WalletConnectException('Session currently connected');
    }

    final params = {
      'approved': true,
      'chainId': chainId,
      'networkId': 0,
      'accounts': accounts,
      'rpcUrl': '',
      'peerId': session.clientId,
      'peerMeta': session.clientMeta,
    };

    final response = JsonRpcResponse(
      id: session.handshakeId,
      result: params,
    );

    await _sendResponse(response);
    session.connected = true;

    // Notify listeners
    _eventBus.fire(Event<SessionStatus>(
      'connect',
      SessionStatus(
        chainId: chainId,
        accounts: accounts,
      ),
    ));
  }

  /// Reject the session.
  Future rejectSession({String? message}) async {
    if (connected) {
      throw WalletConnectException('Session currently connected');
    }

    message = message ?? 'Session Rejected';

    final response = JsonRpcResponse(
      id: session.handshakeId,
      error: {
        'code': -32000,
        'message': message,
      },
    );

    await _sendResponse(response);
    session.connected = false;

    // Notify listeners
    _eventBus.fire(Event<String>('disconnect', message));
  }

  /// Update the existing session.
  Future updateSession(SessionStatus sessionStatus) async {
    if (!connected) {
      throw WalletConnectException('Session currently disconnected');
    }

    session.chainId = sessionStatus.chainId;
    session.accounts = sessionStatus.accounts;
    session.networkId = sessionStatus.networkId ?? 0;
    session.rpcUrl = sessionStatus.rpcUrl ?? '';

    final params = {
      'approved': true,
      'chainId': session.chainId,
      'networkId': session.networkId,
      'accounts': session.accounts,
      'rpcUrl': session.rpcUrl,
    };

    final request = JsonRpcRequest(
      id: payloadId,
      method: 'wc_sessionUpdate',
      params: [params],
    );

    // Send the request
    final response = await _sendRequest(request);

    // Notify listeners
    await _handleSessionResponse(response);
  }

  /// Send a custom request.
  Future sendCustomRequest({
    required String method,
    required List<dynamic> params,
    String? topic,
  }) async {
    final request = JsonRpcRequest(
      id: payloadId,
      method: method,
      params: params,
    );

    return _sendRequest(request);
  }

  /// Kill the current session.
  Future killSession({String? sessionError}) async {
    final message = sessionError ?? 'Session disconnected';

    final request = JsonRpcRequest(
      id: payloadId,
      method: 'wc_sessionUpdate',
      params: [
        {
          'approved': false,
          'chainId': null,
          'networkId': null,
          'accounts': null,
        }
      ],
    );

    unawaited(_sendRequest(request));

    await _handleSessionDisconnect(errorMessage: message);
  }

  /// Check if the request is a silent payload.
  bool isSilentPayload(JsonRpcRequest request) {
    if (request.method.startsWith('wc_')) {
      return true;
    }

    // if (signingMethods.contains(request.method)) {
    //   return false;
    // }

    return true;
  }

  /// Get a new random, payload id.
  int get payloadId {
    var rng = Random();
    final date = (DateTime.now().millisecondsSinceEpoch * pow(10, 3)).toInt();
    final extra = (rng.nextDouble() * pow(10, 3)).floor();
    return date + extra;
  }

  /// Check if a current session is connected.
  bool get connected => session.connected;

  /// Register callback listeners.
  void registerListeners({
    OnConnectRequest? onConnect,
    //OnSessionUpdate? onSessionUpdate,
    OnDisconnect? onDisconnect,
  }) {
    on<SessionStatus>('connect', (data) => onConnect?.call(data));
    // on<WCSessionUpdateResponse>(
    //     'session_update', (data) => onSessionUpdate?.call(data));
    on('disconnect', (data) => onDisconnect?.call());
  }

  void _handleIncomingMessages(WebSocketMessage message) async {
    final activeTopics = [session.clientId, session.handshakeTopic];
    if (!activeTopics.contains(message.topic)) {
      return;
    }

    final key = session.key;
    if (key == null) {
      return;
    }

    // Decrypt the payload
    final encryptedPayload = EncryptedPayload.fromJson(
      json.decode(message.payload),
    );
    final payload = await cipherBox.decrypt(
      payload: encryptedPayload,
      key: key,
    );

    // Decode the data
    final data = json.decode(utf8.decode(payload));

    // Check if the incoming message is a request
    if (_isJsonRpcRequest(data)) {
      final request = JsonRpcRequest.fromJson(data);
      _eventBus.fire(Event(request.method, request));
      return;
    }

    // Handle the response
    _handleSingleResponse(data);
  }

  /// Sends a JSON-RPC-2 compliant request to invoke the given [method].
  Future _sendRequest(
    JsonRpcRequest request, {
    String? topic,
  }) async {
    final key = session.key;
    if (key == null) {
      return;
    }

    final data = json.encode(request.toJson());
    final payload = await cipherBox.encrypt(
      data: Uint8List.fromList(utf8.encode(data)),
      key: key,
    );

    final method = request.method;
    final silent = isSilentPayload(request);

    // Send the request
    transport.send(
      payload: payload.toJson(),
      topic: topic ?? session.peerId,
      silent: silent,
    );

    var completer = Completer.sync();
    _pendingRequests[request.id] = _Request(method, completer, Chain.current());
    return completer.future;
  }

  Future _sendResponse(JsonRpcResponse response) async {
    final key = session.key;
    if (key == null) {
      return;
    }

    final data = json.encode(response.toJson());
    final payload = await cipherBox.encrypt(
      data: Uint8List.fromList(utf8.encode(data)),
      key: key,
    );

    // Send the request
    transport.send(
      payload: payload.toJson(),
      topic: session.peerId,
      silent: true,
    );
  }

  void _initTransport() {
    transport.on('message', _handleIncomingMessages);

    // Open a new connection
    transport.open();
  }

  /// Handles incoming JSON RPC requests that do not have a mapped id.
  void _subscribeToInternalEvents() {
    // Wallet received a session request.
    on<JsonRpcRequest>('wc_sessionRequest', (payload) {
      final request = WCSessionRequest.fromJson(payload.params?[0]);
      session.handshakeId = payload.id;
      session.peerId = request.peerId ?? '';
      session.peerMeta = request.peerMeta ?? const PeerMeta();

      _eventBus.fire(Event<WCSessionRequest>('session_request', request));
    });

    // Wallet received a session update.
    // on<JsonRpcRequest>('wc_sessionUpdate', (payload) {
    //   _handleSessionResponse(payload.params?[0] ?? {});
    // });
  }

  /// Handles a decoded response from the server after batches have been
  /// resolved.
  void _handleSingleResponse(response) {
    if (!_isResponseValid(response)) return;
    var id = response['id'];
    id = (id is String) ? int.parse(id) : id;
    var request = _pendingRequests.remove(id)!;
    if (response.containsKey('result')) {
      request.completer.complete(response['result']);
    } else {
      request.completer.completeError(
          WalletConnectException(
            response['error']['message'],
            code: response['error']['code'],
            data: response['error']['data'],
          ),
          request.chain);
    }
  }

  /// Determines whether the server's response is valid per the spec.
  bool _isJsonRpcRequest(response) {
    if (response is! Map) return false;
    if (response['jsonrpc'] != '2.0') return false;
    var id = response['id'];
    id = (id is String) ? int.parse(id) : id;
    return response.containsKey('method');
  }

  /// Determines whether the server's response is valid per the spec.
  bool _isResponseValid(response) {
    if (response is! Map) return false;
    if (response['jsonrpc'] != '2.0') return false;
    var id = response['id'];
    id = (id is String) ? int.parse(id) : id;
    if (!_pendingRequests.containsKey(id)) return false;
    if (response.containsKey('result')) return true;

    if (!response.containsKey('error')) return false;
    var error = response['error'];
    if (error is! Map) return false;
    if (error['code'] is! int) return false;
    if (error['message'] is! String) return false;
    return true;
  }

  Future _handleSessionResponse(Map<String, dynamic> params) async {
    final approved = params['approved'] ?? false;
    final connected = this.connected;
    if (approved && !connected) {
      // New connection
      session.approve(params);

      // Store session
      await sessionStorage?.store(session);

      // Notify the listeners
      final data = WCSessionRequestResponse.fromJson(params);
      _eventBus.fire(Event<SessionStatus>('connect', data.status));
    } else if (approved && connected) {
      // Session update
      session.approve(params);

      // Store session
      await sessionStorage?.store(session);

      // Notify the listeners
      //final data = WCSessionUpdateResponse.fromJson(params);
      //_eventBus.fire(Event<WCSessionUpdateResponse>('session_update', data));
    } else {
      await _handleSessionDisconnect();
    }
  }

  Future _handleSessionDisconnect({String? errorMessage}) async {
    session.reset();

    // Remove storage session
    await sessionStorage?.removeSession();

    // Close the web socket connection
    await transport.close();

    // Notify listeners
    _eventBus.fire(Event<Map<String, dynamic>>('disconnect', {
      'message': errorMessage ?? '',
    }));
  }
}

/// A pending request to the server.
class _Request {
  /// The method that was sent.
  final String method;

  /// The completer to use to complete the response future.
  final Completer completer;

  /// The stack chain from where the request was made.
  final Chain chain;

  _Request(this.method, this.completer, this.chain);
}
