import 'package:app/app/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app boots to the splash screen', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: CoveApp()));

    expect(find.text('cove'), findsOneWidget);
    expect(find.text('EVERYTHING IN ITS PLACE'), findsOneWidget);
  });
}
