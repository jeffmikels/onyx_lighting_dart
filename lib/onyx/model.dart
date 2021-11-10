import 'dart:io';
import 'dart:async';
import 'dart:convert';

// import 'package:flutter/material.dart';

const debug = false;
const _defaultHeartBeatDelay = Duration(seconds: 1);
const _defaultCommandTimeout = Duration(milliseconds: 250);

void dbg(Object? s) {
  if (debug) print(s);
}

enum OnyxMessageType { info, data }
enum OnyxConnectionStatus { disconnected, connecting, connected, failed }
enum OnyxSortPreference { byNumber, byName }

class OnyxMessage {
  late OnyxMessageType type;
  int code = 0;
  String message = ''; // like Ok
  List<String> dataLines = [];
  String dataText = '';
  String raw = ''; // will be the entire socket communication for this message

  /// onyx runs on a Windows machine, so it uses Windows line endings
  /// All responses have a minimum of three lines.

  /// There are two kinds of responses;
  /// "info" responses look like this
  /// HTTPCODE-TEXTLINE 1
  /// HTTPCODE-TEXTLINE 2
  /// HTTPCODE command sent by user if there was one
  ///
  /// for example, when a client first connects, we get:
  ///
  /// 200-*************Welcome to Onyx Manager v4.0.1010 build 0!*************
  /// 200-Type HELP for a list of available commands
  /// 200
  ///
  /// after an invalid command, we get:
  /// 400-I never heard that command before... are you sure?
  /// 400-Type HELP for a list of commands
  /// 400 hello
  ///
  /// "data" responses look like this
  /// HTTPCODE Ok
  /// response data
  /// .
  ///
  /// after qlactive, we get this:
  /// 200 Ok
  /// No Active Qlist in List
  /// .
  ///
  /// after qllist, we get this:
  /// 200 Ok
  /// 00002 - House Lights
  /// 00003 - SlimPar
  /// 00004 - LED Tape
  /// ... other items ...
  /// .
  OnyxMessage.parse(String data, void Function(String) handleLeftovers) {
    /// onyx messages have three lines terminated with \r\n
    var lines = data.split('\r\n');
    if (lines.length < 4) {
      handleLeftovers(data);
      throw const FormatException('incomplete onyx message');
    }

    // look for info packet
    if (lines.first.contains('-')) {
      type = OnyxMessageType.info;
      raw = lines.sublist(0, 3).join('\r\n');

      var lineData = lines[0].split('-');
      code = int.tryParse(lineData.first) ?? 400;
      message = lineData.sublist(1).join('-');

      lineData = lines[1].split('-');
      message += '\r\n' + lineData.sublist(1).join('-');

      // third line splits on a space
      lineData = lines[2].split(' ');
      message += '\r\n' + lineData.sublist(1).join(' ');

      handleLeftovers(lines.sublist(3).join('\r\n'));
    } else {
      // multiline messages must have a terminator
      if (!data.contains('\r\n.\r\n')) {
        handleLeftovers(data);
        throw const FormatException('incomplete onyx message');
      }

      type = OnyxMessageType.data;
      var responseData = lines.removeAt(0).split(' ');
      code = int.tryParse(responseData.first) ?? 200;
      message = responseData.sublist(1).join(' ');

      while (lines.isNotEmpty) {
        var line = lines.removeAt(0);
        if (line == '.') break;
        dataLines.add(line);
      }
      dataText = dataLines.join('\n'); // we prefer \n for newlines
      handleLeftovers(lines.join('\r\n'));
    }
  }
}

class OnyxSettings {
  String ip = '';
  int port = 2323;
  bool useTelnet = true;

  OnyxSettings({this.ip = '', this.port = 0, this.useTelnet = true});

  OnyxSettings.fromJson(Map<String, dynamic> data) {
    fromJson(data);
  }

  void fromJson(Map<String, dynamic> data) {
    ip = data['ip'] ?? '';
    port = data['port'] ?? 0;
    useTelnet = data['useTelnet'] ?? true;
  }

  Map<String, dynamic> get toJson => {
        'ip': ip,
        'port': port,
        'useTelnet': useTelnet,
      };
}

// data class for an individual cuelist
class OnyxCueList {
  Onyx parent;

  String name = '';
  int cueListNumber = 0; // these do not need to be strings! telnet accepts 0037 or 37

