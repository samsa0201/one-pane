import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tmux_pocket/ssh/connection.dart';

void main() {
  test('generated key round-trips through PEM and gives an authorized_keys line', () {
    final (pem, pub) = generateKey();
    expect(pub, startsWith('ssh-ed25519 AAAA'));
    expect(pub, endsWith(' onepane'));
    final kp = SSHKeyPair.fromPem(pem).single;
    expect(publicLine(kp), pub);
    expect(publicLineOf(pem), pub);
    expect(publicLineOf('not a key'), isNull);
  });
}
