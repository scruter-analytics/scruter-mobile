# Example app

Navigation, a list, a form, a masked view, a crash. `android/` and `ios/` are generated for the React Native version you
choose, so that the same app runs on every version the SDK supports (the CI runs 0.73 to the latest):

```sh
node setup.mjs                                  # the latest tested version, new architecture
node setup.mjs --rn 0.73.11 --arch old
cd ios && pod install && cd ..
npx react-native run-android                    # or run-ios
```

The Android SDK comes from your local Maven repository until it is on Maven Central:
`cd ../../android && ./gradlew :scruter-android:publishToMavenLocal`.

`setup.mjs --check` points the app at the local server of `../scripts/device-check.mjs`, which drives it on an emulator
or a simulator with [Maestro](https://maestro.dev) and checks every request against `../../protocol`.
