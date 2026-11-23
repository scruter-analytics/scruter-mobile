package net.scruter.flutter;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;

/**
 * Opens on {@code scruter-<app id>://team?t=…}, the QR code of App settings › Team phones (docs/MOBILE.md
 * §3.12): hands the link to the SDK (kept until {@code Scruter.start} when the app was not running), then opens the app.
 * An activity of its own keeps the link away from the router of an app with Flutter's deep linking on. No UI.
 */
public final class ScruterTeamLink extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        ScruterFlutterPlugin.teamLink(getIntent());
        Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
        if (launch != null) {
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(launch);
        }
        finish();
    }
}
