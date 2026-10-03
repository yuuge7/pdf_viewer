package android.print;

import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;

/**
 * Drives a {@link PrintDocumentAdapter} straight into a file, with no print
 * dialog.
 *
 * It lives in this package because the two callback classes have
 * constructors the SDK hides from every other one: the print framework is
 * meant to be the only caller. A WebView's adapter is the one thing on
 * Android that paginates HTML, and this is the only way to run it without
 * the user picking "Save as PDF" by hand.
 */
public final class PdfWriter {
    /** Told once, with null on success. */
    public interface Done {
        void onDone(Throwable error);
    }

    private PdfWriter() {}

    public static void write(
            final PrintDocumentAdapter adapter,
            final PrintAttributes attributes,
            final ParcelFileDescriptor out,
            final Done done) {
        adapter.onLayout(null, attributes, null, new PrintDocumentAdapter.LayoutResultCallback() {
            @Override
            public void onLayoutFinished(PrintDocumentInfo info, boolean changed) {
                adapter.onWrite(
                        new PageRange[] {PageRange.ALL_PAGES},
                        out,
                        new CancellationSignal(),
                        new PrintDocumentAdapter.WriteResultCallback() {
                            @Override
                            public void onWriteFinished(PageRange[] pages) {
                                done.onDone(null);
                            }

                            @Override
                            public void onWriteFailed(CharSequence error) {
                                done.onDone(new RuntimeException(String.valueOf(error)));
                            }

                            @Override
                            public void onWriteCancelled() {
                                done.onDone(new RuntimeException("Cancelled"));
                            }
                        });
            }

            @Override
            public void onLayoutFailed(CharSequence error) {
                done.onDone(new RuntimeException(String.valueOf(error)));
            }

            @Override
            public void onLayoutCancelled() {
                done.onDone(new RuntimeException("Cancelled"));
            }
        }, null);
    }
}
