import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';

/// Settings' profile edit (§11) — reuses the existing
/// `ProfileRepository.saveProfile()` onboarding already calls, just with
/// a Settings-reachable entry point. Returns true if saved, false if
/// cancelled.
Future<bool> showEditProfileSheet(
  BuildContext context, {
  required String firstName,
  String? lastName,
  String? avatarPath,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.colors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(context.s(24))),
    ),
    builder: (context) => _EditProfileSheet(
      firstName: firstName,
      lastName: lastName,
      avatarPath: avatarPath,
    ),
  );
  return result ?? false;
}

/// Copies the picked file into the app's own documents directory under a
/// fixed name — overwriting any previous avatar — rather than storing the
/// original picked path, which isn't guaranteed to still be readable
/// later (the source app could clear its cache, revoke access, etc.).
Future<String> _copyAvatarLocally(String pickedPath) async {
  final dir = await getApplicationDocumentsDirectory();
  final dest = File('${dir.path}/profile_avatar.img');
  await dest.writeAsBytes(await File(pickedPath).readAsBytes());
  return dest.path;
}

class _EditProfileSheet extends ConsumerStatefulWidget {
  const _EditProfileSheet({
    required this.firstName,
    this.lastName,
    this.avatarPath,
  });
  final String firstName;
  final String? lastName;
  final String? avatarPath;

  @override
  ConsumerState<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends ConsumerState<_EditProfileSheet> {
  late final _firstNameController = TextEditingController(
    text: widget.firstName,
  );
  late final _lastNameController = TextEditingController(
    text: widget.lastName ?? '',
  );
  late String? _avatarPath = widget.avatarPath;
  bool _nameError = false;

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    final pickedPath = result?.files.single.path;
    if (pickedPath == null) return;
    final localPath = await _copyAvatarLocally(pickedPath);
    if (mounted) setState(() => _avatarPath = localPath);
  }

  Future<void> _save() async {
    final firstName = _firstNameController.text.trim();
    if (firstName.isEmpty) {
      setState(() => _nameError = true);
      return;
    }
    final lastName = _lastNameController.text.trim();
    await ref
        .read(profileRepositoryProvider)
        .saveProfile(
          firstName: firstName,
          lastName: lastName.isEmpty ? null : lastName,
        );
    await ref.read(profileRepositoryProvider).setAvatarPath(_avatarPath);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: context.s(16),
        right: context.s(16),
        top: context.s(20),
        bottom:
            MediaQuery.of(context).viewInsets.bottom +
            MediaQuery.of(context).padding.bottom +
            context.s(18),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Edit profile', style: AppTypography.sectionHeader(context)),
          SizedBox(height: context.s(16)),
          Center(
            child: GestureDetector(
              onTap: _pickAvatar,
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  Container(
                    width: context.s(72),
                    height: context.s(72),
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: context.colors.ink,
                      shape: BoxShape.circle,
                    ),
                    child: _avatarPath == null
                        ? Center(
                            child: Text(
                              widget.firstName.isNotEmpty
                                  ? widget.firstName[0].toUpperCase()
                                  : '?',
                              style: TextStyle(
                                fontFamily: AppTypography.monoFamily,
                                fontSize: context.s(28),
                                fontWeight: FontWeight.w600,
                                color: context.colors.surface,
                              ),
                            ),
                          )
                        : Image.file(
                            File(_avatarPath!),
                            fit: BoxFit.cover,
                            width: context.s(72),
                            height: context.s(72),
                          ),
                  ),
                  Container(
                    width: context.s(24),
                    height: context.s(24),
                    decoration: BoxDecoration(
                      color: context.colors.accent,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: context.colors.surface,
                        width: context.s(2),
                      ),
                    ),
                    child: Icon(
                      Icons.edit,
                      size: context.s(13),
                      color: context.colors.surface,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: context.s(20)),
          Text(
            'FIRST NAME',
            style: AppTypography.monoLabel(
              context,
            ).copyWith(letterSpacing: context.s(1.2)),
          ),
          SizedBox(height: context.s(6)),
          TextField(
            controller: _firstNameController,
            style: TextStyle(
              fontSize: context.s(16),
              color: context.colors.ink,
            ),
            decoration: InputDecoration(
              border: const UnderlineInputBorder(),
              errorText: _nameError ? 'Required' : null,
            ),
          ),
          SizedBox(height: context.s(14)),
          Text(
            'LAST NAME · OPTIONAL',
            style: AppTypography.monoLabel(
              context,
            ).copyWith(letterSpacing: context.s(1.2)),
          ),
          SizedBox(height: context.s(6)),
          TextField(
            controller: _lastNameController,
            style: TextStyle(
              fontSize: context.s(16),
              color: context.colors.ink,
            ),
            decoration: const InputDecoration(border: UnderlineInputBorder()),
          ),
          SizedBox(height: context.s(20)),
          SizedBox(
            width: double.infinity,
            child: GestureDetector(
              onTap: _save,
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: context.s(48),
                decoration: BoxDecoration(
                  color: context.colors.ink,
                  borderRadius: BorderRadius.circular(context.s(15)),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Save',
                  style: AppTypography.button(
                    context,
                  ).copyWith(color: context.colors.surface),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