  bool _active = false;
  bool _transitioning = false;

  final StreamController<bool> _updateStream = StreamController.broadcast();
  Stream<bool> get updates => _updateStream.stream;

  String get fullName => '$name (CL$cueListNumber)';
  String get status => (transitioning ? 'transitioning - ' : '') + (active ? 'active' : 'not active');

  @override
  String toString() {
    return 'CueList: $fullName -- $status';
  }

  /// parses an onyx cuelist description line
  OnyxCueList.fromLine(this.parent, String line) {
    var pattern = RegExp(r'(\d{5}) - (.*)');
    var match = pattern.firstMatch(line);
    if (match != null) {
      cueListNumber = int.tryParse(match.group(1)!) ?? 0;
      name = match.group(2)!;
    } else {
      throw FormatException('Bad CueList Line: $line');
    }
  }

  OnyxCueList({required this.parent, String? name, required this.cueListNumber})
      : name = name ?? cueListNumber.toString();

  // StreamController<void> updateController;
  // Stream<void> get updates => updateController.stream;
  void notify() {
    _updateStream.add(true);
  }

  bool get active => _active;
  set active(bool b) {
    // don't update unless the value is new
    if (b == _active) return;
    _active = b;
    notify();
  }

  bool get transitioning => _transitioning;
  set transitioning(bool b) {
    // don't update unless the value is new
    if (_transitioning == b) return;
    _transitioning = b;
    notify();

    // always bump back to false after a few seconds
    if (b) Timer(const Duration(seconds: 6), () => transitioning = false);
  }

  // convenience functions to allow cuelists to
  // interact with the parent onyx instance
  bool get isFavorite => parent.favoriteCueLists.contains(this);
  set isFavorite(bool b) {
    // don't update unless we need to
    if (isFavorite == b) return;
    parent.flagCueListAsFavorite(this, b);
    notify();
  }

  Future<OnyxMessage?> trigger() async {
    transitioning = true;
    return await parent.triggerCueList(this); //sendCmd('GQL $cueListNumber');
  }

  Future<OnyxMessage?> release() async {
    transitioning = true;
    return await parent.releaseCueList(this); //sendCmd('RQL $cueListNumber');
  }

  Future<OnyxMessage?> toggle() async {
    if (active) {
      return release();
    } else {
      return trigger();
    }
  }
}

class Onyx {
  // private fields
  Socket? _socket;

  var _heartBeatDelay = _defaultHeartBeatDelay;
  var _commandTimeout = _defaultCommandTimeout;

  final StreamController<bool> _updateController = StreamController.broadcast();
  Stream<bool> get updates => _updateController.stream;

  OnyxConnectionStatus _status = OnyxConnectionStatus.disconnected;
  OnyxConnectionStatus get status => _status;
  set status(OnyxConnectionStatus s) {
    _status = s;
    _updateController.add(true);
  }

  bool get connected => _status == OnyxConnectionStatus.connected;
  bool get connecting => _status == OnyxConnectionStatus.connecting;

  StreamSubscription? _listener;
  Completer<OnyxMessage?>? _completer;
  Timer? _heartbeatTimer;
  Timer? _boostedheartbeatTimer;
  String _accumulator = '';

  // public fields
  OnyxSortPreference sortCueListsBy = OnyxSortPreference.byNumber;
  OnyxSettings settings;
  List<OnyxCueList> cueLists = []; // keep as a list for sorting
  Map<int, OnyxCueList> cueListByNumber = {};
  List<OnyxCueList> favoriteCueLists = []; // watch out for duplicate entries!

  // keep this on cuelist reloads
  Set<int> favoriteCueListNumbers = {};

  Onyx(this.settings);

  /// -- PRIVATE FUNCTIONS --
  void _notify() {
    _updateController.add(true);
  }

  /// this function completes [_completer] it with an [OnyxMessage]
  void _requestComplete(OnyxMessage? s) {
    if (_completer != null && !_completer!.isCompleted) _completer!.complete(s);
  }

