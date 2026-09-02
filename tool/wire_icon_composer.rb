# Wire the Icon Composer bundle (Vault_icon.icon) into the Apple targets.
#
# This is the ONLY way to get iOS 26 / macOS 26's real light/dark/tinted/clear
# appearances — an asset catalog cannot express the layered glass artwork.
#
# MUST RUN AFTER flutter_launcher_icons. That tool rewrites the iOS project's
# ASSETCATALOG_COMPILER_APPICON_NAME back to "AppIcon", silently undoing this;
# the symptom is a release build whose Info.plist says AppIcon and whose icon
# has no glass/dark variants. tool/gen_icons.sh calls this last for that reason.
#
# Named Vault_icon (not AppIcon) deliberately: the generated AppIcon.appiconset
# stays on disk as the pre-26 fallback, so reverting is a one-line build-setting
# change rather than a restore.
#
# Requires: gem install --user-install xcodeproj
require 'xcodeproj'

ICON = 'Vault_icon.icon'

[
  ['ios/Runner.xcodeproj',   'Runner'],
  ['macos/Runner.xcodeproj', 'Runner'],
].each do |proj_path, target_name|
  project = Xcodeproj::Project.open(proj_path)
  target  = project.targets.find { |t| t.name == target_name }
  raise "no target #{target_name} in #{proj_path}" unless target

  group = project.main_group[target_name]
  raise "no group #{target_name} in #{proj_path}" unless group

  # Idempotent: drop any previous reference before adding a fresh one, so
  # re-running never accumulates duplicates.
  group.files.select { |f| f.path == ICON }.each do |old|
    target.resources_build_phase.files
          .select { |bf| bf.file_ref == old }
          .each(&:remove_from_project)
    old.remove_from_project
  end

  ref = group.new_reference(ICON)
  # Xcode's type for an Icon Composer document. Without it the bundle is
  # treated as a plain folder and never compiled into an icon set.
  ref.last_known_file_type = 'folder.iconcomposer.icon'
  target.resources_build_phase.add_file_reference(ref, true)

  target.build_configurations.each do |config|
    config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'Vault_icon'
  end

  project.save
  puts "#{proj_path}: #{ICON} -> APPICON_NAME=Vault_icon " \
       "(#{target.build_configurations.map(&:name).join(', ')})"
end
