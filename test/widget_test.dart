import 'package:flutter_test/flutter_test.dart';
import 'package:ui_demo/main.dart';

void main() {
  testWidgets('demo list opens the ink splash demo', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.tap(find.text('Ink Splash Theme'));
    await tester.pumpAndSettle();
    expect(find.text('Tap the icon in the top right'), findsOneWidget);
  });
}
