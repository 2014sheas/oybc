# Troubleshooting Guide

## React Native Version Mismatch Error

If you see the error:

```
React Native version mismatch.
JavaScript version: 0.82.1
Native version: 0.81.4
```

### Root Cause

This happens when there's a mismatch between:

- The React Native version in your `package.json` (JavaScript bundle)
- The React Native version in the Expo Go app on your device (Native runtime)

Expo SDK 54 uses React Native 0.81.5, which should match modern Expo Go apps. However, if your Expo Go app is outdated, you may need to update it.

### Solutions

#### Solution 1: Update Expo Go App (Recommended)

1. Update the Expo Go app on your device from the App Store (iOS) or Play Store (Android)
2. Ensure it's the latest version
3. Try connecting again

#### Solution 2: Clear Cache and Restart

```bash
# Clear all caches
rm -rf .expo node_modules/.cache metro-cache
npm start -- --clear
```

#### Solution 3: Use Development Build (For Production)

If you need specific native modules or versions:

1. Build a development build with EAS
2. Install on your device
3. This gives you full control over native dependencies

#### Solution 4: Check Expo SDK Compatibility

Verify your Expo SDK version matches your Expo Go app:

```bash
npx expo-doctor
npx expo install --check
```

### Current Project Status

- Expo SDK: 54.0.21
- React Native: 0.81.5 (matches Expo SDK 54)
- React: 19.1.0
- All peer dependencies installed

### If Issues Persist

1. Check `expo-doctor` output for any remaining issues
2. Verify your Expo CLI is up to date: `npm install -g @expo/cli@latest`
3. Try creating a fresh Expo project and migrating code
4. Check [Expo's compatibility docs](https://docs.expo.dev/workflow/using-expo-cli/)