  /// this function creates a completer, stores it in [_completer] and returns the future
  Future<OnyxMessage?> _expectResponse({String? timeoutMsg}) {
    _completer = Completer<OnyxMessage?>();
    var retval = _completer!.future.timeout(_commandTimeout, onTimeout: () {
      // if a message fails because of a timeout, it might be because
      // onyx sometimes replies 200 Ok without any data lines
      // when a command is recognized but improperly formed. In that case
      // we need to clear out the accumulator too
      _accumulator = '';
      dbg(timeoutMsg);
      return null;
    });
    return retval;
  }

  void _tcpDataHandler(List<int> data) {
    if (status != OnyxConnectionStatus.connected) status = OnyxConnectionStatus.connected;
    // decode the received data to a string
    var decoded = utf8.decode(data);
    dbg('SOCKET DATA ==================');
    dbg(decoded);
    dbg('END DATA =====================');
    _accumulator += decoded;
    var lines = _accumulator.split('\r\n');
    if (lines.length < 4) return;

    // grab all onyx messages from the accumulator
    while (_accumulator.isNotEmpty) {
      dbg('LOOKING FOR ONYX MESSAGE ==================');

      try {
        var remaining = '';
        var msg = OnyxMessage.parse(_accumulator, (leftovers) => remaining = leftovers);
        dbg('ONYX MESSAGE: =====================');
        dbg(msg.message);
        dbg(msg.dataLines.join('\n'));
        dbg('===================================');
        _requestComplete(msg); // we prefer \n for endlines
        _notify();
        _accumulator = remaining;
      } on FormatException {
        dbg('NO MESSAGE FOUND ==================');
        break;
      }
    }
  }

  /// -- PUBLIC FUNCTIONS THAT APPLY TO THIS INSTANCE
  Future<bool> connect() async {
    _accumulator = '';
    await close();
    status = OnyxConnectionStatus.connecting;
    try {
      var socket = await Socket.connect(
        settings.ip,
        settings.port,
        timeout: const Duration(seconds: 1),
      );
      _listener = socket.listen(_tcpDataHandler, onDone: () {
        status = OnyxConnectionStatus.disconnected;
      });
      _socket = socket;
      status = OnyxConnectionStatus.connected;
      await _expectResponse(timeoutMsg: 'connection message not received');
      await loadCueLists();
      resetHeartbeat();
      return true;
    } on SocketException catch (e) {
      dbg(e);
      status = OnyxConnectionStatus.failed;
      return false;
    }
  }

  Future close() async {
    await _listener?.cancel();
    _listener = null;
    _socket?.destroy();
    _socket = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    status = OnyxConnectionStatus.disconnected;
  }

  /// @deprecated, use close instead
  Future destroy() async {
    await close();
  }

  void stopHeartbeat() {
    _heartbeatTimer?.cancel();
  }

  void startHeartbeat() {
    _heartbeatTimer?.cancel();
    dbg('starting new heartbeat at: $_heartBeatDelay');
    _heartbeatTimer = Timer.periodic(_heartBeatDelay, (_) => doHeartbeat());
  }

  void resetHeartbeat([Duration? delay]) {
    if (delay == null) {
      _heartBeatDelay = _defaultHeartBeatDelay;
    } else {
      _heartBeatDelay = delay;
    }
    dbg('heartbeat reset to: $_heartBeatDelay');
    startHeartbeat();
  }

  void doHeartbeat() async {
    // dbg('beat');
    stopHeartbeat();
    await updateActiveCueLists();
    startHeartbeat();
  }

  /// speeds up the heartbeat for [boostSeconds] seconds
  void boostHeartbeat(int boostSeconds) {
    // restart the heartbeat
    // if the aggressive flag was called
    // we poll more frequently for a few seconds
    _boostedheartbeatTimer?.cancel();
    stopHeartbeat();
    resetHeartbeat(const Duration(milliseconds: 300));
    _boostedheartbeatTimer = Timer(Duration(seconds: boostSeconds), () => resetHeartbeat());
  }

  /// Will track this onyx cuelist as a favorite one.
  /// Favorites will persist reconnects, but they will be lost
  /// when this class instance is destroyed.
  void flagCueListAsFavorite(OnyxCueList cueList, [bool isFavorite = true]) {
    if (isFavorite) {
      favoriteCueListNumbers.add(cueList.cueListNumber);
      favoriteCueLists.add(cueList);
    } else {
      favoriteCueListNumbers.remove(cueList.cueListNumber);
      favoriteCueLists.remove(cueList);
    }
  }

