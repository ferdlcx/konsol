import 'package:dartpad_mobile/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('DartPadMobileApp opens on Mobile Dashboard first', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const DartPadMobileApp());
    await tester.pump();
    expect(find.text('DartPad Dashboard'), findsOneWidget);
  });
}
