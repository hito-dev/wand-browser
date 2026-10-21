#!/usr/bin/env ruby
# Optional maintenance tool. The generated Xcode project is checked in.
require 'xcodeproj'
require 'pathname'

root = File.expand_path('..', __dir__)
ios = File.join(root, 'ios')
project = Xcodeproj::Project.new(File.join(ios, 'WandBrowser.xcodeproj'))
project.root_object.attributes['LastUpgradeCheck'] = '2660'
app = project.new_target(:application, 'WandBrowser', :ios, '18.0')
unit = project.new_target(:unit_test_bundle, 'WandBrowserTests', :ios, '18.0')
ui = project.new_target(:ui_test_bundle, 'WandBrowserUITests', :ios, '18.0')
unit.add_dependency(app)
ui.add_dependency(app)
signing = project.main_group.new_file('Signing.xcconfig')

[[app, 'WandBrowser'], [unit, 'WandBrowserTests'], [ui, 'WandBrowserUITests']].each do |target, directory|
  group = project.main_group.new_group(directory, directory)
  Dir.glob(File.join(ios, directory, '**', '*')).sort.each do |path|
    # Asset catalogs are one compiled resource, not a collection of loose JSON/PNGs.
    next if path.include?('.xcassets/')
    next if File.directory?(path) && !path.end_with?('.xcassets')
    relative = Pathname.new(path).relative_path_from(Pathname.new(File.join(ios, directory))).to_s
    file = group.new_file(relative)
    if path.end_with?('.swift')
      target.source_build_phase.add_file_reference(file)
    elsif path.end_with?('.js', '.html', '.json', '.xcassets', '.xcprivacy', '.dat')
      target.resources_build_phase.add_file_reference(file)
    end
  end
  target.build_configurations.each do |config|
    settings = config.build_settings
    settings['SWIFT_VERSION'] = '6.0'
    settings['SWIFT_STRICT_CONCURRENCY'] = 'complete'
    settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
    settings['TARGETED_DEVICE_FAMILY'] = '1'
    settings['CODE_SIGN_STYLE'] = 'Automatic'
    # Both configurations are beta builds; Release archives are intended for TestFlight.
    settings['PRODUCT_BUNDLE_IDENTIFIER'] = target == app ? 'ai.hito.wand.dev' : "ai.hito.wand.dev.#{target.name}"
    settings['MARKETING_VERSION'] = target == app ? '0.2.3' : '0.1.0'
    settings['CURRENT_PROJECT_VERSION'] = target == app ? '5' : '4'
    settings['GENERATE_INFOPLIST_FILE'] = target == app ? 'NO' : 'YES'
    settings['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
    settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'YES'
    settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
    settings['WAND_FIXTURE_URL'] = 'https://hito-dev.github.io/wand-browser/fixtures/'
    config.base_configuration_reference = signing
    if target == app
      settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
      settings.delete('ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME')
      settings['INFOPLIST_FILE'] = 'WandBrowser/Info.plist'
      settings['CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]'] = 'WandBrowser/WandBrowser.entitlements'
    elsif target == unit
      settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/WandBrowser.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/WandBrowser'
      settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
    else
      settings['TEST_TARGET_NAME'] = 'WandBrowser'
    end
  end
end
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(unit)
scheme.add_test_target(ui)
scheme.set_launch_target(app)
scheme.test_action.should_use_launch_scheme_args_env = false
scheme.test_action.add_macro_expansion(Xcodeproj::XCScheme::BuildableReference.new(app))
scheme.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new([
  { :key => 'WAND_FIXTURE_URL', :value => '$(WAND_FIXTURE_URL)' }
])
scheme.save_as(project.path, 'WandBrowser', true)
project.save
puts project.path

# Real-device Release smoke tests must not build the @testable unit-test target.
smoke = Xcodeproj::XCScheme.new
smoke.add_build_target(app)
smoke.add_test_target(ui)
smoke.test_action.build_configuration = 'Release'
smoke.test_action.should_use_launch_scheme_args_env = false
smoke.test_action.environment_variables = Xcodeproj::XCScheme::EnvironmentVariables.new([
  { :key => 'WAND_FIXTURE_URL', :value => '$(WAND_FIXTURE_URL)' }
])
smoke.set_launch_target(app)
smoke.launch_action.build_configuration = 'Release'
smoke.save_as(project.path, 'WandBrowserReleaseSmoke', true)
