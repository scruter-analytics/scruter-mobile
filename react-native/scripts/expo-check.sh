#!/usr/bin/env bash
# An Expo app with the config plugin and Expo Router, as a development build: `expo prebuild` writes every native setting,
# the bundle resolves, and the app compiles.
#   expo-check.sh android|ios [sdk]
# SDK 57 is the stack of the first app in production (React Native 0.86, new architecture).
set -euo pipefail
platform="${1:-android}"
sdk="${2:-57}"
here="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

(cd "$here" && npm ci --no-audit --no-fund && npm pack --pack-destination "$work")
cd "$work"
npx --yes create-expo-app@latest app --template "blank-typescript@sdk-$sdk" --no-install
cd app
npm install --no-audit --no-fund
npm install --no-audit --no-fund "$work"/scruter-react-native-*.tgz
# The exact versions of that app.
if [ "$sdk" = 57 ]; then npm install --no-audit --no-fund --save-exact --legacy-peer-deps react-native@0.86.0 react@19.2.3; fi
npx expo install expo-router expo-dev-client expo-linking expo-constants react-native-screens react-native-safe-area-context
node -e "
const fs = require('fs');
const c = JSON.parse(fs.readFileSync('app.json', 'utf8'));
c.expo.scheme = 'scruterexpo';
c.expo.ios = { ...c.expo.ios, bundleIdentifier: 'net.scruter.expoexample' };
c.expo.android = { ...c.expo.android, package: 'net.scruter.expoexample' };
c.expo.plugins = [...(c.expo.plugins ?? []), 'expo-router', ['@scruter/react-native', { appId: 'EXAMPLE1' }]];
fs.writeFileSync('app.json', JSON.stringify(c, null, 2));
const p = JSON.parse(fs.readFileSync('package.json', 'utf8'));
p.main = 'expo-router/entry';
fs.writeFileSync('package.json', JSON.stringify(p, null, 2));
"
rm -f App.tsx index.ts
mkdir -p app
cat > app/_layout.tsx <<'TSX'
import { useEffect } from 'react';
import { Stack, useNavigationContainerRef } from 'expo-router';
import { Scruter } from '@scruter/react-native';

Scruter.start({ appId: 'EXAMPLE1' });

export default function RootLayout() {
  const ref = useNavigationContainerRef();
  useEffect(() => Scruter.trackNavigation(ref), [ref]);
  return <Stack />;
}
TSX
cat > app/index.tsx <<'TSX'
import { Text, View } from 'react-native';
import { ScruterMask } from '@scruter/react-native';

export default function Home() {
  return (
    <View>
      <ScruterMask>
        <Text>Expo</Text>
      </ScruterMask>
    </View>
  );
}
TSX
node -e "console.log('Expo', require('expo/package.json').version, 'React Native', require('react-native/package.json').version, 'React', require('react/package.json').version)"
npx expo export --platform "$platform" --output-dir "$work/export"
npx expo prebuild --no-install --platform all

grep -q 'scruter-example1' ios/*/Info.plist
grep -q 'AttributionCopyEndpoint' ios/*/Info.plist
grep -q 'scruterAppId: "example1"' android/app/build.gradle
grep -q 'SOURCEMAP_FILE' ios/*.xcodeproj/project.pbxproj
if [ "$platform" = ios ]; then
  # Nothing from the CocoaPods trunk for the SDK: the package's pod compiles it.
  (cd ios && pod install)
  if grep -q '^  - Scruter ' ios/Podfile.lock; then echo "the pod Scruter came from the trunk"; exit 1; fi
  (cd ios && xcodebuild -workspace ./*.xcworkspace -scheme app -configuration Debug -sdk iphonesimulator \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO ARCHS=arm64 -quiet build)
else
  echo 'allprojects { repositories { mavenLocal() } }' >> android/build.gradle
  (cd android && ./gradlew --no-daemon --max-workers=3 :app:assembleDebug -PreactNativeArchitectures=x86_64)
fi
echo "expo check passed"
