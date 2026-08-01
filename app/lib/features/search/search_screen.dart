import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart' show Area, Tag;
import '../../data/db/tables.dart' show ItemStatus;
import '../../data/repositories/item_repository.dart';
import '../../domain/services/week_math.dart';
import '../agenda/widgets/item_row.dart';
import '../item/item_detail_sheet.dart';

enum _DateFilter { all, thisWeek, thisMonth }

/// Global search with filter chips (§5) — reachable from Agenda's "FIND"
/// pill. Search runs on submit/filter-change, not live-per-keystroke; this
/// is an explicit lookup, not a reactive view like Agenda's own lists.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;

  String? _areaId;
  String? _tagId;
  ItemStatus? _status;
  _DateFilter _dateFilter = _DateFilter.all;

  List<ItemWithArea>? _results;
  bool _searched = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _runSearch);
  }

  Future<void> _runSearch() async {
    DateTime? start;
    DateTime? end;
    final now = DateTime.now();
    if (_dateFilter == _DateFilter.thisWeek) {
      final firstWeekday = await ref
          .read(settingsRepositoryProvider)
          .getFirstDayOfWeek();
      start = startOfWeek(now, firstWeekday);
      end = start.add(const Duration(days: 7));
    } else if (_dateFilter == _DateFilter.thisMonth) {
      start = DateTime(now.year, now.month);
      end = DateTime(now.year, now.month + 1);
    }

    final results = await ref
        .read(itemRepositoryProvider)
        .searchItems(
          query: _controller.text,
          areaId: _areaId,
          tagId: _tagId,
          status: _status,
          startDate: start,
          endDate: end,
        );
    if (!mounted) return;
    setState(() {
      _results = results;
      _searched = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final areas = ref.watch(activeAreasProvider).value ?? const <Area>[];
    final tags = ref.watch(allTagsProvider).value ?? const <Tag>[];

    return Scaffold(
      backgroundColor: context.colors.background,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.s(16)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: context.s(8)),
              Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Icon(
                      Icons.arrow_back,
                      size: context.s(20),
                      color: context.colors.ink,
                    ),
                  ),
                  SizedBox(width: context.s(12)),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      autofocus: true,
                      onChanged: _onQueryChanged,
                      onSubmitted: (_) => _runSearch(),
                      style: TextStyle(
                        fontFamily: AppTypography.sansFamily,
                        fontSize: context.s(15),
                        color: context.colors.ink,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Search title or notes...',
                        hintStyle: TextStyle(color: context.colors.inkDisabled),
                        border: UnderlineInputBorder(
                          borderSide: BorderSide(color: context.colors.border),
                        ),
                        enabledBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: context.colors.border),
                        ),
                        focusedBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: context.colors.ink),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: context.s(12)),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _FilterMenu<String?>(
                      label: _areaId == null
                          ? 'AREA'
                          : areas
                                .firstWhere((a) => a.id == _areaId)
                                .name
                                .toUpperCase(),
                      active: _areaId != null,
                      options: [
                        const MapEntry(null, 'All areas'),
                        for (final area in areas) MapEntry(area.id, area.name),
                      ],
                      onSelected: (v) {
                        setState(() => _areaId = v);
                        _runSearch();
                      },
                    ),
                    SizedBox(width: context.s(8)),
                    _FilterMenu<String?>(
                      label: _tagId == null
                          ? 'TAG'
                          : tags
                                .firstWhere((t) => t.id == _tagId)
                                .name
                                .toUpperCase(),
                      active: _tagId != null,
                      options: [
                        const MapEntry(null, 'All tags'),
                        for (final tag in tags) MapEntry(tag.id, tag.name),
                      ],
                      onSelected: (v) {
                        setState(() => _tagId = v);
                        _runSearch();
                      },
                    ),
                    SizedBox(width: context.s(8)),
                    _FilterMenu<ItemStatus?>(
                      label: _status?.name.toUpperCase() ?? 'STATUS',
                      active: _status != null,
                      options: [
                        const MapEntry(null, 'All statuses'),
                        for (final s in ItemStatus.values) MapEntry(s, s.name),
                      ],
                      onSelected: (v) {
                        setState(() => _status = v);
                        _runSearch();
                      },
                    ),
                    SizedBox(width: context.s(8)),
                    _FilterMenu<_DateFilter>(
                      label: switch (_dateFilter) {
                        _DateFilter.all => 'DATE',
                        _DateFilter.thisWeek => 'THIS WEEK',
                        _DateFilter.thisMonth => 'THIS MONTH',
                      },
                      active: _dateFilter != _DateFilter.all,
                      options: const [
                        MapEntry(_DateFilter.all, 'All time'),
                        MapEntry(_DateFilter.thisWeek, 'This week'),
                        MapEntry(_DateFilter.thisMonth, 'This month'),
                      ],
                      onSelected: (v) {
                        setState(() => _dateFilter = v);
                        _runSearch();
                      },
                    ),
                  ],
                ),
              ),
              SizedBox(height: context.s(12)),
              Expanded(child: _buildResults(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    if (!_searched) {
      return Center(
        child: Text(
          'Search by title, notes, or use the filters above.',
          style: AppTypography.body(context),
          textAlign: TextAlign.center,
        ),
      );
    }
    final results = _results ?? const [];
    if (results.isEmpty) {
      return Center(
        child: Text('No matches.', style: AppTypography.body(context)),
      );
    }
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (context, i) {
        final iwa = results[i];
        return ItemRow(
          itemWithArea: iwa,
          onToggle: () =>
              ref.read(itemRepositoryProvider).toggleComplete(iwa.item.id),
          onTap: () =>
              showItemDetailSheetAndMaybeExport(context, ref, iwa.item.id),
        );
      },
    );
  }
}

class _FilterMenu<T> extends StatelessWidget {
  const _FilterMenu({
    required this.label,
    required this.active,
    required this.options,
    required this.onSelected,
  });
  final String label;
  final bool active;
  final List<MapEntry<T, String>> options;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      color: context.colors.surface,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final option in options)
          PopupMenuItem(value: option.key, child: Text(option.value)),
      ],
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.s(11),
          vertical: context.s(7),
        ),
        decoration: BoxDecoration(
          color: active ? context.colors.ink : context.colors.surface,
          border: Border.all(
            color: active ? context.colors.ink : context.colors.border,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: AppTypography.monoLabel(context).copyWith(
                fontSize: context.s(10),
                color: active
                    ? context.colors.surface
                    : context.colors.inkMuted,
              ),
            ),
            SizedBox(width: context.s(4)),
            Icon(
              Icons.expand_more,
              size: context.s(14),
              color: active ? context.colors.surface : context.colors.inkMuted,
            ),
          ],
        ),
      ),
    );
  }
}
