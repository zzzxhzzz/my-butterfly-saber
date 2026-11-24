package dev.linwood.butterfly;

import android.content.ContentResolver;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Rect;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.google.mlkit.vision.common.InputImage;
import com.google.mlkit.vision.text.Text;
import com.google.mlkit.vision.text.TextRecognition;
import com.google.mlkit.vision.text.TextRecognizer;
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions;
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions;
import com.google.mlkit.vision.text.latin.TextRecognizerOptions;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;


public class MainActivity extends FlutterActivity {
    private static final String CHANNEL = "linwood.dev/butterfly";
    private static final String OCR_CHANNEL = "butterfly.saber_fusion/ocr";
    private Map<String, Object> importIntent;
    private final ExecutorService ocrExecutor = Executors.newSingleThreadExecutor();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private TextRecognizer zhRecognizer;
    private TextRecognizer enRecognizer;
    private TextRecognizer jaRecognizer;

    @Override
    @Nullable
    public String getInitialRoute() {
        if (handleIntent(getIntent())) {
            return "/intent";
        }
        return super.getInitialRoute();
    }

    @Override
    protected void onNewIntent(@NonNull Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (handleIntent(intent) && getFlutterEngine() != null) {
            getFlutterEngine().getNavigationChannel().pushRoute("/intent");
        }
    }

    private boolean handleIntent(Intent intent) {
        String action = intent.getAction();
        String type = intent.getType();

        if (!Intent.ACTION_VIEW.equals(action)
                && !Intent.ACTION_EDIT.equals(action)
                && !Intent.ACTION_SEND.equals(action)) {
            return false;
        }
        Uri uri = intent.getData();
        if (uri == null) {
            uri = getParcelableExtraStream(intent);
        }
        if (uri == null && intent.getClipData() != null && intent.getClipData().getItemCount() > 0) {
            uri = intent.getClipData().getItemAt(0).getUri();
        }
        if (uri != null) {
            String scheme = uri.getScheme();
            if (!ContentResolver.SCHEME_CONTENT.equals(scheme)
                    && !ContentResolver.SCHEME_FILE.equals(scheme)
                    && !ContentResolver.SCHEME_ANDROID_RESOURCE.equals(scheme)) {
                return false;
            }
            if (type == null) {
                type = getContentResolver().getType(uri);
            }
            setImportIntent(type != null ? type : "application/octet-stream", uri.toString());
            return true;
        }
        if (Intent.ACTION_SEND.equals(action)) {
            String text = intent.getStringExtra(Intent.EXTRA_TEXT);
            if (text != null) {
                setImportIntent(type != null ? type : "text/plain", text.getBytes(StandardCharsets.UTF_8));
                return true;
            }
        }
        return false;
    }

    private void setImportIntent(String type, Object source) {
        Map<String, Object> payload = new HashMap<>();
        payload.put("type", type);
        payload.put("source", source);
        importIntent = payload;
    }

