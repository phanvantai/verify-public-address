import 'package:verify_public_address/src/session/wallet_connect_session.dart';

abstract class SessionStorage {
  Future store(WalletConnectSession session);

  Future<WalletConnectSession?> getSession();

  Future removeSession();
}
