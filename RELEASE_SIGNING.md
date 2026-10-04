# Release signing

## Where things stand

Every build so far, including 2.3.0, is signed with the **Android debug key**.
That is fine for testing on your own phone. It is not acceptable for real
users or for Google Play.

The build is now ready for a release key but does not use one yet:

- If `android/key.properties` exists, release builds are signed with the key
  it points to.
- If it does not exist, release builds are signed with the debug key, exactly
  as before.

No credentials were created or changed.

## Important before you switch

Android only installs an update over an existing app if both are signed with
the same key. The first build signed with your release key will **not** install
over the debug-signed app. Each tester must uninstall first, which deletes the
app's local data, including a running challenge.

So: switch once, before there are real users, and never while a challenge that
matters is running.

## One-time setup

1. Create a keystore (run on your own computer; Java's `keytool` comes with
   Android Studio):

       keytool -genkey -v -keystore commit-release.jks -keyalg RSA \
               -keysize 2048 -validity 10000 -alias commit

   Choose strong passwords. Keep the file outside the project folder.

2. Copy `android/key.properties.example` to `android/key.properties` and fill
   in the path, alias and passwords.

3. Build as usual: `flutter build apk --release` (or `appbundle` for Play).

## Looking after the key

- Back up the keystore file and its passwords in at least two safe places. If
  you lose them you can no longer update the app outside Google Play.
- Never commit `key.properties` or the keystore, and never send them to
  anyone. Both are already listed in `android/.gitignore`.
- For Google Play, enrol in **Play App Signing**. Google then holds the key
  users' phones check, and your keystore becomes an *upload key* that Google
  can reset if it is lost.

## Checking which key signed an APK

    apksigner verify --print-certs app-release.apk

The debug key shows `CN=Android Debug`. Your release key shows the name you
entered in step 1.
