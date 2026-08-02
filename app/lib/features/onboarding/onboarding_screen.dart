import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:home_widget/home_widget.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart' show Area;
import '../areas/area_edit_sheet.dart';

/// The three-step first-run flow (§10): profile, create areas, widget
/// prompt. Lands on the real app shell — step 4 replaced the placeholder.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  int _step = 1;
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  bool _nameError = false;

  @override
  void initState() {
    super.initState();
    // Clear the error the moment there's something to work with — only
    // shown after a failed attempt to advance, never pre-emptively.
    _firstNameController.addListener(() {
      if (_nameError && _firstNameController.text.trim().isNotEmpty) {
        setState(() => _nameError = false);
      }
    });
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    super.dispose();
  }

  /// First name is required (§10) — checked before either advancing past
  /// step 1 or finishing onboarding from it.
  bool _validateName() {
    final valid = _firstNameController.text.trim().isNotEmpty;
    setState(() => _nameError = !valid);
    return valid;
  }

  /// [homeTabIndex] lands on a specific `AppShellScreen` tab instead of the
  /// default Agenda — used by the widget-prompt step's "Find both in
  /// Settings" line, which finishes onboarding the same as "Continue"/
  /// "Skip" would, just landing on the Settings tab instead.
  Future<void> _finishOnboarding({int homeTabIndex = 0}) async {
    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    await ref
        .read(profileRepositoryProvider)
        .saveProfile(
          firstName: firstName,
          lastName: lastName.isEmpty ? null : lastName,
        );
    await ref.read(settingsRepositoryProvider).markOnboardingComplete();
    await ref.read(notificationServiceProvider).requestPermissionIfNeeded();
    if (!mounted) return;
    context.go('/home', extra: (tabIndex: homeTabIndex, upNext: false));
  }

  Future<void> _continue() async {
    if (_step == 1 && !_validateName()) return;
    if (_step == 3) {
      // Best-effort — the launcher may not support pinning, and either way
      // onboarding still finishes (§10 step 3: "the app can prompt but
      // can't place a widget itself").
      try {
        await HomeWidget.requestPinWidget(androidName: 'UpNextWidgetProvider');
      } catch (_) {
        // No supported launcher, or running where the plugin isn't wired up.
      }
      await _finishOnboarding();
      return;
    }
    setState(() => _step += 1);
  }

  /// The "skip" link's own step-1 copy isn't literally "skip," but tapping
  /// it still finishes onboarding immediately (§10) — so it needs the same
  /// name gate as "Continue" once on step 1.
  Future<void> _skip() async {
    if (_step == 1 && !_validateName()) return;
    await _finishOnboarding();
  }

  void _back() => setState(() => _step -= 1);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            context.s(24),
            context.s(20),
            context.s(24),
            0,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (_step > 1) ...[
                    GestureDetector(
                      onTap: _back,
                      child: Padding(
                        padding: EdgeInsets.only(right: context.s(12)),
                        child: Icon(
                          Icons.arrow_back,
                          size: context.s(20),
                          color: context.colors.ink,
                        ),
                      ),
                    ),
                  ],
                  Expanded(child: _ProgressBar(step: _step)),
                ],
              ),
              SizedBox(height: context.s(34)),
              Expanded(child: _buildStep()),
              _BottomActions(step: _step, onContinue: _continue, onSkip: _skip),
              SizedBox(height: context.s(26)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case 1:
        return _ProfileStep(
          firstNameController: _firstNameController,
          lastNameController: _lastNameController,
          nameError: _nameError,
        );
      case 2:
        return const _AreasStep();
      default:
        return _WidgetPromptStep(
          onGoToSettings: () => _finishOnboarding(homeTabIndex: 3),
        );
    }
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.step});
  final int step;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(3, (i) {
        final active = step >= i + 1;
        return Padding(
          padding: EdgeInsets.only(right: i < 2 ? context.s(6) : 0),
          child: Container(
            height: context.s(3),
            width: context.s(34),
            decoration: BoxDecoration(
              color: active
                  ? context.colors.accent
                  : context.colors.progressInactive,
              borderRadius: BorderRadius.circular(context.s(2)),
            ),
          ),
        );
      }),
    );
  }
}