  /// [andBoost] will flag the heartbeat to poll Onyx more frequently
  Future<OnyxMessage?> sendCmd(String cmd, [bool andBoost = false]) async {
    // never send an empty command
    // all other commands will receive a response
    if (cmd.trim().isEmpty) return null;

    // wait until the previous command is completed
    // THE TIMEOUT HERE IS REDUNDANT SINCE WE CREATED THE COMPLETER WITH A TIMEOUT
    // await _completer?.future.timeout(_commandTimeout, onTimeout: () {
    //   status = OnyxConnectionStatus.failed;
    //   dbg('previous completer timed out...');
    //   return 'previous completer timed out...';
    // });
    await _completer?.future;

    if (!connected) await connect();
    dbg('${DateTime.now().toIso8601String()} ONYX SEND: $cmd');

    _socket?.write(cmd + '\r\n');

    if (andBoost) boostHeartbeat(6);
    return _expectResponse(timeoutMsg: 'Sending "$cmd", command timed out...');
  }

  /// resets the cuelists, flags them as favorite if they should be, and sorts
  Future<void> loadCueLists() async {
    cueLists.clear();
    favoriteCueLists.clear();
    _notify();
    var res = await getAvailableCueLists();
    if (res == null) return;

    for (var line in res.dataLines) {
      if (line.isEmpty) continue;
      try {
        var cueList = OnyxCueList.fromLine(this, line);
        cueLists.add(cueList);
        cueListByNumber[cueList.cueListNumber] = cueList;
        if (favoriteCueListNumbers.contains(cueList.cueListNumber)) {
          favoriteCueLists.add(cueList);
        }
      } on FormatException catch (e) {
        // this cue item couldn't be parsed
        dbg(e);
        continue;
      }
    }
    if (sortCueListsBy == OnyxSortPreference.byName) {
      cueLists.sort((a, b) => a.name.compareTo(b.name));
      favoriteCueLists.sort((a, b) => a.name.compareTo(b.name));
    } else {
      cueLists.sort((a, b) => a.cueListNumber.compareTo(b.cueListNumber));
      favoriteCueLists.sort((a, b) => a.cueListNumber.compareTo(b.cueListNumber));
    }
    _notify();
  }

  /// will make sure the cuelists are populated
  /// then will ask for all the active ones
  Future<void> updateActiveCueLists() async {
    if (cueLists.isEmpty) await loadCueLists();
    if (cueLists.isEmpty) return;
    var res = await getActiveCueLists();

    // we only need the cue numbers
    List<int> foundNumbers = [];
    if (res == null) return;
    for (var line in res.dataLines) {
      if (line.isEmpty) continue;
      if (line.startsWith('No')) continue;

      dbg(line);
      try {
        var cueList = OnyxCueList.fromLine(this, line);
        if (cueList.cueListNumber == 0) continue;
        foundNumbers.add(cueList.cueListNumber);
      } on FormatException catch (e) {
        dbg(e);
        continue;
      }
    }

    for (var cueList in cueLists) {
      var isActive = foundNumbers.contains(cueList.cueListNumber);
      var wasActive = cueList.active;
      if ((isActive && !wasActive) || (!isActive && wasActive)) {
        cueList.transitioning = false;
        cueList.active = isActive;
      }
    }
    _notify();
  }

  /// =======================================================
  /// ONYX API COMMANDS START HERE
  /// These commands will return Futures for bool, string, or OnyxMessage

  /*
  ACT
  [ACT #] -Action Group =  where # is the Action Group Number
  */
  Future<OnyxMessage?> startActionGroup(String groupNumber) {
    return sendCmd('ACT $groupNumber');
  }

  /*
  ActList
  [ActList] -Will return the Maxxyz Manager Action List
  */
  Future<OnyxMessage?> getActionList() async {
    return sendCmd('ActList');
  }

  /*
  ActName
  [ActName #] -Will return the name of Maxxyz Manager Action name
  */
  Future<String> getActionName(String actionNumber) async {
    var result = await sendCmd('ActName $actionNumber');
    return result?.dataLines.first ?? '';
  }

  /*
  BYE
  [Bye] -Disconnect from server
  */
  Future<OnyxMessage?> disconnect() async {
    return sendCmd('BYE');
  }

