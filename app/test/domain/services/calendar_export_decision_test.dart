import 'package:app/domain/services/calendar_export_decision.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('decideExportAction (§9, Calendar export)', () {
    test('not connected always means none, regardless of mode/date', () {
      expect(
        decideExportAction(
          connected: false,
          exportMode: CalendarExportMode.alwaysAdd,
          hasDate: true,
          alreadyExported: false,
          online: true,
        ),
        ExportAction.none,
      );
    });

    test('mode never always means none, regardless of connectivity', () {
      expect(
        decideExportAction(
          connected: true,
          exportMode: CalendarExportMode.never,
          hasDate: true,
          alreadyExported: false,
          online: true,
        ),
        ExportAction.none,
      );
    });

    test('no date means none', () {
      expect(
        decideExportAction(
          connected: true,
          exportMode: CalendarExportMode.alwaysAdd,
          hasDate: false,
          alreadyExported: false,
          online: true,
        ),
        ExportAction.none,
      );
    });

    test('already exported means none, even if otherwise eligible', () {
      expect(
        decideExportAction(
          connected: true,
          exportMode: CalendarExportMode.alwaysAdd,
          hasDate: true,
          alreadyExported: true,
          online: true,
        ),
        ExportAction.none,
      );
    });

    test('askEachTime + online prompts', () {
      expect(
        decideExportAction(
          connected: true,
          exportMode: CalendarExportMode.askEachTime,
          hasDate: true,
          alreadyExported: false,
          online: true,
        ),
        ExportAction.prompt,
      );
    });

    test('askEachTime + offline is none, and never fires retroactively', () {
      expect(
        decideExportAction(
          connected: true,
          exportMode: CalendarExportMode.askEachTime,
          hasDate: true,
          alreadyExported: false,
          online: false,
        ),
        ExportAction.none,
      );
    });

    test('alwaysAdd + online auto-exports, no prompt', () {
      expect(
        decideExportAction(
          connected: true,
          exportMode: CalendarExportMode.alwaysAdd,
          hasDate: true,
          alreadyExported: false,
          online: true,
        ),
        ExportAction.autoExport,
      );
    });

    test('alwaysAdd + offline queues for the background retry', () {
      expect(
        decideExportAction(
          connected: true,
          exportMode: CalendarExportMode.alwaysAdd,
          hasDate: true,
          alreadyExported: false,
          online: false,
        ),
        ExportAction.queueForLater,
      );
    });
  });
}
