package site.theschoolmanager.app;

import android.content.Context;
import android.print.PrintAttributes;
import android.print.PrintDocumentAdapter;
import android.print.PrintManager;
import android.webkit.WebView;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

/**
 * window.print() does nothing inside an Android WebView: no dialog, no error.
 * The app replaces it (web/src/native/native.ts) with a call to this, which
 * hands the page to Android's own printing: a printer on the network, or
 * "Save as PDF", which is how a receipt reaches WhatsApp. The page's print
 * stylesheet still decides what is on the paper, exactly as in a browser.
 */
@CapacitorPlugin(name = "SchoolPrint")
public class SchoolPrintPlugin extends Plugin {

    @PluginMethod
    public void print(final PluginCall call) {
        final String name = call.getString("name", "The School Manager");
        getActivity().runOnUiThread(() -> {
            try {
                WebView webView = getBridge().getWebView();
                PrintManager printManager = (PrintManager) getActivity().getSystemService(Context.PRINT_SERVICE);
                if (webView == null || printManager == null) {
                    call.reject("Printing is not available on this phone.");
                    return;
                }
                PrintDocumentAdapter adapter = webView.createPrintDocumentAdapter(name);
                printManager.print(name, adapter, new PrintAttributes.Builder().build());
                call.resolve();
            } catch (Exception e) {
                call.reject("Printing could not start: " + e.getMessage(), e);
            }
        });
    }
}