class _ProfileStep extends StatelessWidget {
  const _ProfileStep({
    required this.firstNameController,
    required this.lastNameController,
    required this.nameError,
  });
  final TextEditingController firstNameController;
  final TextEditingController lastNameController;
  final bool nameError;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('STEP ONE', style: AppTypography.monoLabel(context)),
        SizedBox(height: context.s(12)),
        Text("Who's moving in?", style: AppTypography.headline(context)),
        SizedBox(height: context.s(12)),
        Text(
          'Stays on this device. No account, no email, no permissions.',
          style: AppTypography.body(context),
        ),
        SizedBox(height: context.s(34)),
        _UnderlineField(
          label: 'First name',
          controller: firstNameController,
          active: true,
          errorText: nameError ? 'Add a name to continue' : null,
        ),
        SizedBox(height: context.s(22)),
        _UnderlineField(
          label: 'Last name · optional',
          controller: lastNameController,
          active: false,
          hint: '—',
        ),
      ],
    );
  }
}

class _UnderlineField extends StatelessWidget {
  const _UnderlineField({
    required this.label,
    required this.controller,
    required this.active,
    this.hint,
    this.errorText,
  });
  final String label;
  final TextEditingController controller;
  final bool active;
  final String? hint;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final hasError = errorText != null;
    final borderColor = hasError
        ? context.colors.accent
        : (active ? context.colors.ink : context.colors.border);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(), style: AppTypography.monoLabel(context)),
        SizedBox(height: context.s(8)),
        TextField(
          controller: controller,
          style: TextStyle(
            fontFamily: AppTypography.sansFamily,
            fontSize: context.s(19),
            color: context.colors.ink,
          ),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: TextStyle(color: context.colors.inkDisabled),
            contentPadding: EdgeInsets.only(bottom: context.s(9)),
            border: UnderlineInputBorder(
              borderSide: BorderSide(color: borderColor, width: 1.5),
            ),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: borderColor, width: 1.5),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(
                color: hasError ? context.colors.accent : context.colors.ink,
                width: 1.5,
              ),
            ),
          ),
        ),
        if (hasError) ...[
          SizedBox(height: context.s(6)),
          Text(
            errorText!,
            style: AppTypography.secondaryMeta(
              context,
            ).copyWith(fontSize: context.s(12), color: context.colors.accent),
          ),
        ],
      ],
    );
  }
}

