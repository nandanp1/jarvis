#!/usr/bin/env node

/*
 * Deterministically regenerates Jarvis.xcodeproj from the checked-in source tree.
 * It intentionally has no third-party dependencies so the project can be repaired
 * from Linux as well as macOS. Normal development does not require running it.
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const root = path.resolve(__dirname, '..');
const projectDirectory = path.join(root, 'Jarvis.xcodeproj');
const projectFile = path.join(projectDirectory, 'project.pbxproj');
const schemeDirectory = path.join(projectDirectory, 'xcshareddata', 'xcschemes');

function id(label) {
  return crypto.createHash('sha1').update(`jarvis:${label}`).digest('hex').slice(0, 24).toUpperCase();
}

function listSwiftFiles(directory) {
  if (!fs.existsSync(directory)) return [];
  return fs.readdirSync(directory, { withFileTypes: true })
    .flatMap((entry) => {
      const full = path.join(directory, entry.name);
      return entry.isDirectory() ? listSwiftFiles(full) : (entry.name.endsWith('.swift') ? [full] : []);
    })
    .map((file) => path.relative(root, file).replaceAll(path.sep, '/'))
    .sort();
}

const appFiles = listSwiftFiles(path.join(root, 'Jarvis'));
const testFiles = listSwiftFiles(path.join(root, 'JarvisTests'));
const allFiles = [...appFiles, ...testFiles];
const frameworks = ['AppKit.framework', 'AVFoundation.framework', 'Speech.framework', 'Security.framework', 'IOKit.framework', 'Network.framework', 'QuartzCore.framework'];
const testFrameworkNames = ['XCTest.framework'];

const ref = (file) => id(`fileref:${file}`);
const build = (file) => id(`build:${file}`);
const pathInGroup = (file) => file.startsWith('JarvisTests/')
  ? file.slice('JarvisTests/'.length)
  : file.slice('Jarvis/'.length);

const appTarget = id('target:Jarvis');
const testTarget = id('target:JarvisTests');
const project = id('project:Jarvis');
const mainGroup = id('group:main');
const sourceGroup = id('group:Jarvis');
const testGroup = id('group:JarvisTests');
const resourcesGroup = id('group:Resources');
const frameworksGroup = id('group:Frameworks');
const productsGroup = id('group:Products');
const appProduct = id('product:Jarvis.app');
const testProduct = id('product:JarvisTests.xctest');
const appSources = id('phase:Jarvis:sources');
const appResources = id('phase:Jarvis:resources');
const appFrameworks = id('phase:Jarvis:frameworks');
const testSources = id('phase:JarvisTests:sources');
const testFrameworks = id('phase:JarvisTests:frameworks');
const testResources = id('phase:JarvisTests:resources');
const proxy = id('proxy:JarvisTests:Jarvis');
const dependency = id('dependency:JarvisTests:Jarvis');

function settings(entries, indent = '\t\t\t\t') {
  return Object.entries(entries).map(([key, value]) => `${indent}${key} = ${value};`).join('\n');
}

const fileRefs = allFiles.map((file) => `\t\t${ref(file)} /* ${path.basename(file)} */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ${JSON.stringify(pathInGroup(file))}; sourceTree = "<group>"; };`).join('\n');
const buildRefs = allFiles.map((file) => `\t\t${build(file)} /* ${path.basename(file)} in Sources */ = {isa = PBXBuildFile; fileRef = ${ref(file)} /* ${path.basename(file)} */; };`).join('\n');
const frameworkFileRefs = frameworks.map((name) => `\t\t${ref(name)} /* ${name} */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = ${name}; path = System/Library/Frameworks/${name}; sourceTree = SDKROOT; };`).join('\n');
const frameworkBuildRefs = frameworks.map((name) => `\t\t${build(name)} /* ${name} in Frameworks */ = {isa = PBXBuildFile; fileRef = ${ref(name)} /* ${name} */; };`).join('\n');
const testFrameworkFileRefs = testFrameworkNames.map((name) => `\t\t${ref(name)} /* ${name} */ = {isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = ${name}; path = Platforms/MacOSX.platform/Developer/Library/Frameworks/${name}; sourceTree = DEVELOPER_DIR; };`).join('\n');
const testFrameworkBuildRefs = testFrameworkNames.map((name) => `\t\t${build(`test:${name}`)} /* ${name} in Frameworks */ = {isa = PBXBuildFile; fileRef = ${ref(name)} /* ${name} */; };`).join('\n');

const appChildren = appFiles.map((file) => `\t\t\t\t${ref(file)} /* ${path.basename(file)} */,`).join('\n');
const testChildren = testFiles.map((file) => `\t\t\t\t${ref(file)} /* ${path.basename(file)} */,`).join('\n');
const frameworkChildren = frameworks.map((name) => `\t\t\t\t${ref(name)} /* ${name} */,`).join('\n');
const testFrameworkChildren = testFrameworkNames.map((name) => `\t\t\t\t${ref(name)} /* ${name} */,`).join('\n');
const appSourceBuilds = appFiles.map((file) => `\t\t\t\t${build(file)} /* ${path.basename(file)} in Sources */,`).join('\n');
const testSourceBuilds = testFiles.map((file) => `\t\t\t\t${build(file)} /* ${path.basename(file)} in Sources */,`).join('\n');
const frameworkBuilds = frameworks.map((name) => `\t\t\t\t${build(name)} /* ${name} in Frameworks */,`).join('\n');
const testFrameworkBuilds = testFrameworkNames.map((name) => `\t\t\t\t${build(`test:${name}`)} /* ${name} in Frameworks */,`).join('\n');

const projectDebug = id('config:project:Debug');
const projectRelease = id('config:project:Release');
const appDebug = id('config:app:Debug');
const appRelease = id('config:app:Release');
const testDebug = id('config:test:Debug');
const testRelease = id('config:test:Release');
const projectConfigList = id('configlist:project');
const appConfigList = id('configlist:app');
const testConfigList = id('configlist:test');

const pbxproj = `// !$*UTF8*$!
{
\tarchiveVersion = 1;
\tclasses = {};
\tobjectVersion = 54;
\tobjects = {

/* Begin PBXBuildFile section */
${buildRefs}
${frameworkBuildRefs}
${testFrameworkBuildRefs}
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
\t\t${proxy} /* PBXContainerItemProxy */ = {isa = PBXContainerItemProxy; containerPortal = ${project} /* Project object */; proxyType = 1; remoteGlobalIDString = ${appTarget}; remoteInfo = Jarvis; };
/* End PBXContainerItemProxy section */

/* Begin PBXFileReference section */
${fileRefs}
${frameworkFileRefs}
${testFrameworkFileRefs}
\t\t${ref('Info.plist')} /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; name = Info.plist; path = Jarvis/Resources/Info.plist; sourceTree = SOURCE_ROOT; };
\t\t${ref('Jarvis.entitlements')} /* Jarvis.entitlements */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; name = Jarvis.entitlements; path = Jarvis/Resources/Jarvis.entitlements; sourceTree = SOURCE_ROOT; };
\t\t${ref('TestInfo.plist')} /* TestInfo.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; name = TestInfo.plist; path = JarvisTests/TestInfo.plist; sourceTree = SOURCE_ROOT; };
\t\t${appProduct} /* Jarvis.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Jarvis.app; sourceTree = BUILT_PRODUCTS_DIR; };
\t\t${testProduct} /* JarvisTests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = JarvisTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
\t\t${appFrameworks} /* Frameworks */ = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (\n${frameworkBuilds}\n\t\t\t); runOnlyForDeploymentPostprocessing = 0; };
\t\t${testFrameworks} /* Frameworks */ = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (\n${testFrameworkBuilds}\n\t\t\t); runOnlyForDeploymentPostprocessing = 0; };
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
\t\t${mainGroup} = {isa = PBXGroup; children = (${sourceGroup} /* Jarvis */, ${testGroup} /* JarvisTests */, ${resourcesGroup} /* Configuration */, ${frameworksGroup} /* Frameworks */, ${productsGroup} /* Products */,); sourceTree = "<group>"; };
\t\t${sourceGroup} /* Jarvis */ = {isa = PBXGroup; children = (\n${appChildren}\n\t\t\t); name = Jarvis; path = Jarvis; sourceTree = "<group>"; };
\t\t${testGroup} /* JarvisTests */ = {isa = PBXGroup; children = (\n${testChildren}\n\t\t\t); name = JarvisTests; path = JarvisTests; sourceTree = "<group>"; };
\t\t${resourcesGroup} /* Configuration */ = {isa = PBXGroup; children = (${ref('Info.plist')} /* Info.plist */, ${ref('Jarvis.entitlements')} /* Jarvis.entitlements */, ${ref('TestInfo.plist')} /* TestInfo.plist */,); name = Configuration; sourceTree = "<group>"; };
\t\t${frameworksGroup} /* Frameworks */ = {isa = PBXGroup; children = (\n${frameworkChildren}\n${testFrameworkChildren}\n\t\t\t); name = Frameworks; sourceTree = "<group>"; };
\t\t${productsGroup} /* Products */ = {isa = PBXGroup; children = (${appProduct} /* Jarvis.app */, ${testProduct} /* JarvisTests.xctest */,); name = Products; sourceTree = "<group>"; };
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t${appTarget} /* Jarvis */ = {isa = PBXNativeTarget; buildConfigurationList = ${appConfigList} /* Build configuration list for PBXNativeTarget \"Jarvis\" */; buildPhases = (${appSources} /* Sources */, ${appFrameworks} /* Frameworks */, ${appResources} /* Resources */,); buildRules = (); dependencies = (); name = Jarvis; productName = Jarvis; productReference = ${appProduct} /* Jarvis.app */; productType = "com.apple.product-type.application"; };
\t\t${testTarget} /* JarvisTests */ = {isa = PBXNativeTarget; buildConfigurationList = ${testConfigList} /* Build configuration list for PBXNativeTarget \"JarvisTests\" */; buildPhases = (${testSources} /* Sources */, ${testFrameworks} /* Frameworks */, ${testResources} /* Resources */,); buildRules = (); dependencies = (${dependency} /* PBXTargetDependency */,); name = JarvisTests; productName = JarvisTests; productReference = ${testProduct} /* JarvisTests.xctest */; productType = "com.apple.product-type.bundle.unit-test"; };
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t${project} /* Project object */ = {isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 1320; LastUpgradeCheck = 1320; TargetAttributes = {${appTarget} = {CreatedOnToolsVersion = 13.2;}; ${testTarget} = {CreatedOnToolsVersion = 13.2; TestTargetID = ${appTarget};};};}; buildConfigurationList = ${projectConfigList} /* Build configuration list for PBXProject \"Jarvis\" */; compatibilityVersion = "Xcode 12.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base,); mainGroup = ${mainGroup}; productRefGroup = ${productsGroup} /* Products */; projectDirPath = ""; projectRoot = ""; targets = (${appTarget} /* Jarvis */, ${testTarget} /* JarvisTests */,); };
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t${appResources} /* Resources */ = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
\t\t${testResources} /* Resources */ = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t${appSources} /* Sources */ = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (\n${appSourceBuilds}\n\t\t\t); runOnlyForDeploymentPostprocessing = 0; };
\t\t${testSources} /* Sources */ = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (\n${testSourceBuilds}\n\t\t\t); runOnlyForDeploymentPostprocessing = 0; };
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
\t\t${dependency} /* PBXTargetDependency */ = {isa = PBXTargetDependency; target = ${appTarget} /* Jarvis */; targetProxy = ${proxy} /* PBXContainerItemProxy */; };
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
\t\t${projectDebug} /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {\n${settings({ALWAYS_SEARCH_USER_PATHS: 'NO', CLANG_ENABLE_MODULES: 'YES', CLANG_ENABLE_OBJC_ARC: 'YES', COPY_PHASE_STRIP: 'NO', DEBUG_INFORMATION_FORMAT: 'dwarf', ENABLE_TESTABILITY: 'YES', GCC_C_LANGUAGE_STANDARD: 'gnu11', GCC_OPTIMIZATION_LEVEL: '0', MACOSX_DEPLOYMENT_TARGET: '11.0', ONLY_ACTIVE_ARCH: 'YES', SDKROOT: 'macosx', SWIFT_ACTIVE_COMPILATION_CONDITIONS: 'DEBUG', SWIFT_OPTIMIZATION_LEVEL: '"-Onone"', SWIFT_VERSION: '5.0'})}\n\t\t\t}; name = Debug; };
\t\t${projectRelease} /* Release */ = {isa = XCBuildConfiguration; buildSettings = {\n${settings({ALWAYS_SEARCH_USER_PATHS: 'NO', CLANG_ENABLE_MODULES: 'YES', CLANG_ENABLE_OBJC_ARC: 'YES', COPY_PHASE_STRIP: 'NO', DEBUG_INFORMATION_FORMAT: '"dwarf-with-dsym"', ENABLE_NS_ASSERTIONS: 'NO', GCC_C_LANGUAGE_STANDARD: 'gnu11', MACOSX_DEPLOYMENT_TARGET: '11.0', SDKROOT: 'macosx', SWIFT_COMPILATION_MODE: 'wholemodule', SWIFT_OPTIMIZATION_LEVEL: '"-O"', SWIFT_VERSION: '5.0'})}\n\t\t\t}; name = Release; };
\t\t${appDebug} /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {\n${settings({CODE_SIGN_ENTITLEMENTS: 'Jarvis/Resources/Jarvis.entitlements', CODE_SIGN_STYLE: 'Automatic', COMBINE_HIDPI_IMAGES: 'YES', ENABLE_HARDENED_RUNTIME: 'YES', GENERATE_INFOPLIST_FILE: 'NO', INFOPLIST_FILE: 'Jarvis/Resources/Info.plist', LD_RUNPATH_SEARCH_PATHS: '"$(inherited) @executable_path/../Frameworks"', PRODUCT_BUNDLE_IDENTIFIER: 'com.nandan.jarvis', PRODUCT_NAME: '"$(TARGET_NAME)"'})}\n\t\t\t}; name = Debug; };
\t\t${appRelease} /* Release */ = {isa = XCBuildConfiguration; buildSettings = {\n${settings({CODE_SIGN_ENTITLEMENTS: 'Jarvis/Resources/Jarvis.entitlements', CODE_SIGN_STYLE: 'Automatic', COMBINE_HIDPI_IMAGES: 'YES', ENABLE_HARDENED_RUNTIME: 'YES', GENERATE_INFOPLIST_FILE: 'NO', INFOPLIST_FILE: 'Jarvis/Resources/Info.plist', LD_RUNPATH_SEARCH_PATHS: '"$(inherited) @executable_path/../Frameworks"', PRODUCT_BUNDLE_IDENTIFIER: 'com.nandan.jarvis', PRODUCT_NAME: '"$(TARGET_NAME)"'})}\n\t\t\t}; name = Release; };
\t\t${testDebug} /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {\n${settings({BUNDLE_LOADER: '"$(TEST_HOST)"', CODE_SIGN_STYLE: 'Automatic', INFOPLIST_FILE: 'JarvisTests/TestInfo.plist', MACOSX_DEPLOYMENT_TARGET: '11.0', PRODUCT_BUNDLE_IDENTIFIER: 'com.nandan.jarvis.tests', PRODUCT_NAME: '"$(TARGET_NAME)"', SWIFT_VERSION: '5.0', TEST_HOST: '"$(BUILT_PRODUCTS_DIR)/Jarvis.app/Contents/MacOS/Jarvis"'})}\n\t\t\t}; name = Debug; };
\t\t${testRelease} /* Release */ = {isa = XCBuildConfiguration; buildSettings = {\n${settings({BUNDLE_LOADER: '"$(TEST_HOST)"', CODE_SIGN_STYLE: 'Automatic', INFOPLIST_FILE: 'JarvisTests/TestInfo.plist', MACOSX_DEPLOYMENT_TARGET: '11.0', PRODUCT_BUNDLE_IDENTIFIER: 'com.nandan.jarvis.tests', PRODUCT_NAME: '"$(TARGET_NAME)"', SWIFT_VERSION: '5.0', TEST_HOST: '"$(BUILT_PRODUCTS_DIR)/Jarvis.app/Contents/MacOS/Jarvis"'})}\n\t\t\t}; name = Release; };
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t${projectConfigList} /* Build configuration list for PBXProject \"Jarvis\" */ = {isa = XCConfigurationList; buildConfigurations = (${projectDebug} /* Debug */, ${projectRelease} /* Release */,); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
\t\t${appConfigList} /* Build configuration list for PBXNativeTarget \"Jarvis\" */ = {isa = XCConfigurationList; buildConfigurations = (${appDebug} /* Debug */, ${appRelease} /* Release */,); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
\t\t${testConfigList} /* Build configuration list for PBXNativeTarget \"JarvisTests\" */ = {isa = XCConfigurationList; buildConfigurations = (${testDebug} /* Debug */, ${testRelease} /* Release */,); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
/* End XCConfigurationList section */
\t};
\trootObject = ${project} /* Project object */;
}
`;

const scheme = `<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1320" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${appTarget}" BuildableName="Jarvis.app" BlueprintName="Jarvis" ReferencedContainer="container:Jarvis.xcodeproj"/>
      </BuildActionEntry>
      <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${testTarget}" BuildableName="JarvisTests.xctest" BlueprintName="JarvisTests" ReferencedContainer="container:Jarvis.xcodeproj"/>
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${testTarget}" BuildableName="JarvisTests.xctest" BlueprintName="JarvisTests" ReferencedContainer="container:Jarvis.xcodeproj"/></TestableReference></Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${appTarget}" BuildableName="Jarvis.app" BlueprintName="Jarvis" ReferencedContainer="container:Jarvis.xcodeproj"/></BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${appTarget}" BuildableName="Jarvis.app" BlueprintName="Jarvis" ReferencedContainer="container:Jarvis.xcodeproj"/></BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
`;

fs.mkdirSync(projectDirectory, { recursive: true });
fs.mkdirSync(schemeDirectory, { recursive: true });
fs.writeFileSync(projectFile, pbxproj);
fs.writeFileSync(path.join(schemeDirectory, 'Jarvis.xcscheme'), scheme);
console.log(`Generated ${path.relative(root, projectFile)} with ${appFiles.length} app and ${testFiles.length} test source files.`);
