import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:open_tv/remote/protocol.dart';
import 'package:open_tv/remote/remote_client.dart';
import 'package:open_tv/remote/remote_store.dart';
import 'package:open_tv/remote/tv_server.dart';

class FakeHost implements RemotePlayerHost {
  final played = <RemoteMedia>[];
  final commands = <String>[];
  final sources = <RemoteSource>[];
  String? playError;

  @override
  Future<String?> play(RemoteMedia media) async {
    played.add(media);
    return playError;
  }

  @override
  void pause() => commands.add("pause");
  @override
  void resume() => commands.add("resume");
  @override
  Future<void> stop() async => commands.add("stop");
  @override
  Future<String> addSources(List<RemoteSource> added) async {
    sources.addAll(added);
    return "Added ${added.length}";
  }
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}

void main() {
  late Directory dir;
  late FakeHost host;
  late RemoteStore tvStore;
  late RemoteStore phoneStore;
  late TvServer server;
  late RemoteClient client;

  Future<bool> connect({AskPairingCode? askCode}) => client.connect(
    store: phoneStore,
    host: "127.0.0.1",
    port: server.boundPort,
    phoneName: "Test phone",
    askCode: askCode ?? (_, _) async => server.pairingCode.value,
  );

  // A client that speaks the protocol directly, to try what the app never sends.
  Future<(WebSocket, StreamIterator<dynamic>)> rawClient() async {
    final socket = await WebSocket.connect(
      "ws://127.0.0.1:${server.boundPort}",
    );
    final messages = StreamIterator<dynamic>(socket);
    expect(await messages.moveNext(), isTrue);
    expect(jsonDecode(messages.current)["type"], "server");
    return (socket, messages);
  }

  Future<void> drained(StreamIterator<dynamic> messages) async {
    while (await messages.moveNext()) {}
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp("remote_test");
    host = FakeHost();
    tvStore = await RemoteStore.load(File("${dir.path}/tv.json"));
    phoneStore = await RemoteStore.load(File("${dir.path}/phone.json"));
    server = TvServer(store: tvStore, host: host, name: "Test TV", port: 0);
    await server.start();
    client = RemoteClient();
  });

  tearDown(() async {
    await client.disconnect();
    await server.stop();
    await dir.delete(recursive: true);
  });

  test("pairs with the code and then plays on the TV", () async {
    server.openPairing();
    expect(await connect(), isTrue);
    expect(client.connected, isTrue);
    expect(client.tvName, "Test TV");
    expect(server.lastPaired.value, "Test phone");
    expect(tvStore.phones.single.name, "Test phone");
    expect(phoneStore.tvs.single.name, "Test TV");

    const media = RemoteMedia(
      url: "http://example.test/live/user/pass/1.ts",
      title: "News",
      isLive: true,
      referer: "http://example.test",
      userAgent: "Agent",
    );
    expect(await client.play(media), isTrue);
    await until(() => host.played.isNotEmpty);
    final played = host.played.single;
    expect(played.url, media.url);
    expect(played.isLive, isTrue);
    expect(played.referer, "http://example.test");
    expect(played.userAgent, "Agent");
  });

  test("a paired phone reconnects later without a code", () async {
    server.openPairing();
    await connect();
    await client.disconnect();
    server.closePairing();
    final asked = await connect(
      askCode: (_, _) => fail("Shouldn't ask for a code"),
    );
    expect(asked, isTrue);
    expect(client.connected, isTrue);
  });

  test("a wrong code is refused and can be retried", () async {
    server.openPairing();
    final wrongFlags = <bool>[];
    final ok = await connect(
      askCode: (_, wrong) async {
        wrongFlags.add(wrong);
        return wrong ? server.pairingCode.value : "not the code";
      },
    );
    expect(ok, isTrue);
    expect(wrongFlags, [false, true]);
  });

  test("the code changes after repeated wrong guesses", () async {
    server.openPairing();
    final first = server.pairingCode.value;
    var guesses = 0;
    final ok = await connect(
      askCode: (_, _) async => ++guesses <= 5 ? "guess" : null,
    );
    expect(ok, isFalse);
    expect(guesses, 6);
    // Different unless the new random code happens to match (1 in 10000).
    expect(server.pairingCode.value, isNot(first));
    expect(tvStore.phones, isEmpty);
  });

  test("pairing fails while the TV isn't showing a code", () async {
    await expectLater(
      connect(askCode: (_, _) async => "1234"),
      throwsA(isA<RemoteConnectException>()),
    );
    expect(tvStore.phones, isEmpty);
    expect(client.active, isFalse);
  });

  test("cancelling pairing leaves the client disconnected", () async {
    server.openPairing();
    expect(await connect(askCode: (_, _) async => null), isFalse);
    expect(client.active, isFalse);
  });

  test("commands from a client that hasn't paired are ignored", () async {
    final (socket, messages) = await rawClient();
    socket.add(
      jsonEncode({
        "type": "play",
        "media": {"url": "http://evil.test", "title": "x"},
      }),
    );
    await drained(messages);
    expect(host.played, isEmpty);
  });

  test("an unknown token is denied", () async {
    final (socket, messages) = await rawClient();
    socket.add(jsonEncode({"type": "hello", "token": "made-up"}));
    expect(await messages.moveNext(), isTrue);
    expect(jsonDecode(messages.current)["type"], "denied");
    await drained(messages);
  });

  test("malformed messages close the connection", () async {
    final (socket, messages) = await rawClient();
    socket.add("not json");
    await drained(messages);
    expect(server.running, isTrue);
  });

  test("oversized messages close the connection", () async {
    final (socket, messages) = await rawClient();
    socket.add("x" * (remoteMaxMessageChars + 1));
    await drained(messages);
  });

  test("a paired phone's bad play request doesn't crash the TV", () async {
    server.openPairing();
    await connect();
    final (socket, messages) = await rawClient();
    socket.add(
      jsonEncode({"type": "hello", "token": tvStore.phones.single.token}),
    );
    expect(await messages.moveNext(), isTrue);
    socket.add(
      jsonEncode({
        "type": "play",
        "media": {"url": 5},
      }),
    );
    await drained(messages);
    expect(host.played, isEmpty);
    expect(client.connected, isTrue);
  });

  test("status from the TV reaches the phone, also after connecting", () async {
    server.openPairing();
    server.publishStatus(
      const RemoteStatus(RemotePlayerState.playing, "Already on"),
    );
    await connect();
    await until(() => client.status.value.title == "Already on");
    expect(client.status.value.state, RemotePlayerState.playing);

    server.publishStatus(const RemoteStatus(RemotePlayerState.paused, "News"));
    await until(() => client.status.value.state == RemotePlayerState.paused);
    expect(client.status.value.title, "News");
  });

  test("pause, resume and stop reach the TV", () async {
    server.openPairing();
    await connect();
    client.pause();
    client.resume();
    client.stop();
    await until(() => host.commands.length == 3);
    expect(host.commands, ["pause", "resume", "stop"]);
  });

  test("errors from the TV are shown on the phone", () async {
    final messages = <String>[];
    client.onMessage = messages.add;
    host.playError = "Open Fred TV on the TV";
    server.openPairing();
    await connect();
    await client.play(const RemoteMedia(url: "u", title: "t"));
    await until(() => messages.isNotEmpty);
    expect(messages.single, "Open Fred TV on the TV");
    // What the TV refused doesn't show as playing.
    expect(client.status.value.title, isNull);
  });

  test("reconnects by itself when the TV comes back", () async {
    server.openPairing();
    await connect();
    final port = server.boundPort;
    await server.stop();
    await until(() => client.connection.value == RemoteConnection.reconnecting);

    final revived = TvServer(
      store: tvStore,
      host: host,
      name: "Test TV",
      port: port,
    );
    await revived.start();
    addTearDown(revived.stop);
    for (var i = 0; i < 80 && !client.connected; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    expect(client.connected, isTrue);
  });

  test("a phone the TV forgot has to pair again", () async {
    final messages = <String>[];
    client.onMessage = messages.add;
    server.openPairing();
    await connect();
    await server.forgetPhones();
    for (var i = 0; i < 80 && client.active; i++) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    expect(client.active, isFalse);
    expect(phoneStore.tvs, isEmpty);
    expect(messages.single, contains("no longer knows"));
  });

  test("connecting by hand after the TV forgot the phone pairs anew", () async {
    server.openPairing();
    await connect();
    await client.disconnect();
    await server.forgetPhones();
    server.openPairing();
    expect(await connect(), isTrue);
    expect(client.connected, isTrue);
    expect(tvStore.phones.length, 1);

    await client.play(const RemoteMedia(url: "u", title: "t"));
    await until(() => host.played.isNotEmpty);
  });

  test("sources reach the TV and the result returns to the phone", () async {
    final messages = <String>[];
    client.onMessage = messages.add;
    server.openPairing();
    await connect();
    final sent = client.pushSources([
      RemoteSource.fromSource(
        Source(
          name: "Provider",
          sourceType: SourceType.xtream,
          url: "http://example.test/player_api.php",
          username: "user",
          password: "pass",
          locked: true,
        ),
      ),
      const RemoteSource(
        name: "Playlist",
        sourceType: SourceType.m3uUrl,
        url: "https://example.test/list.m3u",
      ),
    ]);
    expect(sent, isTrue);
    await until(() => messages.isNotEmpty);
    expect(messages.single, "Added 2");
    final first = host.sources.first;
    expect(first.name, "Provider");
    expect(first.sourceType, SourceType.xtream);
    expect(first.username, "user");
    expect(first.password, "pass");
    expect(first.locked, isTrue);
    expect(host.sources.last.url, "https://example.test/list.m3u");
  });

  test("a client that hasn't paired can't push sources", () async {
    final (socket, messages) = await rawClient();
    socket.add(jsonEncode({"type": "pushSources", "sources": []}));
    await drained(messages);
    expect(host.sources, isEmpty);
  });

  test("the TV refuses sources that aren't web addresses", () async {
    server.openPairing();
    await connect();
    final (socket, messages) = await rawClient();
    socket.add(
      jsonEncode({"type": "hello", "token": tvStore.phones.single.token}),
    );
    expect(await messages.moveNext(), isTrue);
    socket.add(
      jsonEncode({
        "type": "pushSources",
        "sources": [
          {
            "name": "Sneaky",
            "sourceType": "m3uUrl",
            "url": "file:///data/data/secret",
          },
        ],
      }),
    );
    await drained(messages);
    expect(host.sources, isEmpty);
    expect(server.running, isTrue);
  });

  test("local M3U files can't be sent", () {
    final file = Source(
      name: "File",
      sourceType: SourceType.m3u,
      url: "/storage/list.m3u",
    );
    final web = Source(
      name: "Web",
      sourceType: SourceType.m3uUrl,
      url: "http://example.test/list.m3u",
    );
    expect(RemoteSource.canSend(file), isFalse);
    expect(RemoteSource.canSend(web), isTrue);
    expect(
      () => RemoteSource.fromJson({
        "name": "File",
        "sourceType": "m3u",
        "url": "http://example.test/list.m3u",
      }),
      throwsFormatException,
    );
  });

  test("disconnecting on purpose stops what the TV plays", () async {
    server.openPairing();
    await connect();
    await client.stopAndDisconnect();
    await until(() => host.commands.isNotEmpty);
    expect(host.commands, ["stop"]);
    expect(client.active, isFalse);
  });

  test("a lost connection doesn't stop what the TV plays", () async {
    server.openPairing();
    await connect();
    await client.disconnect();
    await Future.delayed(const Duration(milliseconds: 100));
    expect(host.commands, isEmpty);
  });

  test("moving to another TV stops the one left behind", () async {
    server.openPairing();
    await connect();
    final other = FakeHost();
    final otherServer = TvServer(
      store: await RemoteStore.load(File("${dir.path}/other.json")),
      host: other,
      name: "Other TV",
      port: 0,
    );
    await otherServer.start();
    addTearDown(otherServer.stop);
    otherServer.openPairing();
    await client.connect(
      store: phoneStore,
      host: "127.0.0.1",
      port: otherServer.boundPort,
      phoneName: "Test phone",
      askCode: (_, _) async => otherServer.pairingCode.value,
    );
    await until(() => host.commands.isNotEmpty);
    expect(host.commands, ["stop"]);
    expect(other.commands, isEmpty);
    expect(client.tvName, "Other TV");
  });

  test("stopping while the TV can't be reached says so", () async {
    final messages = <String>[];
    client.onMessage = messages.add;
    server.openPairing();
    server.publishStatus(const RemoteStatus(RemotePlayerState.playing, "News"));
    await connect();
    await until(() => client.status.value.title == "News");
    await server.stop();
    await until(() => client.connection.value == RemoteConnection.reconnecting);
    await client.stopAndDisconnect();
    expect(client.active, isFalse);
    expect(messages.single, contains("may still be playing"));
  });

  test("pairing state survives a restart", () async {
    server.openPairing();
    await connect();
    await tvStore.save();
    await phoneStore.save();
    final tv = await RemoteStore.load(File("${dir.path}/tv.json"));
    final phone = await RemoteStore.load(File("${dir.path}/phone.json"));
    expect(tv.phones.single.token, phone.tvs.single.token);
    expect(tv.tvId, phone.tvs.single.id);
  });

  test("a damaged store file starts over", () async {
    final file = File("${dir.path}/bad.json");
    await file.writeAsString("{ nope");
    final store = await RemoteStore.load(file);
    expect(store.phones, isEmpty);
    expect(store.allowControl, isFalse);
  });
}
