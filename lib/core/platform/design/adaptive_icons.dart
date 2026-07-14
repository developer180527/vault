import 'package:flutter/material.dart';

import 'design_language.dart';
import 'sf_symbol_icon.dart';

/// One semantic icon, two representations: a Material glyph and a real SF
/// Symbol *name* (rendered natively by the OS via [SfSymbolIcon] on Apple
/// platforms). Optional "selected" variants for navigation chrome.
@immutable
class AdaptiveIconData {
  const AdaptiveIconData({
    required this.material,
    required this.sfSymbol,
    IconData? materialSelected,
    String? sfSymbolSelected,
  })  : materialSelected = materialSelected ?? material,
        sfSymbolSelected = sfSymbolSelected ?? sfSymbol;

  final IconData material;
  final IconData materialSelected;

  /// SF Symbol name, e.g. 'gearshape' — the exact system glyph, not a
  /// lookalike font.
  final String sfSymbol;
  final String sfSymbolSelected;
}

/// Renders an [AdaptiveIconData] in the platform's design language: the
/// native SF Symbol on Apple platforms (with the Material glyph as its
/// loading/unknown-name fallback), the Material glyph elsewhere.
class AdaptiveIcon extends StatelessWidget {
  const AdaptiveIcon(
    this.icon, {
    super.key,
    this.selected = false,
    this.size,
    this.color,
  });

  final AdaptiveIconData icon;
  final bool selected;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final material = selected ? icon.materialSelected : icon.material;
    if (designLanguage == DesignLanguage.apple) {
      return SfSymbolIcon(
        selected ? icon.sfSymbolSelected : icon.sfSymbol,
        fallback: material,
        size: size,
        color: color,
      );
    }
    return Icon(material, size: size, color: color);
  }
}

/// The app's semantic icon catalog. Services, actions, jobs, and chrome all
/// pick from here so every concept maps to the right glyph per platform in
/// one place — nothing hand-picks platform icons at call sites.
abstract final class VaultIcons {
  // ---- Services ----
  static const media = AdaptiveIconData(
    material: Icons.tv_outlined,
    materialSelected: Icons.tv,
    sfSymbol: 'play.rectangle',
    sfSymbolSelected: 'play.rectangle.fill',
  );

  static const files = AdaptiveIconData(
    material: Icons.description_outlined,
    materialSelected: Icons.description,
    sfSymbol: 'text.document',
    sfSymbolSelected: 'text.document.fill',
  );

  static const music = AdaptiveIconData(
    material: Icons.music_note_outlined,
    materialSelected: Icons.music_note,
    sfSymbol: 'music.note', // no fill variant — same glyph when selected
  );

  static const torrent = AdaptiveIconData(
    material: Icons.public_outlined,
    materialSelected: Icons.public,
    sfSymbol: 'globe',
  );

  static const chat = AdaptiveIconData(
    material: Icons.chat_bubble_outline,
    materialSelected: Icons.chat_bubble,
    sfSymbol: 'bubble.left',
    sfSymbolSelected: 'bubble.left.fill',
  );

  static const settings = AdaptiveIconData(
    material: Icons.settings_outlined,
    materialSelected: Icons.settings,
    sfSymbol: 'gearshape',
    sfSymbolSelected: 'gearshape.fill',
  );

  static const user = AdaptiveIconData(
    material: Icons.person_outline,
    materialSelected: Icons.person,
    // Bare glyph — the dock's You slot draws its own circle around it
    // (person.crop.circle would double up the enclosure).
    sfSymbol: 'person',
    sfSymbolSelected: 'person.fill',
  );

  static const trash = AdaptiveIconData(
    material: Icons.delete_outline,
    materialSelected: Icons.delete,
    sfSymbol: 'trash',
    sfSymbolSelected: 'trash.fill',
  );

  // ---- Playback ----
  static const play = AdaptiveIconData(
    material: Icons.play_arrow,
    sfSymbol: 'play.fill',
  );

  static const pause = AdaptiveIconData(
    material: Icons.pause,
    sfSymbol: 'pause.fill',
  );

  static const skipNext = AdaptiveIconData(
    material: Icons.skip_next,
    sfSymbol: 'forward.fill',
  );

  // ---- Actions ----
  static const add = AdaptiveIconData(
    material: Icons.add,
    sfSymbol: 'plus',
  );

  static const addLink = AdaptiveIconData(
    material: Icons.add_link,
    sfSymbol: 'link.badge.plus',
  );

  static const clearFinished = AdaptiveIconData(
    material: Icons.clear_all,
    sfSymbol: 'xmark.bin',
  );

  static const newFolder = AdaptiveIconData(
    material: Icons.create_new_folder_outlined,
    sfSymbol: 'folder.badge.plus',
  );

  static const upload = AdaptiveIconData(
    material: Icons.upload_file_outlined,
    sfSymbol: 'square.and.arrow.up',
  );

  static const toggleView = AdaptiveIconData(
    material: Icons.grid_view_outlined,
    sfSymbol: 'square.grid.2x2',
  );

  static const folderOpen = AdaptiveIconData(
    material: Icons.folder_open,
    sfSymbol: 'folder',
  );

  static const photo = AdaptiveIconData(
    material: Icons.photo_outlined,
    sfSymbol: 'photo',
  );

  static const playVideo = AdaptiveIconData(
    material: Icons.play_circle_outline,
    sfSymbol: 'play.rectangle',
  );

  static const document = AdaptiveIconData(
    material: Icons.description_outlined,
    sfSymbol: 'text.document',
  );

  static const openPreview = AdaptiveIconData(
    material: Icons.open_in_new,
    sfSymbol: 'arrow.up.right.square',
  );

  static const offlineAdd = AdaptiveIconData(
    material: Icons.download_for_offline_outlined,
    sfSymbol: 'arrow.down.circle',
  );

  static const offlineRemove = AdaptiveIconData(
    material: Icons.cloud_off_outlined,
    sfSymbol: 'xmark.icloud',
  );

  static const rename = AdaptiveIconData(
    material: Icons.drive_file_rename_outline,
    sfSymbol: 'pencil',
  );

  static const search = AdaptiveIconData(
    material: Icons.search,
    sfSymbol: 'magnifyingglass',
  );

  // ---- Jobs ----
  static const jobTorrent = AdaptiveIconData(
    material: Icons.swap_vert_circle_outlined,
    sfSymbol: 'arrow.up.arrow.down.circle',
  );

  static const jobDownload = AdaptiveIconData(
    material: Icons.download_outlined,
    sfSymbol: 'arrow.down.circle',
  );

  static const jobUpload = AdaptiveIconData(
    material: Icons.upload_outlined,
    sfSymbol: 'arrow.up.circle',
  );
}
