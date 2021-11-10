import 'package:onyx_lighting/onyx.dart';

void main() async {
  final onyx = Onyx(
    OnyxSettings(
      ip: '192.168.50.13',
      port: 2323,
      useTelnet: true,
    ),
  );

  onyx.sortCueListsBy = OnyxSortPreference.byNumber;
  if (await onyx.connect()) {
    print('AVAILABLE CUELISTS --- ');
    if (onyx.cueLists.isNotEmpty) onyx.cueLists.first.isFavorite = true;
    for (var cl in onyx.cueLists) {
      print(cl);
      cl.updates.listen((_) {
        print(cl);
      });
    }
  }
}