    @Nullable
    @SuppressWarnings("deprecation")
    private Uri getParcelableExtraStream(Intent intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri.class);
        }
        return intent.getParcelableExtra(Intent.EXTRA_STREAM);
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL)
                .setMethodCallHandler((call, result) -> {
                    if (call.method.equals("getImportIntent")) {
                        result.success(importIntent);
                    } else {
                        result.notImplemented();
                    }
                });
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), OCR_CHANNEL)
                .setMethodCallHandler((call, result) -> {
                    if (call.method.equals("recognizePng")) {
                        byte[] png = call.argument("png");
                        String lang = call.argument("lang");
                        if (png == null || png.length == 0) {
                            result.error("INVALID_ARGS", "Empty PNG bytes", null);
                            return;
                        }
                        runOcrRecognizePng(png, lang != null ? lang : "zh_en", result);
                    } else {
                        result.notImplemented();
                    }
                });
    }

    private synchronized TextRecognizer getRecognizer(String lang) {
        if ("en".equals(lang)) {
            if (enRecognizer == null) {
                enRecognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS);
            }
            return enRecognizer;
        }
        if ("ja".equals(lang)) {
            if (jaRecognizer == null) {
                jaRecognizer = TextRecognition.getClient(
                        new JapaneseTextRecognizerOptions.Builder().build());
            }
            return jaRecognizer;
        }
        if (zhRecognizer == null) {
            zhRecognizer = TextRecognition.getClient(
                    new ChineseTextRecognizerOptions.Builder().build());
        }
        return zhRecognizer;
    }

    private static double clamp01(double v) {
        return Math.max(0.0, Math.min(1.0, v));
    }

    private void runOcrRecognizePng(
            @NonNull byte[] png,
            @NonNull String lang,
            @NonNull MethodChannel.Result result) {
        ocrExecutor.execute(() -> {
            Bitmap bitmap = null;
            try {
                bitmap = BitmapFactory.decodeByteArray(png, 0, png.length);
                if (bitmap == null) {
                    mainHandler.post(() -> result.error("DECODE_ERROR", "Failed to decode PNG", null));
                    return;
                }
                final double w = Math.max(1, bitmap.getWidth());
                final double h = Math.max(1, bitmap.getHeight());
                final Bitmap finalBitmap = bitmap;
                InputImage inputImage = InputImage.fromBitmap(finalBitmap, 0);
                TextRecognizer recognizer = getRecognizer(lang);
                recognizer.process(inputImage)
                        .addOnSuccessListener(visionText -> {
                            finalBitmap.recycle();
                            List<Map<String, Object>> outLines = new ArrayList<>();
                            for (Text.TextBlock block : visionText.getTextBlocks()) {
                                for (Text.Line line : block.getLines()) {
                                    String lineText = line.getText().trim();
                                    Rect lb = line.getBoundingBox();
                                    if (lineText.isEmpty() || lb == null) continue;
                                    Map<String, Object> lineMap = new HashMap<>();
                                    lineMap.put("text", lineText);
                                    lineMap.put("l", clamp01(lb.left / w));
                                    lineMap.put("t", clamp01(lb.top / h));
                                    lineMap.put("r", clamp01(lb.right / w));
                                    lineMap.put("b", clamp01(lb.bottom / h));

                                    List<Map<String, Object>> words = new ArrayList<>();
                                    for (Text.Element el : line.getElements()) {
                                        Rect wb = el.getBoundingBox();
                                        String wt = el.getText();
                                        if (wt.isEmpty() || wb == null) continue;
                                        Map<String, Object> wm = new HashMap<>();
                                        wm.put("t", wt);
                                        wm.put("l", clamp01(wb.left / w));
                                        wm.put("tp", clamp01(wb.top / h));
                                        wm.put("r", clamp01(wb.right / w));
                                        wm.put("b", clamp01(wb.bottom / h));
                                        words.add(wm);
                                    }
                                    lineMap.put("words", words);
                                    outLines.add(lineMap);
                                }
                            }
                            result.success(outLines);
                        })
                        .addOnFailureListener(e -> {
                            finalBitmap.recycle();
                            result.error("OCR_FAILED", e.getMessage(), null);
                        });
            } catch (Throwable t) {
                if (bitmap != null && !bitmap.isRecycled()) {
                    bitmap.recycle();
                }
                mainHandler.post(() -> result.error("OCR_EXCEPTION", t.getMessage(), null));
            }
        });
    }

    @Override
    protected void onDestroy() {
        ocrExecutor.shutdownNow();
        if (zhRecognizer != null) {
            try { zhRecognizer.close(); } catch (Exception ignored) {}
            zhRecognizer = null;
        }
        if (enRecognizer != null) {
            try { enRecognizer.close(); } catch (Exception ignored) {}
            enRecognizer = null;
        }
        if (jaRecognizer != null) {
            try { jaRecognizer.close(); } catch (Exception ignored) {}
            jaRecognizer = null;
        }
        super.onDestroy();
    }
}
