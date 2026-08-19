package com.hopdemo;

import com.wix.detox.Detox;
import com.wix.detox.config.DetoxConfig;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.filters.LargeTest;
import androidx.test.rule.ActivityTestRule;

import org.junit.Rule;
import org.junit.Test;
import org.junit.runner.RunWith;

/**
 * The Android side of Detox. Detox does not drive an Android app from outside: it runs INSIDE the app as
 * an instrumentation test, and the JavaScript test process connects to it. Without this class there is no
 * androidTest APK, and `detox test` fails looking for
 * app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk.
 *
 * This is the one place the two-device harness touches Java. It is the standard Detox entry point rather
 * than anything specific to this app: every scenario, single device or device pair, runs through it.
 */
@RunWith(AndroidJUnit4.class)
@LargeTest
public class DetoxTest {

    @Rule
    public ActivityTestRule<MainActivity> activityRule = new ActivityTestRule<>(MainActivity.class, false, false);

    @Test
    public void runDetoxTests() {
        DetoxConfig config = new DetoxConfig();
        // The default idle-resource timeout is short. This app opens two Hop nodes, publishes prekeys and
        // dials a relay before the screen settles, and a @device-pair scenario then waits on a second
        // device, so a stricter timeout would report a busy app as a hung one.
        config.idlePolicyConfig.masterTimeoutSec = 120;
        config.idlePolicyConfig.idleResourceTimeoutSec = 120;
        config.rnContextLoadTimeoutSec = 180;

        Detox.runTests(activityRule, config);
    }
}