  /*
  CLRCLR
  [CLRCLR] -Clear+Clear (clear the programmer)
  */
  Future<OnyxMessage?> clearProgrammer() async {
    return sendCmd('CLRCLR');
  }

  /*
  CMD
  [CMD #] -Internal Command where # is the Command Number
  */
  Future<OnyxMessage?> triggerCommand(String commandNumber) async {
    return sendCmd('CMD $commandNumber', true);
  }

  /*
  CmdList
  [CmdList] -Will return the Maxxyz Manager Command List
  */
  Future<OnyxMessage?> getCommandList() async {
    return sendCmd('CmdList');
  }

  /*
  CmdName
  [CmdName #] -Will return the name of Maxxyz Manager Command name #
  */
  Future<String> getCommandName(String commandNumber) async {
    var result = await sendCmd('CmdName $commandNumber');
    return result?.dataLines.first ?? '';
  }

  /*
  GQL
  [GQL #] -Go Cuelist where # is the Cuelist Number
  */
  Future<OnyxMessage?> triggerCueList(OnyxCueList cueList) async {
    // from when we called this with the cueListNumber only
    // var cue = cueLists.firstWhere(
    //   (c) => c.cueListNumber == cueListNumber,
    //   orElse: () => OnyxCueList(parent: this, cueListNumber: cueListNumber),
    // );
    // also, attempt to flag the cue as transitioning
    cueList.transitioning = true;
    return sendCmd('GQL ${cueList.cueListNumber}', true);
  }

  /*
  GSC
  [GSC #] -Go Schedule  where # is the Schedule Number (Set this schdule as default schedule)
  To return to calendar rules use the SchUseCalendar command
  */
  Future<OnyxMessage?> triggerSchedule(String scheduleNumber) async {
    return sendCmd('GSC $scheduleNumber', true);
  }

  /*
  GTQ
  [GTQ #,#] -Go to Cuelist where first # is the Cuelist Number and second # is Cue number
  */
  Future<OnyxMessage?> triggerCue(OnyxCueList cueList, int cueNumber) async {
    var result = await sendCmd('GTQ ${cueList.cueListNumber},$cueNumber', true);
    return result;
  }

  /*
  Help
  Displays commands that the servers supports.
  */
  Future<OnyxMessage?> getHelp() async {
    return sendCmd('Help');
  }

  /*
  IsMxRun
  [IsMxRun] -Will return the state of Maxxyz (Yes or No)
  */
  Future<bool> isMxRun() async {
    var result = await sendCmd('IsMxRun');
    return (result?.dataLines.first.toLowerCase() == 'yes');
  }

  /*
  IsQLActive
  [IsQLActive #] -Will return the state of Qlist # (Yes or No)
  */
  Future<bool> isCueListActive(OnyxCueList cueList) async {
    var result = await sendCmd('IsQLActive ${cueList.cueListNumber}');
    return (result?.dataLines.first.toLowerCase() == 'yes');
  }

  /*
  IsSchRun
  [IsSchRun] -Will return the Scheduler state (yes or no)
  */
  Future<bool> isSchRun() async {
    var result = await sendCmd('IsSchRun');
    return (result?.dataLines.first.toLowerCase() == 'yes');
  }

  /*
  Lastlog
  [LastLog #] -Retrun the number of specified log lines starting from the last...
  Example,  LastLog 10 will return the 10 last entry in the log.
  300 Lines max
  */
  Future<OnyxMessage?> getRecentLog(String numLines) async {
    return sendCmd('Lastlog $numLines');
  }

  /*
  PQL
  [PQL #] -Pause Cuelist where # is the Cuelist Number
  */
  Future<OnyxMessage?> pauseCueList(OnyxCueList cueList) async {
    return sendCmd('PQL ${cueList.cueListNumber}');
  }

  /*
  QLActive
  [QLActive] -Will return a list of the current active cuelist
  */
  Future<OnyxMessage?> getActiveCueLists() async {
    return sendCmd('QLActive');
  }

  /*
  QLList
  [QLList] -Will return a list of the avaialble Cuelist
  */
  Future<OnyxMessage?> getAvailableCueLists() async {
    return sendCmd('QLList');
  }

