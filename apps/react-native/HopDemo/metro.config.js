const path = require('path');
const {getDefaultConfig, mergeConfig} = require('@react-native/metro-config');

/**
 * Metro configuration
 * https://reactnative.dev/docs/metro
 *
 * WHY THIS IS NOT THE TEMPLATE DEFAULT.
 *
 * `@hop-mesh/react-native` is a `file:` dependency, so npm installs it as a SYMLINK to
 * ../../../sdk/react-native, which is outside this project root. Metro only serves files from folders it
 * watches, so with the default config the bundle fails outright:
 *
 *   error Unable to resolve module @hop-mesh/react-native from App.tsx
 *
 * That failure is invisible to both native builds. A debug APK does not embed a bundle, it fetches one
 * from Metro at launch, so `gradlew assembleDebug` and `xcodebuild` both report success and the app then
 * red-boxes on the device. Anything that needs the app to actually RUN, a Detox scenario or two phones
 * exchanging a message, needs this.
 *
 * @type {import('@react-native/metro-config').MetroConfig}
 */
const sdkRoot = path.resolve(__dirname, '../../../sdk/react-native');

const config = {
  watchFolders: [sdkRoot],
  resolver: {
    // The SDK declares react and react-native as PEERS and its own node_modules carries only typescript
    // and @types/node, so when its lib requires react-native there is nothing to find: the SDK's
    // directory is not an ancestor of this app, so Metro cannot walk up to this app's node_modules.
    // extraNodeModules is the fallback for exactly that case, modules Metro would otherwise not find at
    // all, so it cannot shadow a copy that does resolve normally.
    extraNodeModules: {
      react: path.resolve(__dirname, 'node_modules/react'),
      'react-native': path.resolve(__dirname, 'node_modules/react-native'),
    },
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
