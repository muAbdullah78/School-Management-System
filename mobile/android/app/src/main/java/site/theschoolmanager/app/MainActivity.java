package site.theschoolmanager.app;

import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Bundle;
import android.webkit.WebView;
import com.getcapacitor.BridgeActivity;

/**
 * The whole app is the web app in web/, served from inside the APK. This class
 * adds the two things a WebView does not do on its own: printing (the
 * SchoolPrint plugin) and knowing whether the phone is online.
 */
public class MainActivity extends BridgeActivity {

    private ConnectivityManager.NetworkCallback networkCallback;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(SchoolPrintPlugin.class);
        super.onCreate(savedInstanceState);
        watchNetwork();
    }

    /**
     * A WebView's navigator.onLine is whatever the app tells it, and nothing
     * tells it by default: it stays true in airplane mode. The offline engine
     * and the screens read navigator.onLine and the online and offline events,
     * so Android's own view of the network is passed on here and they work
     * unchanged. Any network that offers the internet counts, as it does in a
     * browser; a network that only looks connected is caught by the engine,
     * which treats a failed request as offline.
     */
    private void watchNetwork() {
        final ConnectivityManager cm = getSystemService(ConnectivityManager.class);
        if (cm == null) return;
        setOnline(hasInternet(cm, cm.getActiveNetwork()));
        networkCallback = new ConnectivityManager.NetworkCallback() {
            @Override
            public void onAvailable(Network network) {
                setOnline(true);
            }

            @Override
            public void onLost(Network network) {
                setOnline(hasInternet(cm, cm.getActiveNetwork()));
            }

            @Override
            public void onCapabilitiesChanged(Network network, NetworkCapabilities caps) {
                setOnline(caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET));
            }
        };
        try {
            cm.registerDefaultNetworkCallback(networkCallback);
        } catch (RuntimeException e) {
            // Too many callbacks registered by other apps' bugs, or a restricted
            // profile: the app still works, the engine just learns from failures.
            networkCallback = null;
        }
    }

    private static boolean hasInternet(ConnectivityManager cm, Network network) {
        if (network == null) return false;
        NetworkCapabilities caps = cm.getNetworkCapabilities(network);
        return caps != null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET);
    }

    private void setOnline(final boolean online) {
        runOnUiThread(() -> {
            if (getBridge() == null) return;
            WebView webView = getBridge().getWebView();
            if (webView != null) webView.setNetworkAvailable(online);
        });
    }

    @Override
    public void onDestroy() {
        ConnectivityManager cm = getSystemService(ConnectivityManager.class);
        if (cm != null && networkCallback != null) {
            try {
                cm.unregisterNetworkCallback(networkCallback);
            } catch (IllegalArgumentException ignored) {
                // Never registered, or already gone.
            }
        }
        super.onDestroy();
    }
}