  /*
  QLName
  [QLName #] -Will return the name of Maxxyz Cuelist #
  */
  /// WARNING: DOES NOT WORK with some versions of Onyx
  /// command will probably timeout
  Future<String> getCueListName(String cueListNumber) async {
    var result = await sendCmd('QLName $cueListNumber');
    return result?.dataLines.first ?? '';
  }

  /*
  RAO
  [RAO] -Release All Override
  */
  Future<OnyxMessage?> releaseAllOverrides() async {
    return sendCmd('RAO', true);
  }

  /*
  RAQL
  [RAQL] -Release All Cuelist
  */
  Future<OnyxMessage?> releaseAllCuelists() async {
    // manually flag all as transitioning
    for (var cueList in cueLists) {
      if (cueList.active) {
        cueList.transitioning = true;
      }
    }
    return sendCmd('RAQL', true);
  }

  /*
  RAQLDF
  [RAQLDF] -Release All Cuelist Dimmer First
  */
  Future<OnyxMessage?> releaseAllCuelistsDimFirst() async {
    for (var cueList in cueLists) {
      if (cueList.active) {
        cueList.transitioning = true;
      }
    }
    return sendCmd('RAQLDF', true);
  }

  /*
  RAQLO
  [RAQLO] -Release All Cuelist and Override
  */
  Future<OnyxMessage?> releaseAllCuelistsAndOverrides() async {
    for (var cueList in cueLists) {
      if (cueList.active) {
        cueList.transitioning = true;
      }
    }
    return sendCmd('RAQLO', true);
  }

  /*
  RAQLODF
  [RAQLODF] -Release All Cuelist and Override Dimmer First
  */
  Future<OnyxMessage?> releaseAllCuelistsAndOverridesDimFirst() async {
    for (var cueList in cueLists) {
      if (cueList.active) {
        cueList.transitioning = true;
      }
    }
    return sendCmd('RAQLODF', true);
  }

  /*
  RQL
  [RQL #] -Release Cuelist where # is the Cuelist Number
  */
  Future<OnyxMessage?> releaseCueList(OnyxCueList cueList) async {
    cueList.transitioning = true;
    return sendCmd('RQL ${cueList.cueListNumber}', true);
  }

  /*
  SchList
  [SchList] -Will return the Maxxyz Manager Schedule List
  */
  Future<OnyxMessage?> getScheduleList() async {
    return sendCmd('SchList');
  }

  /*
  SchName
  [SchName #] -Will return the name of Maxxyz Manager Schedule name #
  */
  Future<String> getScheduleName(String scheduleNumber) async {
    var result = await sendCmd('SchName $scheduleNumber');
    return result?.dataLines.first ?? '';
  }

  /*
  SchUseCalendar
  Set the Scheduler to use the Calendar Rules
  */
  Future<OnyxMessage?> setSchedulerToUseCalendar() async {
    return sendCmd('SchUseCalendar');
  }

  /*
  SetDate
  Set the Remote computer date (setdate YYYY,MM,DD)
  Example setdate 2006,07,30  will set the date for  July 30 2006
  */
  Future<OnyxMessage?> setDate(String yyyy, String mm, String dd) async {
    return sendCmd('SetDate $yyyy,$mm,$dd');
  }

  /*
  SetPosDec
  Set the geographical position in decimal value (setposdec Latitude,N or S,Longitude,E or W)
  Example setposdec 45.5,N,34.3,E
  */
  Future<OnyxMessage?> setPositionDecimal(double lat, double lon) async {
    var directionLat = 'N';
    var directionLon = 'E';
    if (lat < 0) {
      directionLat = 'S';
      lat = -lat;
    }
    if (lon < 0) {
      directionLon = 'W';
      lon = -lon;
    }
    return sendCmd('SetPosDec $lat,$directionLat,$lon,$directionLon');
  }

  /*
  SetPosDMS
  Set the geographical position in degre,minute,second value (setposdms DD,MM,SS,N or S,DD,MM,SS,E or W)
  Example setposdms 45,30,00,N,34,15,00,W
  */
  // NOT IMPLEMENTED
  // Future<String> sendSetPosDMS(  ) async {
  //   var result = await send('SetPosDMS');
  //   return result;
  // }

