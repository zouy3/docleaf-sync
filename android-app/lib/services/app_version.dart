// Base (pubspec) version. Android split APKs have separate installation codes.
// about_version_test checks both constants against pubspec.yaml.
abstract final class AppVersion {
  static const name = '1.0.133';
  static const code = 138;
  static const display = '$name ($code)';
}