class _AreasStep extends ConsumerWidget {
  const _AreasStep();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final areasAsync = ref.watch(activeAreasProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Your rooms', style: AppTypography.headline(context)),
        SizedBox(height: context.s(10)),
        Text(
          'Tap one to edit it, or add your own. Nothing is locked in.',
          style: AppTypography.body(context),
        ),
        SizedBox(height: context.s(22)),
        Expanded(
          child: areasAsync.when(
            data: (areas) => ListView(
              children: [
                for (final area in areas) ...[
                  _AreaTile(area: area),
                  SizedBox(height: context.s(9)),
                ],
                const AddAreaTile(),
              ],
            ),
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}

class _AreaTile extends StatelessWidget {
  const _AreaTile({required this.area});
  final Area area;

  @override
  Widget build(BuildContext context) {
    final swatch = colorFromHex(area.color);
    return GestureDetector(
      onTap: () => showAreaEditSheet(context, existing: area),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.s(15),
          vertical: context.s(13),
        ),
        decoration: BoxDecoration(
          color: context.colors.surface,
          border: Border.all(color: context.colors.border),
          borderRadius: BorderRadius.circular(context.s(14)),
        ),
        child: Row(
          children: [
            Container(
              width: context.s(24),
              height: context.s(24),
              decoration: BoxDecoration(
                color: swatch,
                borderRadius: BorderRadius.circular(context.s(8)),
              ),
            ),
            SizedBox(width: context.s(14)),
            Expanded(
              child: Text(
                area.name,
                style: AppTypography.itemTitle(context).copyWith(
                  fontWeight: FontWeight.w500,
                  fontSize: context.s(16),
                ),
              ),
            ),
            Icon(
              Icons.edit_outlined,
              size: context.s(16),
              color: context.colors.inkFaint,
            ),
          ],
        ),
      ),
    );
  }
}

class _WidgetPromptStep extends StatelessWidget {
  const _WidgetPromptStep({required this.onGoToSettings});
  final VoidCallback onGoToSettings;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Put it on the wall', style: AppTypography.headline(context)),
          SizedBox(height: context.s(10)),
          Text(
            'Three widgets, each answering one question.',
            style: AppTypography.body(context),
          ),
          SizedBox(height: context.s(22)),
          const _WidgetPromptCard(
            title: 'Up Next',
            description: "What's closing in on me?",
            preview: _UpNextPreview(),
          ),
          SizedBox(height: context.s(11)),
          const _WidgetPromptCard(
            title: 'Agenda',
            description: "What's happening today, in order?",
            preview: _AgendaPreview(),
          ),
          SizedBox(height: context.s(11)),
          const _WidgetPromptCard(
            title: 'Areas',
            description: 'Where am I falling behind?',
            preview: _AreasPreview(),
          ),
          SizedBox(height: context.s(22)),
          // Settings breadcrumb (§10 step 3) — tapping it finishes
          // onboarding the same as "Continue"/"Skip" would, just landing
          // on the Settings tab instead of Agenda.
          GestureDetector(
            onTap: onGoToSettings,
            child: Text(
              "Want cloud backup or calendar sync later? Find both in Settings — connecting isn't required.",
              style: AppTypography.secondaryMeta(context).copyWith(
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WidgetPromptCard extends StatelessWidget {
  const _WidgetPromptCard({
    required this.title,
    required this.description,
    required this.preview,
  });
  final String title;
  final String description;
  final Widget preview;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(context.s(13)),
      decoration: BoxDecoration(
        color: context.colors.surface,
        border: Border.all(color: context.colors.border),
        borderRadius: BorderRadius.circular(context.s(14)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: context.s(60),
            height: context.s(44),
            padding: EdgeInsets.all(context.s(6)),
            decoration: BoxDecoration(
              color: context.colors.borderFaint,
              borderRadius: BorderRadius.circular(context.s(8)),
            ),
            child: preview,
          ),
          SizedBox(width: context.s(13)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTypography.itemTitle(context).copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: context.s(15),
                  ),
                ),
                SizedBox(height: context.s(3)),
                Text(
                  description,
                  style: AppTypography.secondaryMeta(
                    context,
                  ).copyWith(fontSize: context.s(12.5)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _UpNextPreview extends StatelessWidget {
  const _UpNextPreview();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [_bar(context, 0.7), _bar(context, 0.9), _bar(context, 0.55)],
    );
  }

  Widget _bar(BuildContext context, double widthFactor) {
    return Align(
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: widthFactor,
        child: Container(
          height: context.s(4),
          decoration: BoxDecoration(
            color: const Color(0xFFCFC7B8),
            borderRadius: BorderRadius.circular(context.s(2)),
          ),
        ),
      ),
    );
  }
}

class _AgendaPreview extends StatelessWidget {
  const _AgendaPreview();

  static const _colors = [
    AppColors.areaWork,
    AppColors.areaSchool,
    AppColors.areaProjects,
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [for (final c in _colors) _row(context, c)],
    );
  }

  Widget _row(BuildContext context, Color color) {
    return Row(
      children: [
        Container(
          width: context.s(10),
          height: context.s(4),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(context.s(2)),
          ),
        ),
        SizedBox(width: context.s(4)),
        Expanded(
          child: Container(
            height: context.s(4),
            decoration: BoxDecoration(
              color: const Color(0xFFCFC7B8),
              borderRadius: BorderRadius.circular(context.s(2)),
            ),
          ),
        ),
      ],
    );
  }
}

class _AreasPreview extends StatelessWidget {
  const _AreasPreview();

  static const _bars = [
    (AppColors.areaSchool, 0.60),
    (AppColors.areaWork, 0.85),
    (AppColors.areaPersonal, 0.35),
    (AppColors.areaProjects, 0.50),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final (color, heightFactor) in _bars)
              Container(
                width: context.s(6),
                height: constraints.maxHeight * heightFactor,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(context.s(2)),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _BottomActions extends StatelessWidget {
  const _BottomActions({
    required this.step,
    required this.onContinue,
    required this.onSkip,
  });
  final int step;
  final VoidCallback onContinue;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final ctaLabel = step == 3 ? 'Add to home screen' : 'Continue';
    final skipLabel = step == 1
        ? 'Everything works offline, forever'
        : step == 2
        ? "Skip — I'll add these later"
        : 'Skip for now';
    return Column(
      children: [
        GestureDetector(
          onTap: onContinue,
          child: Container(
            height: context.s(52),
            width: double.infinity,
            decoration: BoxDecoration(
              color: context.colors.ink,
              borderRadius: BorderRadius.circular(context.s(16)),
            ),
            alignment: Alignment.center,
            child: Text(
              ctaLabel,
              style: AppTypography.button(
                context,
              ).copyWith(color: context.colors.surface),
            ),
          ),
        ),
        SizedBox(height: context.s(13)),
        GestureDetector(
          onTap: onSkip,
          child: Text(
            skipLabel,
            style: AppTypography.secondaryMeta(
              context,
            ).copyWith(fontSize: context.s(13), color: context.colors.inkFaint),
          ),
        ),
      ],
    );
  }
}
