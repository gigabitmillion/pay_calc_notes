import 'package:shared_preferences/shared_preferences.dart';
import 'package:in_app_review/in_app_review.dart';

class ReviewRequest {
  static const String _launchCountKey = 'launch_count';
  static const String _reviewRequestedKey = 'review_requested';

  static Future<void> onAppLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    int count = prefs.getInt(_launchCountKey) ?? 0;
    bool alreadyRequested = prefs.getBool(_reviewRequestedKey) ?? false;

    if (!alreadyRequested) {
      count += 1;
      await prefs.setInt(_launchCountKey, count);

      if (count == 5) {
        await requestReview();
        // フラグを立てて今後出さない
        await prefs.setBool(_reviewRequestedKey, true);
      }
    }
  }

  static Future<void> requestReview() async {
    final inAppReview = InAppReview.instance;

    if (await inAppReview.isAvailable()) {
      await inAppReview.requestReview();
    } else {
      // iOS: appStoreId指定、Android: 省略でOK
      await inAppReview.openStoreListing(
        appStoreId: '6746982676',
      );
    }
  }
}