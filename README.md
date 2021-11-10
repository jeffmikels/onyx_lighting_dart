# Onyx Lighting for Dart

This package provides a Dart interface to the Onyx Lighting controller API.

Currently, only the Telnet API is supported, but an OSC implementation is in the works as well.

## Features

This package exposes the Onyx Telnet API to Dart. Here are all the functions accessible through the Onyx Telnet API (the output from sending `help` to the telnet endpoint):

```
100 {List of telnet commands (omit the brackets [ ] )
ACT
  [ACT #] -Action Group =  where # is the Action Group Number

ActList
  [ActList] -Will return the Maxxyz Manager Action List

ActName
  [ActName #] -Will return the name of Maxxyz Manager Action name

BYE
  [Bye] -Disconnect from server

CLRCLR
  [CLRCLR] -Clear+Clear (clear the programmer)

CMD
  [CMD #] -Internal Command where # is the Command Number

CmdList
  [CmdList] -Will return the Maxxyz Manager Command List

CmdName
  [CmdName #] -Will return the name of Maxxyz Manager Command name #

GQL
  [GQL #] -Go Cuelist where # is the Cuelist Number

GSC
  [GSC #] -Go Schedule  where # is the Schedule Number (Set this schdule as default schedule)
  To return to calendar rules use the SchUseCalendar command


GTQ
  [GTQ #,#] -Go to Cuelist where first # is the Cuelist Number and second # is Cue number

Help
  Displays commands that the servers supports.

IsMxRun
  [IsMxRun] -Will return the state of Maxxyz (Yes or No)

IsQLActive
  [IsQLActive #] -Will return the state of Qlist # (Yes or No)

IsSchRun
  [IsSchRun] -Will return the Scheduler state (yes or no)

Lastlog
  [LastLog #] -Retrun the number of specified log lines starting from the last...
  Example,  LastLog 10 will return the 10 last entry in the log.
  300 Lines max

PQL
  [PQL #] -Pause Cuelist where # is the Cuelist Number

QLActive
  [QLActive] -Will return a list of the current active cuelist

QLList
  [QLList] -Will return a list of the avaialble Cuelist

QLName
  [QLName #] -Will return the name of Maxxyz Cuelist #

RAO
  [RAO] -Release All Override

RAQL
  [RAQL] -Release All Cuelist

RAQLDF
  [RAQLDF] -Release All Cuelist Dimmer First

RAQLO
  [RAQLO] -Release All Cuelist and Override

RAQLODF
  [RAQLODF] -Release All Cuelist and Override Dimmer First

RQL
  [RQL #] -Release Cuelist where # is the Cuelist Number

SchList
  [SchList] -Will return the Maxxyz Manager Schedule List

SchName
  [SchName #] -Will return the name of Maxxyz Manager Schedule name #

SchUseCalendar
  Set the Scheduler to use the Calendar Rules

SetDate
  Set the Remote computer date (setdate YYYY,MM,DD)
  Example setdate 2006,07,30  will set the date for  July 30 2006

SetPosDec
  Set the geographical position in decimal value (setposdec Latitude,N or S,Longitude,E or W)
  Example setposdec 45.5,N,34.3,E

SetPosDMS
  Set the geographical position in degre,minute,second value (setposdms DD,MM,SS,N or S,DD,MM,SS,E or W)
  Example setposdms 45,30,00,N,34,15,00,W

SetQLLevel
  [SetQLLevel #,#] -Set Cuelist level where first # is the Cuelist Number and second # is a level between 0 and 255r



SetTime
  Set the Remote computer time (settime HH,MM,SS) is 24 hours format
  Example settime 19,13,30  will set the time for 7:13:30 PM

SetTimepreset
  Set the time of a Time Preset No,H,M,S (24 hours values)
  Example  timepreset 1,16,55,30  will set time preset 1 @ 4:55:30 PM



Status
  [Status] -Will return a status report

TimePresetList
  Return a list of time preset

WhoIAm
  [WhoIAm] -Will Return your IP Address used to login on that server

```

## Getting started

From within your project folder add this library to your `pubspec.yaml` file:

```
dart pub add onyx_lighting
```

or with flutter

```
flutter pub add onyx_lighting
```

## Usage

```dart
final onyx = Onyx(
	OnyxSettings(
		ip: '192.168.50.13',
		port: 2323,
		useTelnet: true,
	),
);

await onyx.connect();
if (onyx.connected) {
	onyx.sortBy = OnyxSortPreference.byNumber;
	await onyx.loadCueLists();
	print('AVAILABLE CUELISTS --- ');
	for (var cl in onyx.cueLists) {
		print(cl);
		cl.updates.listen((_) {
			print(cl);
		});
	}
}
```

Once connected, the Onyx class exposes a stream of updates that can be listened to:

```dart
onyx.updates.listen(listener);
```

Additionally, after the connection is finished, all available cue lists will be accessible through the following objects:

```dart
List<OnyxCueList> cueLists; // sorted according to the value of sortCueListsBy
Map<int, OnyxCueList> cueListsByNumber;
```

The `Onyx` class will allow you to specify favorite cue lists as well. The favorites will persist between multiple connections, but they will be destroyed when the class instance is destroyed. If you want to keep them through multiple instances of the `Onyx` class, you will need to track them separately.

I have tried to document everything well enough. Create an issue if you have questions or want to help development.

## Additional information