  /*
  SetQLLevel
  [SetQLLevel #,#] -Set Cuelist level where first # is the Cuelist Number and second # is a level between 0 and 255r
  */
  Future<OnyxMessage?> setCueListLevel(OnyxCueList cueList, String level) async {
    cueList.transitioning = true;
    return sendCmd('SetQLLevel ${cueList.cueListNumber},$level');
  }

  /*
  SetTime
  Set the Remote computer time (settime HH,MM,SS) is 24 hours format
  Example settime 19,13,30  will set the time for 7:13:30 PM
  */
  Future<OnyxMessage?> setTime(String hh, String mm, String ss) async {
    return await sendCmd('SetTime $hh,$mm,$ss');
  }

  /*
  SetTimepreset
  Set the time of a Time Preset No,H,M,S (24 hours values)
  Example  timepreset 1,16,55,30  will set time preset 1 @ 4:55:30 PM
  */
  Future<OnyxMessage?> setTimePreset(String presetNumber, String hh, String mm, String ss) async {
    return sendCmd('SetTimepreset $presetNumber,$hh,$mm,$ss');
  }

  /*
  Status
  [Status] -Will return a status report
  */
  Future<OnyxMessage?> getStatus() async {
    return await sendCmd('Status');
  }

  /*
  TimePresetList
  Return a list of time preset
  */
  Future<OnyxMessage?> getTimePresets() async {
    return sendCmd('TimePresetList');
  }
}

/// This data is what Onyx Returns for CmdList
/// and is placed here for easier development
class OnyxCommandConstants {
  // SCHEDULE COMMANDS
  static const String START_SCHEDULER = "00001";
  static const String START_SCHEDULER_NO_TRACKING = "00004";
  static const String START_SCHEDULER_NO_STARTUP = "00005";
  static const String RESTART_SCHEDULER_IN = "00006";
  static const String RESTART_SCHEDULER_AT = "00007";
  static const String STOP_SCHEDULER = "00002";
  static const String USE_CALENDAR_RULES = "00003";
  static const String IGNORE_CALENDAR_RULES_FOR = "00008";
  static const String IGNORE_CALENDAR_RULES_UNTIL = "00009";
  static const String STOP_ANY_WAITING_COMMANDS = "00010";

  // GENERAL COMMANDS
  static const String RESTORE_ALL_WINDOWS = "00020";
  static const String RESTORE_ONYX_SCHEDULER_LAUNCHER = "00021";
  static const String HIDE_ALL_WINDOWS = "00022";
  static const String CLOSE_ALL_WINDOWS = "00023";
  static const String SAVE_LOG = "00025";
  static const String RESTORE_ALL_TOUCH_PANELS = "00031";
  static const String CLOSE_ALL_TOUCH_PANELS = "00032";
  static const String LOCK_ALL_TOUCH_PANELS = "00080";
  static const String UNLOCK_ALL_TOUCH_PANELS = "00081";
  static const String CLOSE_CURRENT_PANEL = "00082";
  static const String MINIMIZE_CURRENT_TOUCH_PANEL = "00083";
  static const String MINIMIZE_ALL_TOUCH_PANELS = "00087";
  static const String MAXIMIZE_ALL_TOUCH_PANELS = "00088";
  static const String RESTORE_ALL_TOUCH_PANELS_2 = "00089";
  static const String RESET_TOGGLE_CURRENT_TOUCH_PANEL = "00085";
  static const String RESET_TOGGLE_ALL_TOUCH_PANELS = "00086";

  // WINDOW CONTROLS
  static const String SHOW_ACTION_ITEMS_LIST = "00033";
  static const String CLOSE_ACTION_ITEMS_LIST = "00034";
  static const String OPEN_SCHEDULER = "00041";
  static const String CLOSE_SCHEDULER = "00042";
  static const String OPEN_CALENDAR_RULES = "00047";
  static const String CLOSE_CALENDER_RULES = "00048";
  static const String OPEN_CALENDAR_EXPLORER = "00049";
  static const String CLOSE_CALENDAR_EXPLORER = "00050";
  static const String OPEN_IMAGES_LIST = "00073";
  static const String CLOSE_IMAGES_LIST = "00074";
  static const String OPEN_COPY_BUTTON_FILTER = "00075";
  static const String CLOSE_COPY_BUTTON_FILTER = "00076";
  static const String OPEN_QUICK_PANEL = "00077";
  static const String CLOSE_QUICK_PANEL = "00078";
}
