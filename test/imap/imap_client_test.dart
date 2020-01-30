import 'dart:async';

import 'package:test/test.dart';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:event_bus/event_bus.dart';
import 'package:enough_mail/enough_mail.dart';
import 'mock_imap_server.dart';
import '../mock_socket.dart';

bool _isLogEnabled = false;
String imapHost, imapUser, imapPassword;
ImapClient client;
MockImapServer mockServer;
Response<List<Capability>> capResponse;
List<ImapFetchEvent> fetchEvents = <ImapFetchEvent>[];
List<int> expungedMessages = <int>[];
const String supportedMessageFlags =
    r'\Answered \Flagged \Deleted \Seen \Draft $Forwarded $social $promotion $HasAttachment $HasNoAttachment $HasChat $MDNSent';
const String supportedPermanentMessageFlags = supportedMessageFlags + r' \*';
ServerMailbox mockInbox;
Mailbox inbox;

void main() {
  setUp(() async {
    if (client != null) {
      return;
    }
    _log('setting up ImapClient tests');
    var envVars = Platform.environment;

    var imapPort = 993;
    var useRealConnection =
        (!envVars.containsKey('IMAP_USE') || envVars['IMAP_USE'] == 'true') &&
            envVars.containsKey('IMAP_HOST') &&
            envVars.containsKey('IMAP_USER') &&
            envVars.containsKey('IMAP_PASSWORD');
    if (useRealConnection) {
      if (envVars.containsKey('IMAP_LOG')) {
        _isLogEnabled = (envVars['IMAP_LOG'] == 'true');
      } else {
        _isLogEnabled = true;
      }
      imapHost = envVars['IMAP_HOST'];
      imapUser = envVars['IMAP_USER'];
      imapPassword = envVars['IMAP_PASSWORD'];
      if (envVars.containsKey('IMAP_PORT')) {
        imapPort = int.parse(envVars['IMAP_PORT']);
      }
    } else if (envVars.containsKey('IMAP_LOG')) {
      _isLogEnabled = (envVars['IMAP_LOG'] == 'true');
      //print("log-enabled: $_isLogEnabled  [IMAP_LOG=${envVars['IMAP_LOG']}]");
    }
    client = ImapClient(bus: EventBus(sync: true), isLogEnabled: _isLogEnabled);

    client.eventBus
        .on<ImapExpungeEvent>()
        .listen((e) => expungedMessages.add(e.messageSequenceId));
    client.eventBus.on<ImapFetchEvent>().listen((e) => fetchEvents.add(e));

    if (useRealConnection) {
      await client.connectToServer(imapHost, imapPort);
      capResponse = await client.login(imapUser, imapPassword);
    } else {
      var connection = MockConnection();
      client.connect(connection.socketClient);
      mockServer = MockImapServer.connect(connection.socketServer);
      client.serverInfo = ImapServerInfo();
      capResponse = await client.login('testuser', 'testpassword');
    }
    mockInbox = ServerMailbox(
        'INBOX',
        List<MailboxFlag>.from([MailboxFlag.hasChildren]),
        supportedMessageFlags,
        supportedPermanentMessageFlags);
    _log('ImapClient test setup complete');
  });

  test('ImapClient login', () async {
    _log('login result: ${capResponse.status}');
    expect(capResponse.status, ResponseStatus.OK);
    expect(capResponse.result != null, true,
        reason: 'capability response does not contain a result');
    expect(capResponse.result.isNotEmpty, true,
        reason: 'capability response does not contain a single capability');
    _log('');
    _log('Capabilities=${capResponse.result}');
    if (mockServer != null) {
      expect(capResponse.result.length, 2);
      expect(capResponse.result[0].name, 'IMAP4rev1');
      expect(capResponse.result[1].name, 'IDLE');
    }
  });

  test('ImapClient listMailboxes', () async {
    _log('');
    if (mockServer != null) {
      mockInbox.messagesExists = 256;
      mockInbox.messagesRecent = 23;
      mockInbox.firstUnseenMessageSequenceId = 21419;
      mockInbox.uidValidity = 1466002015;
      mockInbox.uidNext = 37323;
      mockInbox.highestModSequence = 110414;
      mockServer.mailboxes.clear();
      mockServer.mailboxes.add(mockInbox);
      mockServer.mailboxes.add(ServerMailbox(
          'Public',
          List<MailboxFlag>.from(
              [MailboxFlag.noSelect, MailboxFlag.hasChildren]),
          supportedMessageFlags,
          supportedPermanentMessageFlags));
      mockServer.mailboxes.add(ServerMailbox(
          'Shared',
          List<MailboxFlag>.from(
              [MailboxFlag.noSelect, MailboxFlag.hasChildren]),
          supportedMessageFlags,
          supportedPermanentMessageFlags));
    }
    var listResponse = await client.listMailboxes();
    _log('list result: ${listResponse.status}');
    expect(listResponse.status, ResponseStatus.OK,
        reason: 'expecting OK list result');
    expect(listResponse.result != null, true,
        reason: 'list response does not conatin a result');
    expect(listResponse.result.isNotEmpty, true,
        reason: 'list response does not contain a single mailbox');
    for (var box in listResponse.result) {
      _log('list mailbox: ' +
          box.name +
          (box.hasChildren ? ' with children' : ' without children') +
          (box.isUnselectable ? ' not selectable' : ' selectable'));
    }
    if (mockServer != null) {
      expect(client.serverInfo.pathSeparator, mockServer.pathSeparator,
          reason: 'different path separator than in server');
      expect(3, listResponse.result.length,
          reason: 'Set up 3 mailboxes in root');
      var box = listResponse.result[0];
      expect('INBOX', box.name);
      expect(true, box.hasChildren);
      expect(false, box.isSelected);
      expect(false, box.isUnselectable);
      box = listResponse.result[1];
      expect('Public', box.name);
      expect(true, box.hasChildren);
      expect(false, box.isSelected);
      expect(true, box.isUnselectable);
      box = listResponse.result[2];
      expect('Shared', box.name);
      expect(true, box.hasChildren);
      expect(false, box.isSelected);
      expect(true, box.isUnselectable);
    }
  });
  test('ImapClient LSUB', () async {
    _log('');
    if (mockServer != null) {
      mockServer.mailboxesSubscribed.clear();
      mockServer.mailboxesSubscribed.add(mockInbox);
      mockServer.mailboxesSubscribed.add(ServerMailbox(
          'Public',
          List<MailboxFlag>.from(
              [MailboxFlag.noSelect, MailboxFlag.hasChildren]),
          supportedMessageFlags,
          supportedPermanentMessageFlags));
    }
    var listResponse = await client.listSubscribedMailboxes();
    _log('lsub result: ' + listResponse.status.toString());
    expect(listResponse.status, ResponseStatus.OK,
        reason: 'expecting OK lsub result');
    expect(listResponse.result != null, true,
        reason: 'lsub response does not contain a result');
    expect(listResponse.result.isNotEmpty, true,
        reason: 'lsub response does not contain a single mailbox');
    for (var box in listResponse.result) {
      _log('lsub mailbox: ' +
          box.name +
          (box.hasChildren ? ' with children' : ' without children') +
          (box.isUnselectable ? ' not selectable' : ' selectable'));
    }
    if (mockServer != null) {
      expect(client.serverInfo.pathSeparator, mockServer.pathSeparator,
          reason: 'different path separator than in server');
      expect(2, listResponse.result.length,
          reason: 'Set up 2 mailboxes as subscribed');
      var box = listResponse.result[0];
      expect('INBOX', box.name);
      expect(true, box.hasChildren);
      expect(false, box.isSelected);
      expect(false, box.isUnselectable);
      box = listResponse.result[1];
      expect('Public', box.name);
      expect(true, box.hasChildren);
      expect(false, box.isSelected);
      expect(true, box.isUnselectable);
    }
  });
  test('ImapClient LIST Inbox', () async {
    _log('');
    var listResponse = await client.listMailboxes(path: 'INBOX');
    _log('INBOX result: ' + listResponse.status.toString());
    expect(listResponse.status, ResponseStatus.OK,
        reason: 'expecting OK LIST INBOX result');
    expect(listResponse.result != null, true,
        reason: 'list response does not contain a result ');
    expect(listResponse.result.length == 1, true,
        reason: 'list response does not contain exactly one result');
    for (var box in listResponse.result) {
      _log('INBOX mailbox: ' +
          box.path +
          (box.hasChildren ? ' with children' : ' without children') +
          (box.isSelected ? ' select' : ' no select'));
    }
    if (mockServer != null) {
      expect(client.serverInfo.pathSeparator, mockServer.pathSeparator,
          reason: 'different path separator than in server');
      expect(1, listResponse.result.length,
          reason: 'There can be only one INBOX');
      var box = listResponse.result[0];
      expect('INBOX', box.name);
      expect(true, box.hasChildren);
      expect(false, box.isSelected);
      expect(false, box.isUnselectable);
    }

    _log('');
    inbox = listResponse.result[0];
    var selectResponse = await client.selectMailbox(inbox);
    expect(selectResponse.status, ResponseStatus.OK,
        reason: 'expecting OK SELECT INBOX response');
    expect(selectResponse.result != null, true,
        reason: 'select response does not contain a result ');
    expect(selectResponse.result.isReadWrite, true,
        reason: 'SELECT should open INBOX in READ-WRITE ');
    expect(
        selectResponse.result.messagesExists != null &&
            selectResponse.result.messagesExists > 0,
        true,
        reason: 'expecting at least 1 mail in INBOX');
    _log(inbox.name +
        ' exist=' +
        inbox.messagesExists.toString() +
        ' recent=' +
        inbox.messagesRecent.toString() +
        ', uidValidity=' +
        inbox.uidValidity.toString());
    if (mockServer != null) {
      expect(inbox.messagesExists, 256);
      expect(inbox.messagesRecent, 23);
      expect(inbox.firstUnseenMessageSequenceId, 21419);
      expect(inbox.uidValidity, 1466002015);
      expect(inbox.uidNext, 37323);
      expect(inbox.highestModSequence, 110414);
      expect(inbox.messageFlags != null, true,
          reason: 'message flags expected');
      expect(_toString(inbox.messageFlags),
          r'\Answered \Flagged \Deleted \Seen \Draft $Forwarded $social $promotion $HasAttachment $HasNoAttachment $HasChat $MDNSent');
      expect(inbox.permanentMessageFlags != null, true,
          reason: 'permanent message flags expected');
      expect(_toString(inbox.permanentMessageFlags),
          r'\Answered \Flagged \Deleted \Seen \Draft $Forwarded $social $promotion $HasAttachment $HasNoAttachment $HasChat $MDNSent \*');
    }
  });

  test('ImapClient search', () async {
    _log('');
    if (mockServer != null) {
      mockInbox.messageSequenceIdsUnseen =
          List<int>.from([mockInbox.firstUnseenMessageSequenceId, 3423, 17, 3]);
    }
    var searchResponse = await client.searchMessages('UNSEEN');
    expect(searchResponse.status, ResponseStatus.OK);
    expect(searchResponse.result != null, true);
    expect(searchResponse.result.isNotEmpty, true);
    _log('searched messages: ' + searchResponse.result.toString());
    if (mockServer != null) {
      expect(searchResponse.result.length,
          mockInbox.messageSequenceIdsUnseen.length);
      expect(searchResponse.result[0], mockInbox.firstUnseenMessageSequenceId);
      expect(searchResponse.result[1], 3423);
      expect(searchResponse.result[2], 17);
      expect(searchResponse.result[3], 3);
    }
  });

  test('ImapClient fetch FULL', () async {
    _log('');
    var lowerIndex = math.max(inbox.messagesExists - 1, 0);
    if (mockServer != null) {
      mockServer.fetchResponses.clear();
      mockServer.fetchResponses.add(inbox.messagesExists.toString() +
          r' FETCH (FLAGS () INTERNALDATE "25-Oct-2019 16:35:31 +0200" '
              'RFC822.SIZE 15320 ENVELOPE ("Fri, 25 Oct 2019 16:35:28 +0200 (CEST)" {61}\r\n'
              'New appointment: SoW (x2) for rebranding of App & Mobile Apps'
              '(("=?UTF-8?Q?Sch=C3=B6n=2C_Rob?=" NIL "rob.schoen" "domain.com")) (("=?UTF-8?Q?Sch=C3=B6n=2C_'
              'Rob?=" NIL "rob.schoen" "domain.com")) (("=?UTF-8?Q?Sch=C3=B6n=2C_Rob?=" NIL "rob.schoen" '
              '"domain.com")) (("Alice Dev" NIL "alice.dev" "domain.com")) NIL NIL "<Appointment.59b0d625-afaf-4fc6'
              '-b845-4b0fce126730@domain.com>" "<130499090.797.1572014128349@product-gw2.domain.com>") BODY (("text" "plain" '
              '("charset" "UTF-8") NIL NIL "quoted-printable" 1289 53)("text" "html" ("charset" "UTF-8") NIL NIL "quoted-printable" '
              '7496 302) "alternative"))');
      mockServer.fetchResponses.add(lowerIndex.toString() +
          r' FETCH (FLAGS (new seen) INTERNALDATE "25-Oct-2019 17:03:12 +0200" '
              'RFC822.SIZE 20630 ENVELOPE ("Fri, 25 Oct 2019 11:02:30 -0400 (EDT)" "New appointment: Discussion and '
              'Q&A" (("Tester, Theresa" NIL "t.tester" "domain.com")) (("Tester, Theresa" NIL "t.tester" "domain.com"))'
              ' (("Tester, Theresa" NIL "t.tester" "domain.com")) (("Alice Dev" NIL "alice.dev" "domain.com"))'
              ' NIL NIL "<Appointment.963a03aa-4a81-49bf-b3a2-77e39df30ee9@domain.com>" "<1814674343.1008.1572015750561@appsuite-g'
              'w2.domain.com>") BODY (("TEXT" "PLAIN" ("CHARSET" "US-ASCII") NIL NIL "7BIT" 1152 '
              '23)("TEXT" "PLAIN" ("CHARSET" "US-ASCII" "NAME" "cc.diff")'
              '"<960723163407.20117h@cac.washington.edu>" "Compiler diff" '
              '"BASE64" 4554 73) "MIXED"))');
    }
    var fetchResponse =
        await client.fetchMessages(lowerIndex, inbox.messagesExists, 'FULL');
    expect(fetchResponse.status, ResponseStatus.OK,
        reason: 'support for FETCH FULL expected');
    if (mockServer != null) {
      expect(fetchResponse.result != null, true,
          reason: 'fetch result expected');
      expect(fetchResponse.result.length, 2);
      var message = fetchResponse.result[0];
      expect(message.sequenceId, lowerIndex + 1);
      expect(message.flags != null, true);
      expect(message.flags.length, 0);
      expect(message.internalDate, '25-Oct-2019 16:35:31 +0200');
      expect(message.size, 15320);
      expect(message.date, 'Fri, 25 Oct 2019 16:35:28 +0200 (CEST)');
      expect(message.subject,
          'New appointment: SoW (x2) for rebranding of App & Mobile Apps');
      expect(message.inReplyTo,
          '<Appointment.59b0d625-afaf-4fc6-b845-4b0fce126730@domain.com>');
      expect(message.messageId,
          '<130499090.797.1572014128349@product-gw2.domain.com>');
      expect(message.cc, null);
      expect(message.bcc, null);
      expect(message.from != null, true);
      expect(message.from.length, 1);
      expect(message.from.first.personalName, '=?UTF-8?Q?Sch=C3=B6n=2C_Rob?=');
      expect(message.from.first.sourceRoute, null);
      expect(message.from.first.mailboxName, 'rob.schoen');
      expect(message.from.first.hostName, 'domain.com');
      expect(message.sender != null, true);
      expect(message.sender.personalName, '=?UTF-8?Q?Sch=C3=B6n=2C_Rob?=');
      expect(message.sender.sourceRoute, null);
      expect(message.sender.mailboxName, 'rob.schoen');
      expect(message.sender.hostName, 'domain.com');
      expect(message.replyTo != null, true);
      expect(
          message.replyTo.first.personalName, '=?UTF-8?Q?Sch=C3=B6n=2C_Rob?=');
      expect(message.replyTo.first.sourceRoute, null);
      expect(message.replyTo.first.mailboxName, 'rob.schoen');
      expect(message.replyTo.first.hostName, 'domain.com');
      expect(message.to != null, true);
      expect(message.to.first.personalName, 'Alice Dev');
      expect(message.to.first.sourceRoute, null);
      expect(message.to.first.mailboxName, 'alice.dev');
      expect(message.to.first.hostName, 'domain.com');
      expect(message.body != null, true);
      expect(message.body.type, 'alternative');
      expect(message.body.structures != null, true);
      expect(message.body.structures.length, 2);
      expect(message.body.structures[0].type, 'text');
      expect(message.body.structures[0].subtype, 'plain');
      expect(message.body.structures[0].description, null);
      expect(message.body.structures[0].id, null);
      expect(message.body.structures[0].encoding, 'quoted-printable');
      expect(message.body.structures[0].size, 1289);
      expect(message.body.structures[0].numberOfLines, 53);
      expect(message.body.structures[0].attributes != null, true);
      expect(message.body.structures[0].attributes.length, 1);
      expect(message.body.structures[0].attributes[0].name, 'charset');
      expect(message.body.structures[0].attributes[0].value, 'UTF-8');
      expect(message.body.structures[1].type, 'text');
      expect(message.body.structures[1].subtype, 'html');
      expect(message.body.structures[1].description, null);
      expect(message.body.structures[1].id, null);
      expect(message.body.structures[1].encoding, 'quoted-printable');
      expect(message.body.structures[1].size, 7496);
      expect(message.body.structures[1].numberOfLines, 302);
      expect(message.body.structures[1].attributes != null, true);
      expect(message.body.structures[1].attributes.length, 1);
      expect(message.body.structures[1].attributes[0].name, 'charset');
      expect(message.body.structures[1].attributes[0].value, 'UTF-8');

      message = fetchResponse.result[1];
      expect(message.sequenceId, lowerIndex);
      expect(message.flags != null, true);
      expect(message.flags.length, 2);
      expect(message.flags[0], 'new');
      expect(message.flags[1], 'seen');
      expect(message.internalDate, '25-Oct-2019 17:03:12 +0200');
      expect(message.size, 20630);
      expect(message.date, 'Fri, 25 Oct 2019 11:02:30 -0400 (EDT)');
      expect(message.subject, 'New appointment: Discussion and Q&A');
      expect(message.inReplyTo,
          '<Appointment.963a03aa-4a81-49bf-b3a2-77e39df30ee9@domain.com>');
      expect(message.messageId,
          '<1814674343.1008.1572015750561@appsuite-gw2.domain.com>');
      expect(message.cc, null);
      expect(message.bcc, null);
      expect(message.from != null, true);
      expect(message.from.length, 1);
      expect(message.from.first.personalName, 'Tester, Theresa');
      expect(message.from.first.sourceRoute, null);
      expect(message.from.first.mailboxName, 't.tester');
      expect(message.from.first.hostName, 'domain.com');
      expect(message.sender != null, true);
      expect(message.sender.personalName, 'Tester, Theresa');
      expect(message.sender.sourceRoute, null);
      expect(message.sender.mailboxName, 't.tester');
      expect(message.sender.hostName, 'domain.com');
      expect(message.replyTo != null, true);
      expect(message.replyTo.first.personalName, 'Tester, Theresa');
      expect(message.replyTo.first.sourceRoute, null);
      expect(message.replyTo.first.mailboxName, 't.tester');
      expect(message.replyTo.first.hostName, 'domain.com');
      expect(message.to != null, true);
      expect(message.to.first.personalName, 'Alice Dev');
      expect(message.to.first.sourceRoute, null);
      expect(message.to.first.mailboxName, 'alice.dev');
      expect(message.to.first.hostName, 'domain.com');
      expect(message.body != null, true);
      expect(message.body.type, 'MIXED');
      expect(message.body.structures != null, true);
      expect(message.body.structures.length, 2);
      expect(message.body.structures[0].type, 'TEXT');
      expect(message.body.structures[0].subtype, 'PLAIN');
      expect(message.body.structures[0].description, null);
      expect(message.body.structures[0].id, null);
      expect(message.body.structures[0].encoding, '7BIT');
      expect(message.body.structures[0].size, 1152);
      expect(message.body.structures[0].numberOfLines, 23);
      expect(message.body.structures[0].attributes != null, true);
      expect(message.body.structures[0].attributes.length, 1);
      expect(message.body.structures[0].attributes[0].name, 'CHARSET');
      expect(message.body.structures[0].attributes[0].value, 'US-ASCII');
      expect(message.body.structures[1].type, 'TEXT');
      expect(message.body.structures[1].subtype, 'PLAIN');
      expect(message.body.structures[1].description, 'Compiler diff');
      expect(message.body.structures[1].id,
          '<960723163407.20117h@cac.washington.edu>');
      expect(message.body.structures[1].encoding, 'BASE64');
      expect(message.body.structures[1].size, 4554);
      expect(message.body.structures[1].numberOfLines, 73);
      expect(message.body.structures[1].attributes != null, true);
      expect(message.body.structures[1].attributes.length, 2);
      expect(message.body.structures[1].attributes[0].name, 'CHARSET');
      expect(message.body.structures[1].attributes[0].value, 'US-ASCII');
      expect(message.body.structures[1].attributes[1].name, 'NAME');
      expect(message.body.structures[1].attributes[1].value, 'cc.diff');
    }
  });

  test('ImapClient fetch BODY[HEADER]', () async {
    _log('');
    var lowerIndex = math.max(inbox.messagesExists - 1, 0);
    if (mockServer != null) {
      mockServer.fetchResponses.clear();
      mockServer.fetchResponses.add(inbox.messagesExists.toString() +
          ' FETCH (BODY[HEADER] {345}\r\n'
              'Date: Wed, 17 Jul 1996 02:23:25 -0700 (PDT)\r\n'
              'From: Terry Gray <gray@cac.washington.edu>\r\n'
              'Subject: IMAP4rev1 WG mtg summary and minutes\r\n'
              'To: imap@cac.washington.edu\r\n'
              'cc: minutes@CNRI.Reston.VA.US, \r\n'
              '   John Klensin <KLENSIN@MIT.EDU>\r\n'
              'Message-Id: <B27397-0100000@cac.washington.edu>\r\n'
              'MIME-Version: 1.0\r\n'
              'Content-Type: TEXT/PLAIN; CHARSET=US-ASCII\r\n'
              ')\r\n');
      mockServer.fetchResponses.add(lowerIndex.toString() +
          ' FETCH (BODY[HEADER] {319}\r\n'
              'Date: Wed, 17 Jul 2020 02:23:25 -0700 (PDT)\r\n'
              'From: COI JOY <coi@coi.me>\r\n'
              'Subject: COI\r\n'
              'To: imap@cac.washington.edu\r\n'
              'cc: minutes@CNRI.Reston.VA.US, \r\n'
              '   John Klensin <KLENSIN@MIT.EDU>\r\n'
              'Message-Id: <chat\$.B27397-0100000@cac.washington.edu>\r\n'
              'MIME-Version: 1.0\r\n'
              'Chat-Version: 1.0\r\n'
              'Content-Type: text/plan; charset="UTF-8"\r\n'
              ')\r\n');
    }
    var fetchResponse = await client.fetchMessages(
        lowerIndex, inbox.messagesExists, 'BODY[HEADER]');
    expect(fetchResponse.status, ResponseStatus.OK,
        reason: 'support for FETCH BODY[] expected');
    if (mockServer != null) {
      expect(fetchResponse.result != null, true,
          reason: 'fetch result expected');
      // for (int i=0; i<fetchResponse.result.length; i++) {
      //   print("$i: fetch body[header]:");
      //   print(fetchResponse.result[i].toString());
      // }

      expect(fetchResponse.result.length, 2);
      var message = fetchResponse.result[0];
      expect(message.sequenceId, lowerIndex + 1);
      expect(message.headers != null, true);
      expect(message.headers.length, 8);
      expect(message.getHeaderValue('From'),
          'Terry Gray <gray@cac.washington.edu>');

      message = fetchResponse.result[1];
      expect(message.sequenceId, lowerIndex);
      expect(message.headers != null, true);
      expect(message.headers.length, 9);
      expect(message.getHeaderValue('Chat-Version'), '1.0');
      expect(
          message.getHeaderValue('Content-Type'), 'text/plan; charset="UTF-8"');
    }
  });

  test('ImapClient fetch BODY.PEEK[HEADER.FIELDS (References)]', () async {
    _log('');
    var lowerIndex = math.max(inbox.messagesExists - 1, 0);
    if (mockServer != null) {
      mockServer.fetchResponses.clear();
      mockServer.fetchResponses.add(inbox.messagesExists.toString() +
          ' FETCH (BODY[HEADER.FIELDS (REFERENCES)] {50}\r\n'
              r'References: <chat$1579598212023314@russyl.com>'
              '\r\n\r\n'
              ')\r\n');
      mockServer.fetchResponses.add(lowerIndex.toString() +
          ' FETCH (BODY[HEADER.FIELDS (REFERENCES)] {2}\r\n'
              '\r\n'
              ')\r\n');
    }
    var fetchResponse = await client.fetchMessages(lowerIndex,
        inbox.messagesExists, 'BODY.PEEK[HEADER.FIELDS (REFERENCES)]');
    expect(fetchResponse.status, ResponseStatus.OK,
        reason:
            'support for FETCH BODY.PEEK[HEADER.FIELDS (REFERENCES)] expected');
    if (mockServer != null) {
      expect(fetchResponse.result != null, true,
          reason: 'fetch result expected');

      expect(fetchResponse.result.length, 2);
      var message = fetchResponse.result[0];
      expect(message.sequenceId, lowerIndex + 1);
      expect(message.headers != null, true);
      expect(message.headers.length, 1);
      expect(message.getHeaderValue('References'),
          r'<chat$1579598212023314@russyl.com>');

      message = fetchResponse.result[1];
      expect(message.sequenceId, lowerIndex);
      expect(message.headers == null, true);
      expect(message.getHeaderValue('References'), null);
      //expect(message.headers.length, 0);
      // expect(message.getHeaderValue('Chat-Version'), '1.0');
      // expect(
      //     message.getHeaderValue('Content-Type'), 'text/plan; charset="UTF-8"');
    }
  });

  test('ImapClient fetch BODY.PEEK[HEADER.FIELDS.NOT (References)]', () async {
    _log('');
    var lowerIndex = math.max(inbox.messagesExists - 1, 0);
    if (mockServer != null) {
      mockServer.fetchResponses.clear();
      mockServer.fetchResponses.add(inbox.messagesExists.toString() +
          ' FETCH (BODY[HEADER.FIELDS.NOT (REFERENCES)] {46}\r\n'
              'From: Shirley <Shirley.Jackson@domain.com>\r\n'
              '\r\n'
              ')\r\n');
      mockServer.fetchResponses.add(lowerIndex.toString() +
          ' FETCH (BODY[HEADER.FIELDS.NOT (REFERENCES)] {2}\r\n'
              '\r\n'
              ')\r\n');
    }
    var fetchResponse = await client.fetchMessages(lowerIndex,
        inbox.messagesExists, 'BODY.PEEK[HEADER.FIELDS.NOT (REFERENCES)]');
    expect(fetchResponse.status, ResponseStatus.OK,
        reason:
            'support for FETCH BODY.PEEK[HEADER.FIELDS.NOT (REFERENCES)] expected');
    if (mockServer != null) {
      expect(fetchResponse.result != null, true,
          reason: 'fetch result expected');

      expect(fetchResponse.result.length, 2);
      var message = fetchResponse.result[0];
      expect(message.sequenceId, lowerIndex + 1);
      expect(message.headers != null, true);
      expect(message.headers.length, 1);
      expect(message.getHeaderValue('From'),
          'Shirley <Shirley.Jackson@domain.com>');

      message = fetchResponse.result[1];
      expect(message.sequenceId, lowerIndex);
      expect(message.headers == null, true);
      expect(message.getHeaderValue('References'), null);
      expect(message.getHeaderValue('From'), null);
      //expect(message.headers.length, 0);
      // expect(message.getHeaderValue('Chat-Version'), '1.0');
      // expect(
      //     message.getHeaderValue('Content-Type'), 'text/plan; charset="UTF-8"');
    }
  });

  test('ImapClient fetch BODY[]', () async {
    _log('');
    var lowerIndex = math.max(inbox.messagesExists - 1, 0);
    if (mockServer != null) {
      mockServer.fetchResponses.clear();
      mockServer.fetchResponses.add(inbox.messagesExists.toString() +
          ' FETCH (BODY[] {359}\r\n'
              'Date: Wed, 17 Jul 1996 02:23:25 -0700 (PDT)\r\n'
              'From: Terry Gray <gray@cac.washington.edu>\r\n'
              'Subject: IMAP4rev1 WG mtg summary and minutes\r\n'
              'To: imap@cac.washington.edu\r\n'
              'cc: minutes@CNRI.Reston.VA.US, \r\n'
              '   John Klensin <KLENSIN@MIT.EDU>\r\n'
              'Message-Id: <B27397-0100000@cac.washington.edu>\r\n'
              'MIME-Version: 1.0\r\n'
              'Content-Type: TEXT/PLAIN; CHARSET=US-ASCII\r\n'
              '\r\n'
              'Hello Word\r\n'
              ')\r\n');
      mockServer.fetchResponses.add(lowerIndex.toString() +
          ' FETCH (BODY[] {374}\r\n'
              'Date: Wed, 17 Jul 1996 02:23:25 -0700 (PDT)\r\n'
              'From: Terry Gray <gray@cac.washington.edu>\r\n'
              'Subject: IMAP4rev1 WG mtg summary and minutes\r\n'
              'To: imap@cac.washington.edu\r\n'
              'cc: minutes@CNRI.Reston.VA.US, \r\n'
              '   John Klensin <KLENSIN@MIT.EDU>\r\n'
              'Message-Id: <B27397-0100000@cac.washington.edu>\r\n'
              'MIME-Version: 1.0\r\n'
              'Content-Type: text/plain; charset="utf-8"\r\n'
              '\r\n'
              'Welcome to Enough MailKit.\r\n'
              ')\r\n');
    }
    var fetchResponse =
        await client.fetchMessages(lowerIndex, inbox.messagesExists, 'BODY[]');
    expect(fetchResponse.status, ResponseStatus.OK,
        reason: 'support for FETCH BODY[] expected');
    if (mockServer != null) {
      expect(fetchResponse.result != null, true,
          reason: 'fetch result expected');
      expect(fetchResponse.result.length, 2);
      var message = fetchResponse.result[0];
      expect(message.sequenceId, lowerIndex + 1);
      expect(message.bodyRaw, 'Hello Word\r\n');

      message = fetchResponse.result[1];
      expect(message.sequenceId, lowerIndex);
      expect(message.bodyRaw, 'Welcome to Enough MailKit.\r\n');
      expect(message.getHeaderValue('MIME-Version'), '1.0');
      expect(message.getHeaderValue('Content-Type'),
          'text/plain; charset="utf-8"');
      //expect(message.getHeader('Content-Type').first.value, 'text/plain; charset="utf-8"');
    }
  });

  test('ImapClient fetch BODY[0]', () async {
    _log('');
    var lowerIndex = math.max(inbox.messagesExists - 1, 0);
    if (mockServer != null) {
      mockServer.fetchResponses.clear();
      mockServer.fetchResponses.add(inbox.messagesExists.toString() +
          ' FETCH (BODY[0] {12}\r\n'
              'Hello Word\r\n'
              ')\r\n');
      mockServer.fetchResponses.add(lowerIndex.toString() +
          ' FETCH (BODY[0] {28}\r\n'
              'Welcome to Enough MailKit.\r\n'
              ')\r\n');
    }
    var fetchResponse =
        await client.fetchMessages(lowerIndex, inbox.messagesExists, 'BODY[0]');
    expect(fetchResponse.status, ResponseStatus.OK,
        reason: 'support for FETCH BODY[0] expected');
    if (mockServer != null) {
      expect(fetchResponse.result != null, true,
          reason: 'fetch result expected');
      expect(fetchResponse.result.length, 2);
      var message = fetchResponse.result[0];
      expect(message.sequenceId, lowerIndex + 1);
      expect(message.getBodyPart(0), 'Hello Word\r\n');

      message = fetchResponse.result[1];
      expect(message.sequenceId, lowerIndex);
      expect(message.getBodyPart(0), 'Welcome to Enough MailKit.\r\n');
    }
  });

  test('ImapClient noop', () async {
    _log('');
    await Future.delayed(Duration(seconds: 1));
    var noopResponse = await client.noop();
    expect(noopResponse.status, ResponseStatus.OK);

    if (mockServer != null) {
      expungedMessages.clear();
      mockInbox.noopChanges = List.from([
        '2232 EXPUNGE',
        '1234 EXPUNGE',
        '23 EXISTS',
        '3 RECENT',
        r'14 FETCH (FLAGS (\Seen \Deleted))',
        r'2322 FETCH (FLAGS (\Seen $Chat))',
      ]);
      noopResponse = await client.noop();
      await Future.delayed(Duration(milliseconds: 50));
      expect(noopResponse.status, ResponseStatus.OK);
      expect(expungedMessages, List<int>.from([2232, 1234]),
          reason: 'Expunged messages should fit');
      expect(inbox.messagesExists, 23);
      expect(inbox.messagesRecent, 3);
      expect(fetchEvents.length, 2, reason: 'Expecting 2 fetch events');
      var event = fetchEvents[0];
      expect(event.messageSequenceId, 14);
      expect(event.flags, List<String>.from([r'\Seen', r'\Deleted']));
      event = fetchEvents[1];
      expect(event.messageSequenceId, 2322);
      expect(event.flags, List<String>.from([r'\Seen', r'$Chat']));
    }
  });

  test('ImapClient idle', () async {
    _log('');
    expungedMessages.clear();
    var idleResponseFuture = client.idleStart();

    if (mockServer != null) {
      mockInbox.messagesExists += 4;
      mockServer.fire(Duration(milliseconds: 100),
          '* 2 EXPUNGE\r\n* 17 EXPUNGE\r\n* ${mockInbox.messagesExists} EXISTS\r\n');
    }
    await Future.delayed(Duration(milliseconds: 200));
    await client.idleDone();
    var idleResponse = await idleResponseFuture;
    expect(idleResponse.status, ResponseStatus.OK);
    if (mockServer != null) {
      expect(expungedMessages.length, 2);
      expect(expungedMessages[0], 2);
      expect(expungedMessages[1], 17);
      expect(inbox.messagesExists, mockInbox.messagesExists);
    }

    //expect(doneResponse.status, ResponseStatus.OK);
  });

  test('ImapClient close', () async {
    _log('');
    var closeResponse = await client.closeMailbox();
    expect(closeResponse.status, ResponseStatus.OK);
  });

  test('ImapClient logout', () async {
    _log('');
    var logoutResponse = await client.logout();
    expect(logoutResponse.status, ResponseStatus.OK);

    //await Future.delayed(Duration(seconds: 1));
    client.close();
    _log('done connecting');
    client = null;
  });
}

void _log(String text) {
  if (_isLogEnabled) {
    print(text);
  }
}

String _toString(List elements, [String separator = ' ']) {
  var buffer = StringBuffer();
  var addSeparator = false;
  for (var element in elements) {
    if (addSeparator) {
      buffer.write(separator);
    }
    buffer.write(element);
    addSeparator = true;
  }
  return buffer.toString();
}
